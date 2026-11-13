-- ============================================================================
-- STAGE 6: TABLEAU EXTRACTS (DuckDB). Run after 03-05. Each block's result is saved to outputs/ and copied to tableau/.
-- Design: one MONTHLY LEAKAGE table in long format (month x category x mrr_usd) so a single stacked-bar view can drill from
-- "MRR waterfall" into leakage categories without extra joins in Tableau.
-- ============================================================================

-- name: tb01_dunning_failed_accounts
-- Accounts whose failed first payment got NO retry at all (the process gap), with MRR at risk.
DROP TABLE IF EXISTS lk_dunning_accounts;
CREATE TABLE lk_dunning_accounts AS
SELECT p.invoice_id, i.account_id, CAST(date_trunc('month', p.attempted_at) AS DATE) fail_month
FROM payments p JOIN invoices i USING (invoice_id) WHERE p.attempt_number=1 AND p.status='failed'
  AND NOT EXISTS (SELECT 1 FROM payments q WHERE q.invoice_id=p.invoice_id AND q.attempt_number>1) AND p.attempted_at < '2025-12-01';
SELECT fail_month, COUNT(*) accounts FROM lk_dunning_accounts GROUP BY 1 ORDER BY 1;

-- name: tb02_leakage_monthly_long
-- Categories (MRR dollars per month): dunning_outage_lost_mrr = MRR that churned involuntarily for accounts in the no-retry set;
-- coupon_stacking_excess_discount, unbilled_sso_seats = ongoing monthly leak; pricing_error_one_time = underbilled invoice dollars (not MRR).
SELECT m, 'dunning_outage_lost_mrr' category, ROUND(SUM(-delta),0) mrr_usd FROM acct_move WHERE move='churn' AND churn_type='involuntary' AND account_id IN (SELECT account_id FROM lk_dunning_accounts) GROUP BY 1
UNION ALL SELECT m, 'coupon_stacking_excess_discount', excess_discount_mrr FROM (
   WITH nr AS (SELECT cr.subscription_id, MAX(c.percent_off) max_pct FROM coupon_redemptions cr JOIN coupons c USING (coupon_id) WHERE CAST(c.stackable AS VARCHAR) IN ('False','false','0') AND c.percent_off IS NOT NULL GROUP BY 1 HAVING COUNT(*)>=2),
   ref AS (SELECT currency, CAST(date_trunc('month', issued_at) AS DATE) im, AVG(fx_rate_to_usd) fx FROM invoices WHERE fx_rate_to_usd IS NOT NULL GROUP BY 1,2),
   x AS (SELECT (i.discount_amount - i.subtotal*nr.max_pct/100.0)*r.fx ex, (CAST(substr(CAST(i.period_end AS VARCHAR),1,4) AS INTEGER)-CAST(substr(CAST(i.period_start AS VARCHAR),1,4) AS INTEGER))*12 + CAST(substr(CAST(i.period_end AS VARCHAR),6,2) AS INTEGER)-CAST(substr(CAST(i.period_start AS VARCHAR),6,2) AS INTEGER) nm, CAST(date_trunc('month', i.period_start) AS DATE) pm
         FROM invoices i JOIN nr USING (subscription_id) JOIN ref r ON r.currency=i.currency AND r.im=CAST(date_trunc('month', i.issued_at) AS DATE) WHERE i.status='paid' AND i.discount_amount>0)
   SELECT mo.m, ROUND(SUM(x.ex/x.nm),0) excess_discount_mrr FROM x JOIN months mo ON mo.m>=x.pm AND mo.mi < (SELECT mi FROM months WHERE m=x.pm)+x.nm GROUP BY 1) z
UNION ALL SELECT u.month_start, 'unbilled_sso_seats', ROUND(SUM((u.seats_provisioned-u.seats_billed)*s.price_per_seat_usd),0)
   FROM seat_usage_monthly u JOIN subscriptions s USING (account_id) WHERE u.seats_billed>0 AND u.seats_provisioned>u.seats_billed GROUP BY 1
UNION ALL SELECT CAST('2025-03-01' AS DATE), 'pricing_error_one_time', one_time_usd FROM lk_oneoffs WHERE cause='pricing_error'
ORDER BY 1, 2;

-- name: tb03_dq_timezone_impact
-- How many EUR/INR invoices land in the WRONG month because issued_at is local time? Shift back by the observed offset (EUR 1h, INR 5.5h).
SELECT currency, COUNT(*) invoices_near_month_start,
       SUM(CASE WHEN CAST(substr(CAST(issued_at AS VARCHAR),9,2) AS INTEGER)=1 AND CAST(substr(CAST(issued_at AS VARCHAR),12,2) AS INTEGER) < CASE WHEN currency='INR' THEN 6 ELSE 1 END THEN 1 ELSE 0 END) misbucketed_by_month
FROM invoices WHERE currency IN ('EUR','INR') GROUP BY 1;
