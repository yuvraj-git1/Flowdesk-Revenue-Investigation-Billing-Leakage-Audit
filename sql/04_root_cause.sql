-- ============================================================================
-- STAGE 4: ROOT-CAUSE INVESTIGATION (DuckDB). Run AFTER 03 in the same session (uses acct_move, acct_dim, billed_mrr).
-- Question: leadership says "it's just churn". Method: (1) decompose the 2024->2025 slowdown into its waterfall components,
-- (2) test each alternative cause separately with its own evidence query, (3) label what the data PROVES vs only SUGGESTS.
-- ============================================================================

-- name: rc01_net_new_mrr_decomposition_2024_vs_2025
-- Where did the slowdown come from? Yearly totals of each waterfall component and each component's share of the shortfall.
WITH y AS (SELECT substr(CAST(m AS VARCHAR),1,4) yr,
   SUM(CASE WHEN move='new' THEN delta ELSE 0 END) new_mrr, SUM(CASE WHEN move='expansion' THEN delta ELSE 0 END) expansion,
   SUM(CASE WHEN move='contraction' THEN delta ELSE 0 END) contraction,
   SUM(CASE WHEN move='churn' AND churn_type='voluntary' THEN delta ELSE 0 END) churn_voluntary,
   SUM(CASE WHEN move='churn' AND churn_type='involuntary' THEN delta ELSE 0 END) churn_involuntary, SUM(delta) net_new
   FROM acct_move WHERE m >= '2024-01-01' GROUP BY 1),
 a AS (SELECT * FROM y WHERE yr='2024'), b AS (SELECT * FROM y WHERE yr='2025')
SELECT 'new' component, ROUND(a.new_mrr,0) y2024, ROUND(b.new_mrr,0) y2025, ROUND(b.new_mrr-a.new_mrr,0) change, ROUND(100.0*(b.new_mrr-a.new_mrr)/(b.net_new-a.net_new),1) pct_of_shortfall FROM a, b UNION ALL
SELECT 'expansion', ROUND(a.expansion,0), ROUND(b.expansion,0), ROUND(b.expansion-a.expansion,0), ROUND(100.0*(b.expansion-a.expansion)/(b.net_new-a.net_new),1) FROM a, b UNION ALL
SELECT 'contraction', ROUND(a.contraction,0), ROUND(b.contraction,0), ROUND(b.contraction-a.contraction,0), ROUND(100.0*(b.contraction-a.contraction)/(b.net_new-a.net_new),1) FROM a, b UNION ALL
SELECT 'churn_voluntary', ROUND(a.churn_voluntary,0), ROUND(b.churn_voluntary,0), ROUND(b.churn_voluntary-a.churn_voluntary,0), ROUND(100.0*(b.churn_voluntary-a.churn_voluntary)/(b.net_new-a.net_new),1) FROM a, b UNION ALL
SELECT 'churn_involuntary', ROUND(a.churn_involuntary,0), ROUND(b.churn_involuntary,0), ROUND(b.churn_involuntary-a.churn_involuntary,0), ROUND(100.0*(b.churn_involuntary-a.churn_involuntary)/(b.net_new-a.net_new),1) FROM a, b UNION ALL
SELECT 'NET NEW MRR', ROUND(a.net_new,0), ROUND(b.net_new,0), ROUND(b.net_new-a.net_new,0), 100.0 FROM a, b;

-- name: rc02_involuntary_churn_rate_by_month
-- H-billing: is involuntary (payment_failure) churn steady, or does it spike? Rate = involuntary churned MRR / opening MRR.
SELECT m, ROUND(-SUM(CASE WHEN move='churn' AND churn_type='involuntary' THEN delta ELSE 0 END),0) invol_churn_mrr,
  ROUND(-100.0*SUM(CASE WHEN move='churn' AND churn_type='involuntary' THEN delta ELSE 0 END)/NULLIF(SUM(prev),0),2) invol_rate_pct,
  ROUND(-100.0*SUM(CASE WHEN move='churn' AND churn_type='voluntary' THEN delta ELSE 0 END)/NULLIF(SUM(prev),0),2) vol_rate_pct
FROM acct_move WHERE m >= '2024-07-01' GROUP BY 1 ORDER BY 1;

-- name: rc02b_dunning_gap_quantified
-- Evidence for the spike: failed first attempts in months with NO retries. Baseline = recovery rate of failures that DID get retries.
-- recoverable MRR = MRR of accounts whose failure got no retry x baseline recovery rate (by count, applied to MRR at risk).
DROP TABLE IF EXISTS lk_dunning;
CREATE TABLE lk_dunning AS
WITH f AS (SELECT p.invoice_id, i.account_id, CAST(date_trunc('month', p.attempted_at) AS DATE) m,
        (SELECT COUNT(*) FROM payments q WHERE q.invoice_id=p.invoice_id AND q.attempt_number>1) retries,
        (SELECT COUNT(*) FROM payments q WHERE q.invoice_id=p.invoice_id AND q.status='succeeded') recovered
      FROM payments p JOIN invoices i USING (invoice_id) WHERE p.attempt_number=1 AND p.status='failed'),
 base AS (SELECT 1.0*SUM(CASE WHEN recovered>0 THEN 1 ELSE 0 END)/COUNT(*) rate FROM f WHERE retries>0),
 gap AS (SELECT f.account_id, f.m, pc.mrr_before_usd mrr_lost FROM f JOIN plan_changes pc ON pc.account_id=f.account_id AND pc.change_type='cancel'
         WHERE f.retries=0 AND f.m < '2025-12-01')
SELECT MIN(m) first_month, MAX(m) last_month, COUNT(*) accounts_no_retry, ROUND(SUM(mrr_lost),0) mrr_hit, ROUND(SUM(mrr_lost)*12,0) arr_hit,
       ROUND(MAX(base.rate),3) baseline_recovery_rate, ROUND(SUM(mrr_lost)*12*MAX(base.rate),0) arr_recoverable_expected
FROM gap, base;
SELECT * FROM lk_dunning;

-- name: rc03_coupon_stacking_excess_discount
-- H-discounting: subscriptions holding 2+ non-stackable coupons. Expected discount = the single largest coupon %.
-- Excess = actual invoice discount (USD) - subtotal x max single coupon %. Counts only invoices issued while coupons were active.
DROP TABLE IF EXISTS lk_stack_hist;
CREATE TABLE lk_stack_hist AS
WITH nr AS (SELECT cr.subscription_id, COUNT(*) n, MAX(c.percent_off) max_pct, SUM(c.percent_off) sum_pct, MIN(cr.redeemed_at) first_redeem
            FROM coupon_redemptions cr JOIN coupons c USING (coupon_id) WHERE CAST(c.stackable AS VARCHAR) IN ('False','false','0') AND c.percent_off IS NOT NULL GROUP BY 1 HAVING COUNT(*) >= 2),
 ref AS (SELECT currency, CAST(date_trunc('month', issued_at) AS DATE) im, AVG(fx_rate_to_usd) fx FROM invoices WHERE fx_rate_to_usd IS NOT NULL GROUP BY 1,2),
 x AS (SELECT i.subscription_id, i.account_id, i.issued_at, i.discount_amount*r.fx disc_usd, i.subtotal*r.fx sub_usd, nr.max_pct, nr.sum_pct
       FROM invoices i JOIN nr USING (subscription_id) JOIN ref r ON r.currency=i.currency AND r.im=CAST(date_trunc('month', i.issued_at) AS DATE) WHERE i.status='paid' AND i.discount_amount>0)
SELECT COUNT(DISTINCT subscription_id) stacked_subs, COUNT(*) invoices, ROUND(SUM(disc_usd),0) actual_discount_usd, ROUND(SUM(sub_usd*max_pct/100.0),0) expected_discount_usd,
       ROUND(SUM(disc_usd - sub_usd*max_pct/100.0),0) excess_discount_usd_to_date, MIN(issued_at) first_inv, MAX(issued_at) last_inv
FROM x;
SELECT * FROM lk_stack_hist;

-- name: rc03b_stacking_still_running
-- How much excess discount is STILL running (forward-looking, annualized)? Look at each stacker's latest invoice.
DROP TABLE IF EXISTS lk_stack_fwd;
CREATE TABLE lk_stack_fwd AS
WITH nr AS (SELECT cr.subscription_id, MAX(c.percent_off) max_pct FROM coupon_redemptions cr JOIN coupons c USING (coupon_id)
            WHERE CAST(c.stackable AS VARCHAR) IN ('False','false','0') AND c.percent_off IS NOT NULL GROUP BY 1 HAVING COUNT(*) >= 2),
 ref AS (SELECT currency, CAST(date_trunc('month', issued_at) AS DATE) im, AVG(fx_rate_to_usd) fx FROM invoices WHERE fx_rate_to_usd IS NOT NULL GROUP BY 1,2),
 l AS (SELECT i.subscription_id, i.status, i.discount_amount*r.fx d, i.subtotal*r.fx s, nr.max_pct, (CAST(substr(CAST(i.period_end AS VARCHAR),1,4) AS INTEGER)-CAST(substr(CAST(i.period_start AS VARCHAR),1,4) AS INTEGER))*12 + CAST(substr(CAST(i.period_end AS VARCHAR),6,2) AS INTEGER)-CAST(substr(CAST(i.period_start AS VARCHAR),6,2) AS INTEGER) nm,
        ROW_NUMBER() OVER (PARTITION BY i.subscription_id ORDER BY i.issued_at DESC) rn
       FROM invoices i JOIN nr USING (subscription_id) JOIN ref r ON r.currency=i.currency AND r.im=CAST(date_trunc('month', i.issued_at) AS DATE) WHERE i.status='paid')
SELECT COUNT(*) subs, SUM(CASE WHEN d>0 THEN 1 ELSE 0 END) latest_invoice_still_discounted,
       ROUND(SUM(CASE WHEN d>0 THEN (d - s*max_pct/100.0)/nm*12 ELSE 0 END),0) excess_discount_arr_still_running
FROM l WHERE rn=1 AND subscription_id IN (SELECT subscription_id FROM subscriptions WHERE status<>'canceled');
SELECT * FROM lk_stack_fwd;

-- name: rc04_unbilled_seats
-- H-unbilled usage: seats provisioned but not billed. Use contracted price per seat (subscriptions.price_per_seat_usd).
-- cash_leaked_to_date = sum over months of (provisioned - billed) x price; arr_run_rate = latest-month gap x price x 12.
DROP TABLE IF EXISTS lk_seats;
CREATE TABLE lk_seats AS
WITH g AS (SELECT u.account_id, u.month_start, u.seats_provisioned - u.seats_billed gap, s.price_per_seat_usd pps, u.seats_sso_provisioned sso
           FROM seat_usage_monthly u JOIN subscriptions s USING (account_id) WHERE u.seats_billed>0 AND u.seats_provisioned > u.seats_billed),
 latest AS (SELECT account_id, MAX(month_start) mx FROM seat_usage_monthly WHERE seats_billed>0 GROUP BY 1)
SELECT COUNT(DISTINCT g.account_id) accounts_ever, MIN(g.month_start) first_month,
       ROUND(SUM(g.gap*g.pps),0) cash_leaked_to_date,
       ROUND(SUM(CASE WHEN g.month_start=l.mx AND s2.status<>'canceled' THEN g.gap ELSE 0 END),0) unbilled_seats_now,
       ROUND(SUM(CASE WHEN g.month_start=l.mx AND s2.status<>'canceled' THEN g.gap*g.pps*12 ELSE 0 END),0) arr_run_rate
FROM g JOIN latest l ON l.account_id=g.account_id JOIN subscriptions s2 ON s2.account_id=g.account_id;
SELECT * FROM lk_seats;

-- name: rc04b_unbilled_seat_profile
-- Is it concentrated? (plan, SSO, size of gap). A tight pattern (all Business+SSO) points to a systematic process gap, not random drift.
SELECT u.plan, a.sso_enabled, COUNT(*) account_months, COUNT(DISTINCT u.account_id) accounts, ROUND(AVG(u.seats_provisioned - u.seats_billed),1) avg_gap,
       ROUND(AVG(1.0*u.seats_sso_provisioned/NULLIF(u.seats_provisioned,0)),2) sso_share
FROM seat_usage_monthly u JOIN accounts a USING (account_id) WHERE u.seats_billed>0 AND u.seats_provisioned>u.seats_billed GROUP BY 1,2;

-- name: rc05_pricing_error_is_one_off
-- H-pricing: the half-price invoices (Mar 3-9 2025). Is it recurring (ARR) or one-time? Compare each affected account's next invoice unit price.
WITH ref AS (SELECT currency, CAST(date_trunc('month', issued_at) AS DATE) im, AVG(fx_rate_to_usd) fx FROM invoices WHERE fx_rate_to_usd IS NOT NULL GROUP BY 1,2),
 bad AS (SELECT invoice_id, subscription_id, issued_at, unit_price*r.fx unit_usd FROM invoices i JOIN ref r ON r.currency=i.currency AND r.im=CAST(date_trunc('month', i.issued_at) AS DATE)
         WHERE i.status='paid' AND i.issued_at >= '2025-03-03' AND i.issued_at < '2025-03-10' AND i.billing_reason='subscription_cycle' AND i.unit_price*r.fx < 15 AND i.seats_billed>0 AND
         EXISTS (SELECT 1 FROM plan_changes pc WHERE pc.subscription_id=i.subscription_id AND pc.to_plan='business' AND pc.changed_at<=i.issued_at))
SELECT COUNT(*) invoices_in_window_priced_like_pro, COUNT(DISTINCT subscription_id) subs,
       SUM(CASE WHEN EXISTS (SELECT 1 FROM invoices n WHERE n.subscription_id=bad.subscription_id AND n.issued_at>bad.issued_at) THEN 1 ELSE 0 END) have_later_invoice
FROM bad;

-- name: rc06_funnel_conversion_by_signup_quarter
-- H-new-business: net new fell too. Did signups fall (acquisition) or did conversion fall (monetisation)?
-- Cohort = signup quarter; paid_90d = first_paid within 90 days of signup. Internal test accounts excluded.
SELECT substr(CAST(created_at AS VARCHAR),1,4) || '-Q' || CASE WHEN substr(CAST(created_at AS VARCHAR),6,2) IN ('01','02','03') THEN '1' WHEN substr(CAST(created_at AS VARCHAR),6,2) IN ('04','05','06') THEN '2' WHEN substr(CAST(created_at AS VARCHAR),6,2) IN ('07','08','09') THEN '3' ELSE '4' END cohort,
       COUNT(*) signups, SUM(CASE WHEN first_paid_at IS NOT NULL AND date_diff('day', created_at, first_paid_at) <= 90 THEN 1 ELSE 0 END) paid_90d,
       ROUND(100.0*SUM(CASE WHEN first_paid_at IS NOT NULL AND date_diff('day', created_at, first_paid_at) <= 90 THEN 1 ELSE 0 END)/COUNT(*),2) conv_90d_pct
FROM accounts WHERE email_domain IS NULL OR email_domain <> 'flowdesk.com' GROUP BY 1 ORDER BY 1;

-- name: rc07_voluntary_churn_hazard_by_year_and_interval
-- H-product/market: is voluntary churn higher in 2025 for like-for-like customers? Monthly voluntary logo churn, by billing interval.
SELECT substr(CAST(m AS VARCHAR),1,4) yr, interval_eom, SUM(CASE WHEN prev>0 THEN 1 ELSE 0 END) account_months,
       SUM(CASE WHEN move='churn' AND churn_type='voluntary' THEN 1 ELSE 0 END) vol_churns,
       ROUND(100.0*SUM(CASE WHEN move='churn' AND churn_type='voluntary' THEN 1 ELSE 0 END)/SUM(CASE WHEN prev>0 THEN 1 ELSE 0 END),2) vol_logo_churn_pct_month
FROM acct_move WHERE m >= '2024-01-01' GROUP BY 1,2 ORDER BY 2,1;

-- name: rc08_reported_vs_corrected_revenue_by_year
-- H-reporting: if finance sums invoices.total_usd, how wrong is revenue? Corrected = total_amount x ref fx.
WITH ref AS (SELECT currency, CAST(date_trunc('month', issued_at) AS DATE) im, AVG(fx_rate_to_usd) fx FROM invoices WHERE fx_rate_to_usd IS NOT NULL GROUP BY 1,2)
SELECT substr(CAST(i.issued_at AS VARCHAR),1,4) yr, ROUND(SUM(COALESCE(i.total_usd,0)),0) reported_billings_usd, ROUND(SUM(i.total_amount*r.fx),0) corrected_billings_usd,
       ROUND(SUM(COALESCE(i.total_usd,0)) - SUM(i.total_amount*r.fx),0) reporting_error_usd
FROM invoices i JOIN ref r ON r.currency=i.currency AND r.im=CAST(date_trunc('month', i.issued_at) AS DATE) WHERE i.status='paid' GROUP BY 1 ORDER BY 1;

-- name: rc09_refund_rate_by_year
-- H-refunds: is refund volume rising? Refunds converted at ref fx as % of corrected billings.
WITH ref AS (SELECT currency, AVG(fx_rate_to_usd) fx FROM invoices WHERE fx_rate_to_usd IS NOT NULL GROUP BY 1)
SELECT substr(CAST(r.refunded_at AS VARCHAR),1,4) yr, COUNT(*) refunds, ROUND(SUM(r.amount*f.fx),0) refunded_usd FROM refunds r JOIN ref f ON f.currency=r.currency GROUP BY 1 ORDER BY 1;

-- name: rc06b_conversion_by_channel_matured_cohorts
-- Is the conversion drop a channel-mix story? Compare 2024 H1 vs 2025 H1 cohorts (both fully matured: 90-day window closed) by clean channel.
SELECT d.channel, SUM(CASE WHEN a.created_at < '2024-07-01' AND a.created_at >= '2024-01-01' THEN 1 ELSE 0 END) signups_h1_24,
  ROUND(100.0*SUM(CASE WHEN a.created_at >= '2024-01-01' AND a.created_at < '2024-07-01' AND a.first_paid_at IS NOT NULL AND date_diff('day', a.created_at, a.first_paid_at)<=90 THEN 1 ELSE 0 END)/SUM(CASE WHEN a.created_at >= '2024-01-01' AND a.created_at < '2024-07-01' THEN 1 ELSE 0 END),1) conv_h1_24,
  SUM(CASE WHEN a.created_at >= '2025-01-01' AND a.created_at < '2025-07-01' THEN 1 ELSE 0 END) signups_h1_25,
  ROUND(100.0*SUM(CASE WHEN a.created_at >= '2025-01-01' AND a.created_at < '2025-07-01' AND a.first_paid_at IS NOT NULL AND date_diff('day', a.created_at, a.first_paid_at)<=90 THEN 1 ELSE 0 END)/SUM(CASE WHEN a.created_at >= '2025-01-01' AND a.created_at < '2025-07-01' THEN 1 ELSE 0 END),1) conv_h1_25
FROM accounts a JOIN acct_dim d USING (account_id) WHERE a.email_domain IS NULL OR a.email_domain <> 'flowdesk.com' GROUP BY 1 ORDER BY 1;
