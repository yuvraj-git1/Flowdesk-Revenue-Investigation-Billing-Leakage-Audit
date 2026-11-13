-- ============================================================================
-- STAGE 5: QUANTIFY LEAKAGE + RECOVERABLE ARR (DuckDB). Run after 03 and 04 (uses lk_* tables built in 04).
-- Two separate questions:  (A) how much of the 2025 shortfall does each driver explain?  (B) how much ARR can we win back?
-- All assumptions are visible in the `p` parameter CTEs so a reviewer can change them and re-run.
-- ============================================================================

-- name: lk01_shortfall_attribution
-- (A) Attribution of the drop in net new MRR (2025 vs 2024). Churn changes split into
--   VOLUME effect (a bigger MRR base naturally churns more dollars at the same rate) and
--   RATE effect (customers leaving faster). The outage part of involuntary churn = actual churn in Feb-Jun 2025 above the
--   baseline involuntary rate observed in the months with working dunning (Jan 2025 and Jul-Dec 2025).
WITH y AS (SELECT substr(CAST(m AS VARCHAR),1,4) yr, SUM(prev) opn, -SUM(CASE WHEN move='churn' AND churn_type='voluntary' THEN delta ELSE 0 END) vol,
             -SUM(CASE WHEN move='churn' AND churn_type='involuntary' THEN delta ELSE 0 END) inv,
             SUM(CASE WHEN move='new' THEN delta ELSE 0 END) new_, SUM(CASE WHEN move='expansion' THEN delta ELSE 0 END) exp_,
             SUM(CASE WHEN move='contraction' THEN delta ELSE 0 END) con_, SUM(delta) net FROM acct_move WHERE m>='2024-01-01' GROUP BY 1),
 a AS (SELECT * FROM y WHERE yr='2024'), b AS (SELECT * FROM y WHERE yr='2025'),
 base AS (SELECT -SUM(CASE WHEN move='churn' AND churn_type='involuntary' THEN delta ELSE 0 END)/SUM(prev) r FROM acct_move WHERE m IN ('2025-01-01','2025-07-01','2025-08-01','2025-09-01','2025-10-01','2025-11-01','2025-12-01')),
 outage AS (SELECT SUM(-CASE WHEN move='churn' AND churn_type='involuntary' THEN delta ELSE 0 END) - MAX(base.r)*SUM(prev) ex FROM acct_move, base WHERE m>='2025-02-01' AND m<='2025-06-01'),
 c AS (SELECT 'new business (conversion decline)' driver, b.new_-a.new_ mrr FROM a,b UNION ALL
       SELECT 'expansion', b.exp_-a.exp_ FROM a,b UNION ALL SELECT 'contraction', b.con_-a.con_ FROM a,b UNION ALL
       SELECT 'voluntary churn - volume effect (bigger base)', -(a.vol/a.opn)*(b.opn-a.opn) FROM a,b UNION ALL
       SELECT 'voluntary churn - rate effect (customers leaving faster)', -((b.vol/b.opn)-(a.vol/a.opn))*b.opn FROM a,b UNION ALL
       SELECT 'involuntary churn - volume effect', -(a.inv/a.opn)*(b.opn-a.opn) FROM a,b UNION ALL
       SELECT 'involuntary churn - dunning outage Feb-Jun 2025', -outage.ex FROM outage UNION ALL
       SELECT 'involuntary churn - other rate effect', -((b.inv/b.opn)-(a.inv/a.opn))*b.opn + outage.ex FROM a,b,outage)
SELECT driver, ROUND(mrr,0) mrr_effect, ROUND(mrr*12,0) arr_effect, ROUND(100.0*mrr/(SELECT b.net-a.net FROM a,b),1) pct_of_shortfall FROM c
UNION ALL SELECT 'TOTAL (net new MRR 2025 minus 2024)', ROUND(b.net-a.net,0), ROUND((b.net-a.net)*12,0), 100.0 FROM a,b;

-- name: lk02_stacking_peak_run_rate
-- Peak ANNUALISED excess discount (list vs expected single coupon) across months: spread each stacker invoice over its service months.
WITH nr AS (SELECT cr.subscription_id, MAX(c.percent_off) max_pct FROM coupon_redemptions cr JOIN coupons c USING (coupon_id)
            WHERE CAST(c.stackable AS VARCHAR) IN ('False','false','0') AND c.percent_off IS NOT NULL GROUP BY 1 HAVING COUNT(*)>=2),
 ref AS (SELECT currency, CAST(date_trunc('month', issued_at) AS DATE) im, AVG(fx_rate_to_usd) fx FROM invoices WHERE fx_rate_to_usd IS NOT NULL GROUP BY 1,2),
 x AS (SELECT i.invoice_id, (i.discount_amount - i.subtotal*nr.max_pct/100.0)*r.fx ex,
        (CAST(substr(CAST(i.period_end AS VARCHAR),1,4) AS INTEGER)-CAST(substr(CAST(i.period_start AS VARCHAR),1,4) AS INTEGER))*12 + CAST(substr(CAST(i.period_end AS VARCHAR),6,2) AS INTEGER)-CAST(substr(CAST(i.period_start AS VARCHAR),6,2) AS INTEGER) nm,
        CAST(date_trunc('month', i.period_start) AS DATE) pm
       FROM invoices i JOIN nr USING (subscription_id) JOIN ref r ON r.currency=i.currency AND r.im=CAST(date_trunc('month', i.issued_at) AS DATE) WHERE i.status='paid' AND i.discount_amount>0),
 j AS (SELECT mo.m, SUM(x.ex/x.nm) ex_mrr FROM x JOIN months mo ON mo.m>=x.pm AND mo.mi < (SELECT mi FROM months WHERE m=x.pm)+x.nm GROUP BY 1)
SELECT m, ROUND(ex_mrr,0) excess_discount_mrr, ROUND(ex_mrr*12,0) annualised FROM j ORDER BY 1;

-- name: lk03_pricing_and_refund_one_offs
-- One-time dollar leaks (no ARR). Pricing: invoices billed at <60% of the contracted price at invoice date (see dq05b). Refunds: 2nd refund on a payment.
DROP TABLE IF EXISTS lk_oneoffs;
CREATE TABLE lk_oneoffs AS
WITH ref AS (SELECT currency, CAST(date_trunc('month', issued_at) AS DATE) m, AVG(fx_rate_to_usd) fx FROM invoices WHERE fx_rate_to_usd IS NOT NULL GROUP BY 1,2),
 t AS (SELECT i.invoice_id, i.account_id, i.unit_price*r.fx unit_usd, i.subtotal*r.fx subtotal_usd,
        (SELECT pc.to_plan FROM plan_changes pc WHERE pc.subscription_id=i.subscription_id AND pc.changed_at<=i.issued_at ORDER BY pc.changed_at DESC, pc.plan_change_id DESC LIMIT 1) plan_then,
        (SELECT pc.to_interval FROM plan_changes pc WHERE pc.subscription_id=i.subscription_id AND pc.changed_at<=i.issued_at ORDER BY pc.changed_at DESC, pc.plan_change_id DESC LIMIT 1) interval_then
       FROM invoices i JOIN ref r ON r.currency=i.currency AND r.m=CAST(date_trunc('month', i.issued_at) AS DATE) WHERE i.status='paid'),
 e AS (SELECT *, (CASE plan_then WHEN 'business' THEN 24.0 ELSE 12.0 END)*(CASE interval_then WHEN 'annual' THEN 0.8 ELSE 1.0 END) exp_usd FROM t),
 pr AS (SELECT COUNT(*) n, COUNT(DISTINCT account_id) accts, SUM(subtotal_usd/(unit_usd/exp_usd) - subtotal_usd) usd FROM e WHERE unit_usd/exp_usd < 0.6),
 rk AS (SELECT r.*, ROW_NUMBER() OVER (PARTITION BY payment_id ORDER BY refunded_at, refund_id) rn FROM refunds r),
 rf AS (SELECT COUNT(*) n, COUNT(DISTINCT payment_id) accts, SUM(rk.amount*(SELECT AVG(fx_rate_to_usd) FROM invoices WHERE currency=rk.currency AND fx_rate_to_usd IS NOT NULL)) usd FROM rk WHERE rn>1)
SELECT 'pricing_error' cause, n rows_, accts accounts, ROUND(usd,0) one_time_usd FROM pr UNION ALL SELECT 'duplicate_refunds', n, accts, ROUND(usd,0) FROM rf;
SELECT * FROM lk_oneoffs;

-- name: lk04_leakage_register
-- (B) THE REGISTER: per cause -> accounts, cash leaked to date, ARR impact today, recoverable ARR (low / base / high).
-- Assumptions (edit here):  dunning win-back of already-churned accounts 20% / 40% / 60% of the ARR retries would have saved;
--   stacking: forward discount removable 50% / 100% / 100%;  unbilled seats: true-up success 50% / 75% / 100% (customers may push back or churn).
WITH p AS (SELECT 0.20 d_lo, 0.40 d_base, 0.60 d_hi, 0.50 s_lo, 1.0 s_base, 1.0 s_hi, 0.50 u_lo, 0.75 u_base, 1.0 u_hi),
 dun AS (SELECT accounts_no_retry n, arr_hit, arr_recoverable_expected exp_arr FROM lk_dunning),
 stk AS (SELECT h.stacked_subs n, h.excess_discount_usd_to_date cash, f.excess_discount_arr_still_running run FROM lk_stack_hist h, lk_stack_fwd f),
 seat AS (SELECT accounts_ever n, cash_leaked_to_date cash, arr_run_rate run FROM lk_seats)
SELECT 'Dunning outage (failed payments never retried, Feb-Jun 2025)' cause, dun.n accounts, ROUND(dun.exp_arr,0) arr_lost_to_cause, 0 cash_leaked_to_date, ROUND(dun.exp_arr,0) arr_impact_today,
       ROUND(dun.exp_arr*p.d_lo,0) recoverable_low, ROUND(dun.exp_arr*p.d_base,0) recoverable_base, ROUND(dun.exp_arr*p.d_hi,0) recoverable_high, 'proven' evidence_strength FROM dun, p UNION ALL
SELECT 'Unbilled SSO seats (provisioned > billed)', seat.n, ROUND(seat.run,0), ROUND(seat.cash,0), ROUND(seat.run,0), ROUND(seat.run*p.u_lo,0), ROUND(seat.run*p.u_base,0), ROUND(seat.run*p.u_hi,0), 'proven' FROM seat, p UNION ALL
SELECT 'Coupon stacking (2+ non-stackable coupons)', stk.n, ROUND(stk.run,0), ROUND(stk.cash,0), ROUND(stk.run,0), ROUND(stk.run*p.s_lo,0), ROUND(stk.run*p.s_base,0), ROUND(stk.run*p.s_hi,0), 'proven (ARR still running is small; most coupons expired)' FROM stk, p UNION ALL
SELECT 'Pricing error (billed at half price, Mar 3-9 2025)', rows_, 0, one_time_usd, 0, 0, 0, 0, 'proven; one-time back-bill only' FROM lk_oneoffs WHERE cause='pricing_error' UNION ALL
SELECT 'Duplicate refunds', rows_, 0, one_time_usd, 0, 0, 0, 0, 'proven; one-time recovery only' FROM lk_oneoffs WHERE cause='duplicate_refunds';
