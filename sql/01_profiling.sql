-- ============================================================================
-- STAGE 1: PROFILING  (DuckDB)   Why: before any metric, prove what one row means
-- (grain), which columns identify it (keys), and which columns can't be trusted.
-- ============================================================================

-- name: p01_row_counts_and_date_ranges
-- Why: volume sanity + the time window each table covers (catches truncated loads).
SELECT 'accounts' t, COUNT(*) n, MIN(created_at) first_ts, MAX(created_at) last_ts FROM accounts UNION ALL
SELECT 'subscriptions', COUNT(*), MIN(started_at), MAX(started_at) FROM subscriptions UNION ALL
SELECT 'plan_changes', COUNT(*), MIN(changed_at), MAX(changed_at) FROM plan_changes UNION ALL
SELECT 'invoices', COUNT(*), MIN(issued_at), MAX(issued_at) FROM invoices UNION ALL
SELECT 'payments', COUNT(*), MIN(attempted_at), MAX(attempted_at) FROM payments UNION ALL
SELECT 'refunds', COUNT(*), MIN(refunded_at), MAX(refunded_at) FROM refunds UNION ALL
SELECT 'coupons', COUNT(*), MIN(valid_from), MAX(valid_to) FROM coupons UNION ALL
SELECT 'coupon_redemptions', COUNT(*), MIN(redeemed_at), MAX(redeemed_at) FROM coupon_redemptions UNION ALL
SELECT 'seat_usage_monthly', COUNT(*), MIN(month_start), MAX(month_start) FROM seat_usage_monthly;

-- name: p02_primary_key_check
-- Why: a "key" that repeats silently double-counts every join downstream.
SELECT 'accounts.account_id' k, COUNT(*) n, COUNT(DISTINCT account_id) d FROM accounts UNION ALL
SELECT 'subscriptions.subscription_id', COUNT(*), COUNT(DISTINCT subscription_id) FROM subscriptions UNION ALL
SELECT 'subscriptions.account_id (1 sub/acct?)', COUNT(*), COUNT(DISTINCT account_id) FROM subscriptions UNION ALL
SELECT 'plan_changes.plan_change_id', COUNT(*), COUNT(DISTINCT plan_change_id) FROM plan_changes UNION ALL
SELECT 'invoices.invoice_id', COUNT(*), COUNT(DISTINCT invoice_id) FROM invoices UNION ALL
SELECT 'invoices.(subscription,period_start)', COUNT(*), COUNT(DISTINCT subscription_id || '|' || period_start) FROM invoices UNION ALL
SELECT 'payments.payment_id', COUNT(*), COUNT(DISTINCT payment_id) FROM payments UNION ALL
SELECT 'payments.(invoice,attempt)', COUNT(*), COUNT(DISTINCT invoice_id || '|' || attempt_number) FROM payments UNION ALL
SELECT 'refunds.refund_id', COUNT(*), COUNT(DISTINCT refund_id) FROM refunds UNION ALL
SELECT 'refunds.payment_id (1 refund/payment?)', COUNT(*), COUNT(DISTINCT payment_id) FROM refunds UNION ALL
SELECT 'coupon_redemptions.id', COUNT(*), COUNT(DISTINCT redemption_id) FROM coupon_redemptions UNION ALL
SELECT 'seat_usage.(account,month)', COUNT(*), COUNT(DISTINCT account_id || '|' || month_start) FROM seat_usage_monthly;

-- name: p03_foreign_key_orphans
-- Why: orphans mean lost revenue rows on INNER JOIN. Expect 0; anything else is an issue.
SELECT 'subscriptions->accounts' fk, COUNT(*) orphans FROM subscriptions s LEFT JOIN accounts a USING (account_id) WHERE a.account_id IS NULL UNION ALL
SELECT 'plan_changes->subscriptions', COUNT(*) FROM plan_changes p LEFT JOIN subscriptions s USING (subscription_id) WHERE s.subscription_id IS NULL UNION ALL
SELECT 'invoices->subscriptions', COUNT(*) FROM invoices i LEFT JOIN subscriptions s USING (subscription_id) WHERE s.subscription_id IS NULL UNION ALL
SELECT 'payments->invoices', COUNT(*) FROM payments p LEFT JOIN invoices i USING (invoice_id) WHERE i.invoice_id IS NULL UNION ALL
SELECT 'refunds->payments', COUNT(*) FROM refunds r LEFT JOIN payments p USING (payment_id) WHERE p.payment_id IS NULL UNION ALL
SELECT 'redemptions->coupons', COUNT(*) FROM coupon_redemptions r LEFT JOIN coupons c USING (coupon_id) WHERE c.coupon_id IS NULL UNION ALL
SELECT 'invoices.coupon_redemption->redemptions', COUNT(*) FROM invoices i LEFT JOIN coupon_redemptions r ON r.redemption_id = i.coupon_redemption_id WHERE i.coupon_redemption_id IS NOT NULL AND r.redemption_id IS NULL;

-- name: p04_null_profile
-- Why: a column that is 12% NULL is a different column than one that is 0% NULL.
SELECT 'invoices' t, COUNT(*) n, SUM(CASE WHEN fx_rate_to_usd IS NULL THEN 1 ELSE 0 END) fx_null,
       SUM(CASE WHEN total_usd IS NULL THEN 1 ELSE 0 END) total_usd_null, SUM(CASE WHEN unit_price IS NULL THEN 1 ELSE 0 END) unit_price_null FROM invoices UNION ALL
SELECT 'accounts', COUNT(*), SUM(CASE WHEN industry IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN email_domain IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN country IS NULL THEN 1 ELSE 0 END) FROM accounts UNION ALL
SELECT 'payments', COUNT(*), SUM(CASE WHEN processor_ref IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN failure_code IS NULL THEN 1 ELSE 0 END), 0 FROM payments;

-- name: p05_categoricals
-- Why: enumerations tell you the states a row can be in; unexpected values are findings.
SELECT 'subscriptions.status' col, status val, COUNT(*) n FROM subscriptions GROUP BY 2 UNION ALL
SELECT 'subscriptions.cancellation_source', COALESCE(cancellation_source,'(null)'), COUNT(*) FROM subscriptions GROUP BY 2 UNION ALL
SELECT 'subscriptions.plan|interval', plan || '|' || billing_interval, COUNT(*) FROM subscriptions GROUP BY 2 UNION ALL
SELECT 'invoices.status', status, COUNT(*) FROM invoices GROUP BY 2 UNION ALL
SELECT 'invoices.currency', currency, COUNT(*) FROM invoices GROUP BY 2 UNION ALL
SELECT 'payments.status|attempt', status || '|' || CAST(attempt_number AS VARCHAR), COUNT(*) FROM payments GROUP BY 2 UNION ALL
SELECT 'payments.method', payment_method, COUNT(*) FROM payments GROUP BY 2 UNION ALL
SELECT 'plan_changes.type', change_type, COUNT(*) FROM plan_changes GROUP BY 2 UNION ALL
SELECT 'refunds.reason', reason, COUNT(*) FROM refunds GROUP BY 2 UNION ALL
SELECT 'accounts.lifecycle', lifecycle_stage, COUNT(*) FROM accounts GROUP BY 2 UNION ALL
SELECT 'accounts.motion', acquisition_motion, COUNT(*) FROM accounts GROUP BY 2
ORDER BY 1, 3 DESC;

-- name: p06_channel_labels
-- Why: the channel dimension is used for segmentation later; check how clean it is.
SELECT signup_source, COUNT(*) accounts FROM accounts GROUP BY 1 ORDER BY 2 DESC;

-- name: p07_monthly_pulse
-- Why: a first look at the story: signups, new paid, invoices and billed USD by month.
WITH s AS (SELECT CAST(date_trunc('month', created_at) AS DATE) m, COUNT(*) signups FROM accounts GROUP BY 1),
     p AS (SELECT CAST(date_trunc('month', first_paid_at) AS DATE) m, COUNT(*) new_paid FROM accounts WHERE first_paid_at IS NOT NULL GROUP BY 1),
     i AS (SELECT CAST(date_trunc('month', issued_at) AS DATE) m, COUNT(*) invoices, ROUND(SUM(total_usd),0) billed_usd_reported FROM invoices WHERE status='paid' GROUP BY 1)
SELECT s.m, signups, new_paid, invoices, billed_usd_reported FROM s LEFT JOIN p USING (m) LEFT JOIN i USING (m) ORDER BY 1;
