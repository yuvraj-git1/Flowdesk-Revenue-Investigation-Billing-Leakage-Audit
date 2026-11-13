-- ============================================================================
-- STAGE 3: MRR WATERFALL + CORE SAAS METRICS (DuckDB)
-- Design: MRR is rebuilt per account per MONTH-END from plan_changes (the contract history).
-- Why plan_changes and not subscriptions? subscriptions is a current-state snapshot (no history);
-- plan_changes gives mrr_before/after for every movement so any month can be reconstructed.
-- "List MRR" = contracted price x seats BEFORE discounts. "Billed MRR" (invoices) is built later for reconciliation.
-- ============================================================================

-- name: m00_months
-- Month spine with an integer index (lets us self-join "12 months earlier" without date arithmetic).
DROP TABLE IF EXISTS months;
CREATE TABLE months AS SELECT m, ROW_NUMBER() OVER (ORDER BY m) mi, LEAD(m) OVER (ORDER BY m) next_m FROM (SELECT DISTINCT month_start m FROM seat_usage_monthly) x;
SELECT * FROM months ORDER BY m;

-- name: m01_account_month_mrr
-- One row per paid account per month from its first paid month: month-end MRR = mrr_after of the LAST plan_change
-- before the next month starts. After a cancel, mrr_after=0 so churned accounts stay in the spine at 0 (needed to detect churn).
DROP TABLE IF EXISTS acct_month_mrr;
CREATE TABLE acct_month_mrr AS
WITH first_m AS (SELECT account_id, CAST(date_trunc('month', MIN(changed_at)) AS DATE) fm FROM plan_changes GROUP BY 1),
 spine AS (SELECT f.account_id, mo.m, mo.mi, COALESCE(mo.next_m, CAST('2026-01-01' AS DATE)) nxt FROM first_m f JOIN months mo ON mo.m >= f.fm),
 ranked AS (SELECT sp.account_id, sp.m, sp.mi, pc.mrr_after_usd mrr, COALESCE(pc.to_plan, pc.from_plan) plan_eom, COALESCE(pc.to_interval, pc.from_interval) interval_eom,
            ROW_NUMBER() OVER (PARTITION BY sp.account_id, sp.m ORDER BY pc.changed_at DESC, pc.plan_change_id DESC) rn
            FROM spine sp JOIN plan_changes pc ON pc.account_id = sp.account_id AND pc.changed_at < sp.nxt)
SELECT account_id, m, mi, mrr, plan_eom, interval_eom FROM ranked WHERE rn = 1;
SELECT COUNT(*) rows_, COUNT(DISTINCT account_id) accounts, ROUND(SUM(CASE WHEN m='2025-12-01' THEN mrr END),0) dec25_mrr FROM acct_month_mrr;

-- name: m02_account_dimensions
-- Segment attributes. Channel labels are normalised with a transparent rule set (lower/trim, then keyword match);
-- unmapped count must be 0 (checked below).
DROP TABLE IF EXISTS acct_dim;
CREATE TABLE acct_dim AS
SELECT account_id, acquisition_motion motion, company_size_band size_band,
  CASE WHEN lower(trim(signup_source)) IN ('organic_search','organic','organic search','seo','google organic') THEN 'organic_search'
       WHEN lower(trim(signup_source)) IN ('direct','(direct)','none','direct / none') THEN 'direct'
       WHEN lower(trim(signup_source)) IN ('referral','word of mouth','referral_friend','ref') THEN 'referral'
       WHEN lower(trim(signup_source)) IN ('paid_search','google ads','google / cpc','adwords','googleads','ppc') THEN 'paid_search'
       WHEN lower(trim(signup_source)) IN ('paid_social','fb','facebook ads','facebook','linkedin ads','social_paid') THEN 'paid_social'
       WHEN lower(trim(signup_source)) IN ('review_site','g2','g2 crowd','capterra','capterra review','getapp') THEN 'review_site'
       WHEN lower(trim(signup_source)) IN ('affiliate','partnerstack','aff') THEN 'affiliate'
       WHEN lower(trim(signup_source)) IN ('content_email','newsletter','email','blog') THEN 'content_email'
       WHEN lower(trim(signup_source)) IN ('partner','partners','integration_partner') THEN 'partner'
       ELSE 'UNMAPPED' END channel
FROM accounts;
SELECT channel, COUNT(*) accounts FROM acct_dim GROUP BY 1 ORDER BY 2 DESC;

-- name: m03_movements
-- Classify each account-month change vs previous month-end:
--   new = first ever MRR>0 | reactivation = MRR returns after having been >0 before | churn = MRR goes to 0
--   expansion / contraction = up / down while staying >0.  churn_type comes from subscriptions.cancellation_source.
DROP TABLE IF EXISTS acct_move;
CREATE TABLE acct_move AS
WITH x AS (SELECT account_id, m, mi, mrr, plan_eom, interval_eom,
        COALESCE(LAG(mrr) OVER (PARTITION BY account_id ORDER BY m), 0) prev,
        COALESCE(MAX(mrr) OVER (PARTITION BY account_id ORDER BY m ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) ever_before
        FROM acct_month_mrr)
SELECT x.*, d.motion, d.channel, d.size_band,
  CASE WHEN prev=0 AND mrr>0 AND ever_before=0 THEN 'new' WHEN prev=0 AND mrr>0 THEN 'reactivation' WHEN prev>0 AND mrr=0 THEN 'churn'
       WHEN prev>0 AND mrr>prev THEN 'expansion' WHEN prev>0 AND mrr<prev THEN 'contraction' ELSE 'flat' END move,
  mrr - prev delta,
  CASE WHEN prev>0 AND mrr=0 THEN CASE WHEN s.cancellation_source='payment_failure' THEN 'involuntary' ELSE 'voluntary' END END churn_type
FROM x JOIN acct_dim d USING (account_id) LEFT JOIN subscriptions s USING (account_id);
SELECT move, COUNT(*) n, ROUND(SUM(delta),0) delta FROM acct_move GROUP BY 1 ORDER BY 2 DESC;

-- name: m10_mrr_waterfall_monthly
-- THE WATERFALL: opening + new + reactivation + expansion - contraction - churn = closing. check_ must be 0.
SELECT m, ROUND(SUM(prev),0) opening,
  ROUND(SUM(CASE WHEN move='new' THEN delta ELSE 0 END),0) new_mrr,
  ROUND(SUM(CASE WHEN move='reactivation' THEN delta ELSE 0 END),0) reactivation_mrr,
  ROUND(SUM(CASE WHEN move='expansion' THEN delta ELSE 0 END),0) expansion_mrr,
  ROUND(SUM(CASE WHEN move='contraction' THEN delta ELSE 0 END),0) contraction_mrr,
  ROUND(SUM(CASE WHEN move='churn' AND churn_type='voluntary' THEN delta ELSE 0 END),0) churn_voluntary_mrr,
  ROUND(SUM(CASE WHEN move='churn' AND churn_type='involuntary' THEN delta ELSE 0 END),0) churn_involuntary_mrr,
  ROUND(SUM(mrr),0) closing,
  ROUND(SUM(mrr) - SUM(prev) - SUM(delta),2) check_,
  ROUND(SUM(mrr)*12,0) arr
FROM acct_move GROUP BY 1 ORDER BY 1;

-- name: m11_quarterly_waterfall_2024_vs_2025
-- Story test: where did net new MRR go? Compare each component by quarter.
SELECT CAST(strftime_q AS VARCHAR) q, SUM(new_mrr) new_mrr, SUM(expansion_mrr) expansion, SUM(contraction_mrr) contraction, SUM(churn_mrr) churn, SUM(net_new) net_new FROM (
  SELECT substr(CAST(m AS VARCHAR),1,4) || '-Q' || CASE WHEN substr(CAST(m AS VARCHAR),6,2) IN ('01','02','03') THEN '1' WHEN substr(CAST(m AS VARCHAR),6,2) IN ('04','05','06') THEN '2' WHEN substr(CAST(m AS VARCHAR),6,2) IN ('07','08','09') THEN '3' ELSE '4' END strftime_q,
    CASE WHEN move='new' THEN delta ELSE 0 END new_mrr, CASE WHEN move='expansion' THEN delta ELSE 0 END expansion_mrr,
    CASE WHEN move='contraction' THEN delta ELSE 0 END contraction_mrr, CASE WHEN move='churn' THEN delta ELSE 0 END churn_mrr, delta net_new
  FROM acct_move WHERE m >= '2024-01-01') z GROUP BY 1 ORDER BY 1;

-- name: m12_nrr_grr_logo_vs_revenue_churn_monthly
-- Monthly view: logo churn = churned accounts / accounts active at start; revenue churn = churned MRR / opening MRR;
-- gross revenue churn also counts contraction. NRR/GRR monthly = (opening +/- movements on EXISTING accounts) / opening.
SELECT m, SUM(CASE WHEN prev>0 THEN 1 ELSE 0 END) accts_open, SUM(CASE WHEN move='churn' THEN 1 ELSE 0 END) accts_churned,
  ROUND(100.0*SUM(CASE WHEN move='churn' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN prev>0 THEN 1 ELSE 0 END),0),2) logo_churn_pct,
  ROUND(-100.0*SUM(CASE WHEN move='churn' THEN delta ELSE 0 END)/NULLIF(SUM(prev),0),2) revenue_churn_pct,
  ROUND(100.0*SUM(CASE WHEN prev>0 THEN mrr ELSE 0 END)/NULLIF(SUM(prev),0),2) nrr_monthly_pct,
  ROUND(100.0*(SUM(prev) + SUM(CASE WHEN move IN ('churn','contraction') THEN delta ELSE 0 END))/NULLIF(SUM(prev),0),2) grr_monthly_pct
FROM acct_move GROUP BY 1 ORDER BY 1;

-- name: m13_nrr_grr_ttm
-- Standard trailing-12-month cohort metrics: take accounts with MRR>0 twelve months ago.
-- NRR = their MRR today / their MRR then (includes expansion). GRR caps each account at its old MRR (no expansion credit).
SELECT a.m, ROUND(SUM(b.mrr),0) base_mrr, ROUND(100.0*SUM(a.mrr)/SUM(b.mrr),1) nrr_ttm_pct,
       ROUND(100.0*SUM(CASE WHEN a.mrr < b.mrr THEN a.mrr ELSE b.mrr END)/SUM(b.mrr),1) grr_ttm_pct,
       ROUND(100.0*SUM(CASE WHEN a.mrr=0 THEN 1 ELSE 0 END)/COUNT(*),1) logo_churn_ttm_pct
FROM acct_month_mrr a JOIN acct_month_mrr b ON b.account_id=a.account_id AND b.mi = a.mi-12 AND b.mrr>0
GROUP BY 1 ORDER BY 1;

-- name: m14_ttm_retention_by_segment
-- Same TTM metric cut by segment AS OF twelve months ago (so segments don't leak the future). Dec snapshots only.
WITH seg AS (SELECT 'plan' dim, b.plan_eom seg, a.m, a.mrr cur, b.mrr base FROM acct_month_mrr a JOIN acct_month_mrr b ON b.account_id=a.account_id AND b.mi=a.mi-12 AND b.mrr>0
             UNION ALL SELECT 'interval', b.interval_eom, a.m, a.mrr, b.mrr FROM acct_month_mrr a JOIN acct_month_mrr b ON b.account_id=a.account_id AND b.mi=a.mi-12 AND b.mrr>0
             UNION ALL SELECT 'motion', d.motion, a.m, a.mrr, b.mrr FROM acct_month_mrr a JOIN acct_month_mrr b ON b.account_id=a.account_id AND b.mi=a.mi-12 AND b.mrr>0 JOIN acct_dim d ON d.account_id=a.account_id
             UNION ALL SELECT 'channel', d.channel, a.m, a.mrr, b.mrr FROM acct_month_mrr a JOIN acct_month_mrr b ON b.account_id=a.account_id AND b.mi=a.mi-12 AND b.mrr>0 JOIN acct_dim d ON d.account_id=a.account_id)
SELECT dim, seg, m, COUNT(*) accounts, ROUND(SUM(base),0) base_mrr, ROUND(100.0*SUM(cur)/SUM(base),1) nrr_pct,
       ROUND(100.0*SUM(CASE WHEN cur<base THEN cur ELSE base END)/SUM(base),1) grr_pct, ROUND(100.0*SUM(CASE WHEN cur=0 THEN 1 ELSE 0 END)/COUNT(*),1) logo_churn_pct
FROM seg WHERE m IN ('2024-12-01','2025-12-01') GROUP BY 1,2,3 ORDER BY 1,2,3;

-- name: m15_waterfall_by_segment_long
-- Long format (month x dimension x segment x movement) = the Tableau drill-down source.
SELECT m, 'plan' dimension, plan_eom segment, move, COUNT(*) accounts, ROUND(SUM(delta),2) mrr_delta FROM acct_move WHERE move<>'flat' GROUP BY 1,2,3,4 UNION ALL
SELECT m, 'channel', channel, move, COUNT(*), ROUND(SUM(delta),2) FROM acct_move WHERE move<>'flat' GROUP BY 1,2,3,4 UNION ALL
SELECT m, 'motion', motion, move, COUNT(*), ROUND(SUM(delta),2) FROM acct_move WHERE move<>'flat' GROUP BY 1,2,3,4 UNION ALL
SELECT m, 'interval', interval_eom, move, COUNT(*), ROUND(SUM(delta),2) FROM acct_move WHERE move<>'flat' GROUP BY 1,2,3,4 ORDER BY 1,2,3,4;

-- name: m20_billed_mrr
-- RECONCILIATION VIEW: what did we actually bill per service month? Each PAID invoice's net (subtotal - discount, ex-tax)
-- is converted at ref fx (monthly avg of rows that have fx; reported total_usd is unreliable, see DQ) and spread evenly over
-- the months its period covers. Period months = months m with month(period_start) <= m < month(period_end).
DROP TABLE IF EXISTS billed_mrr;
CREATE TABLE billed_mrr AS
WITH ref AS (SELECT currency, CAST(date_trunc('month', issued_at) AS DATE) im, AVG(fx_rate_to_usd) fx FROM invoices WHERE fx_rate_to_usd IS NOT NULL GROUP BY 1,2),
 inv AS (SELECT i.invoice_id, i.account_id, i.period_start, i.period_end, (i.subtotal - i.discount_amount) * r.fx net_usd, i.subtotal * r.fx gross_usd,
         (CAST(substr(CAST(i.period_end AS VARCHAR),1,4) AS INTEGER) - CAST(substr(CAST(i.period_start AS VARCHAR),1,4) AS INTEGER))*12
          + CAST(substr(CAST(i.period_end AS VARCHAR),6,2) AS INTEGER) - CAST(substr(CAST(i.period_start AS VARCHAR),6,2) AS INTEGER) n_months  -- FULL period length (not only months inside the data window)
         FROM invoices i JOIN ref r ON r.currency=i.currency AND r.im=CAST(date_trunc('month', i.issued_at) AS DATE) WHERE i.status='paid'),
 j AS (SELECT inv.*, mo.m
       FROM inv JOIN months mo ON mo.m >= CAST(date_trunc('month', inv.period_start) AS DATE) AND mo.m < CAST(date_trunc('month', inv.period_end) AS DATE))
SELECT m, SUM(net_usd/n_months) billed_net, SUM(gross_usd/n_months) billed_gross FROM j GROUP BY 1;
SELECT l.m, ROUND(SUM(l.mrr),0) list_mrr, ROUND(MAX(b.billed_gross),0) billed_gross_mrr, ROUND(MAX(b.billed_net),0) billed_net_mrr,
       ROUND(SUM(l.mrr)-MAX(b.billed_net),0) gap_usd, ROUND(100.0*(SUM(l.mrr)-MAX(b.billed_net))/SUM(l.mrr),1) gap_pct
FROM acct_month_mrr l LEFT JOIN billed_mrr b ON b.m=l.m GROUP BY 1 ORDER BY 1;
