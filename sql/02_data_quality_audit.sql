-- ============================================================================
-- STAGE 2: DATA QUALITY AUDIT (DuckDB). Each block = one hypothesis + evidence.
-- Convention: "ref fx" = average fx_rate_to_usd for that currency & month, taken
-- only from rows where fx is present. It lets us re-price rows with bad/missing USD.
-- ============================================================================

-- name: dq01_duplicate_accounts_by_domain
-- H1: some owners signed up twice. Test: same non-null email_domain, created <=30 days apart.
-- Why domain: it is the strongest identity signal we have; names alone collide.
WITH pairs AS (
  SELECT a.account_id first_id, b.account_id dup_id, a.company_name n1, b.company_name n2,
         date_diff('day', a.created_at, b.created_at) gap_days
  FROM accounts a JOIN accounts b ON a.email_domain = b.email_domain AND a.account_id < b.account_id
  WHERE a.email_domain IS NOT NULL AND a.email_domain <> 'flowdesk.com'
    AND b.created_at >= a.created_at AND date_diff('day', a.created_at, b.created_at) <= 30)
SELECT COUNT(*) pairs, COUNT(DISTINCT dup_id) accounts_flagged,
       ROUND(100.0*COUNT(DISTINCT dup_id)/(SELECT COUNT(*) FROM accounts),2) pct_of_accounts,
       SUM(CASE WHEN d.first_paid_at IS NOT NULL THEN 1 ELSE 0 END) flagged_that_ever_paid
FROM pairs p JOIN accounts d ON d.account_id = p.dup_id;

-- name: dq01b_duplicate_examples
SELECT a.account_id first_id, a.company_name first_name, b.account_id dup_id, b.company_name dup_name,
       date_diff('day', a.created_at, b.created_at) gap_days, a.email_domain
FROM accounts a JOIN accounts b ON a.email_domain = b.email_domain AND a.account_id < b.account_id
WHERE a.email_domain <> 'flowdesk.com' AND date_diff('day', a.created_at, b.created_at) BETWEEN 0 AND 30 ORDER BY 1 LIMIT 8;

-- name: dq01b2_duplicates_webmail_by_name
-- Owners on webmail have NULL domain, so use a weaker key: first 8 letters of the lowercased, space-free name + same country,
-- created <=30 days apart. Weaker evidence: treat as SUGGESTIVE (could be two genuinely similar companies).
WITH k AS (SELECT account_id, created_at, country, substr(lower(replace(company_name,' ','')),1,8) nk FROM accounts WHERE email_domain IS NULL)
SELECT COUNT(DISTINCT b.account_id) webmail_accounts_flagged
FROM k a JOIN k b ON a.nk=b.nk AND a.country=b.country AND a.account_id<b.account_id AND date_diff('day', a.created_at, b.created_at) BETWEEN 0 AND 30;

-- name: dq01c_internal_test_accounts
-- Natural noise candidate: company's own domain should be excluded from growth metrics.
SELECT COUNT(*) accounts, MIN(created_at) first_seen, MAX(created_at) last_seen, SUM(CASE WHEN first_paid_at IS NOT NULL THEN 1 ELSE 0 END) paid
FROM accounts WHERE email_domain = 'flowdesk.com' OR company_name LIKE 'Flowdesk Test%';

-- name: dq02_fx_missing_and_unconverted
-- H2: non-USD invoices may carry missing or wrong USD totals. Three tests per currency:
--  missing = fx/total_usd NULL; unconverted = total_usd == local total_amount (never converted);
--  recomputed = total_amount * ref_fx is the number we trust instead.
WITH ref AS (SELECT currency, CAST(date_trunc('month', issued_at) AS DATE) m, AVG(fx_rate_to_usd) fx
             FROM invoices WHERE fx_rate_to_usd IS NOT NULL GROUP BY 1, 2),
 x AS (SELECT i.currency, i.total_amount, i.total_usd, i.fx_rate_to_usd, i.status, i.total_amount*r.fx recomputed
       FROM invoices i JOIN ref r ON r.currency=i.currency AND r.m = CAST(date_trunc('month', i.issued_at) AS DATE)
       WHERE i.status = 'paid')
SELECT currency, COUNT(*) paid_invoices,
  SUM(CASE WHEN fx_rate_to_usd IS NULL THEN 1 ELSE 0 END) fx_missing,
  SUM(CASE WHEN fx_rate_to_usd IS NOT NULL AND currency <> 'USD' AND ABS(total_usd-total_amount) < 0.01 AND total_amount > 1 THEN 1 ELSE 0 END) unconverted,
  ROUND(SUM(COALESCE(total_usd,0)),0) reported_usd, ROUND(SUM(recomputed),0) recomputed_usd,
  ROUND(SUM(COALESCE(total_usd,0)) - SUM(recomputed),0) reported_minus_true
FROM x GROUP BY 1 ORDER BY 1;

-- name: dq02b_fx_rate_sanity
-- Are the fx rates themselves plausible and stable? (range per currency)
SELECT currency, ROUND(MIN(fx_rate_to_usd),4) min_fx, ROUND(AVG(fx_rate_to_usd),4) avg_fx, ROUND(MAX(fx_rate_to_usd),4) max_fx FROM invoices WHERE fx_rate_to_usd IS NOT NULL GROUP BY 1;

-- name: dq03_timestamp_alignment
-- H3: if all timestamps are UTC, the first payment attempt should come just AFTER invoice issue.
-- Negative minutes = invoice stamped in a different clock than the payment. Grouped by currency.
SELECT i.currency, COUNT(*) n, ROUND(AVG(date_diff('minute', i.issued_at, p.attempted_at))/60.0,2) avg_hours_after_issue,
       ROUND(100.0*SUM(CASE WHEN p.attempted_at < i.issued_at THEN 1 ELSE 0 END)/COUNT(*),1) pct_payment_before_invoice
FROM invoices i JOIN payments p ON p.invoice_id=i.invoice_id AND p.attempt_number=1 GROUP BY 1 ORDER BY 1;

-- name: dq04_duplicate_refunds
-- H4: a payment should be refunded at most once in full. Look for payments with >1 refund.
WITH r AS (SELECT payment_id, COUNT(*) n, SUM(amount) refunded, MIN(refunded_at) t1, MAX(refunded_at) t2, MIN(currency) cur FROM refunds GROUP BY 1 HAVING COUNT(*) > 1)
SELECT r.payment_id, r.n, r.refunded, p.amount payment_amount, r.cur, date_diff('minute', r.t1, r.t2) minutes_apart FROM r JOIN payments p USING (payment_id) ORDER BY 1;

-- name: dq04b_refund_overage_usd
-- Dollar value of the second refund on each double-refunded payment (converted at ref fx).
WITH ranked AS (SELECT r.*, ROW_NUMBER() OVER (PARTITION BY payment_id ORDER BY refunded_at, refund_id) rn FROM refunds r),
 fxr AS (SELECT currency, AVG(fx_rate_to_usd) fx FROM invoices WHERE fx_rate_to_usd IS NOT NULL GROUP BY 1)
SELECT COUNT(*) extra_refund_rows, ROUND(SUM(rk.amount*f.fx),0) extra_refund_usd, ROUND(100.0*COUNT(*)/(SELECT COUNT(*) FROM refunds),2) pct_of_refunds
FROM ranked rk JOIN fxr f ON f.currency=rk.currency WHERE rn > 1;

-- name: dq05_unit_price_anomalies_usd
-- H5: price list is 12/24 (monthly) or 9.60/19.20 (annual). In USD invoices fx=1, so any other unit_price is a pricing error.
SELECT unit_price, COUNT(*) invoices, MIN(CAST(issued_at AS DATE)) first_seen, MAX(CAST(issued_at AS DATE)) last_seen FROM invoices
WHERE currency='USD' GROUP BY 1 ORDER BY 2 DESC LIMIT 12;

-- name: dq05b_price_vs_contract_at_invoice_date
-- Why point-in-time: comparing to the subscription's CURRENT price confounds upgrades/downgrades.
-- Instead take the plan+interval in force on the invoice date from plan_changes, build the expected list price,
-- and compare with unit_price converted to USD at ref fx. Ratio ~0.5 = billed at half the contracted price.
WITH ref AS (SELECT currency, CAST(date_trunc('month', issued_at) AS DATE) m, AVG(fx_rate_to_usd) fx FROM invoices WHERE fx_rate_to_usd IS NOT NULL GROUP BY 1,2),
 t AS (SELECT i.invoice_id, i.subscription_id, i.account_id, i.issued_at, i.seats_billed, i.unit_price*r.fx unit_usd, i.subtotal*r.fx subtotal_usd,
        (SELECT pc.to_plan FROM plan_changes pc WHERE pc.subscription_id=i.subscription_id AND pc.changed_at<=i.issued_at ORDER BY pc.changed_at DESC, pc.plan_change_id DESC LIMIT 1) plan_then,
        (SELECT pc.to_interval FROM plan_changes pc WHERE pc.subscription_id=i.subscription_id AND pc.changed_at<=i.issued_at ORDER BY pc.changed_at DESC, pc.plan_change_id DESC LIMIT 1) interval_then
       FROM invoices i JOIN ref r ON r.currency=i.currency AND r.m=CAST(date_trunc('month', i.issued_at) AS DATE) WHERE i.status='paid'),
 e AS (SELECT *, (CASE plan_then WHEN 'business' THEN 24.0 ELSE 12.0 END)*(CASE interval_then WHEN 'annual' THEN 0.8 ELSE 1.0 END) expected_usd FROM t)
SELECT CASE WHEN unit_usd/expected_usd < 0.6 THEN 'billed ~half price' WHEN unit_usd/expected_usd < 0.9 THEN '0.6-0.9' WHEN unit_usd/expected_usd <= 1.1 THEN 'ok (0.9-1.1)' ELSE '>1.1' END bucket,
       COUNT(*) invoices, COUNT(DISTINCT account_id) accounts, MIN(issued_at) first_seen, MAX(issued_at) last_seen,
       ROUND(SUM(subtotal_usd),0) subtotal_usd, ROUND(SUM(subtotal_usd/(unit_usd/expected_usd) - subtotal_usd),0) implied_underbilling_usd
FROM e GROUP BY 1 ORDER BY 2 DESC;

-- name: dq05c_underpriced_invoice_detail
-- Where do the half-price invoices cluster in time and plan?
WITH ref AS (SELECT currency, CAST(date_trunc('month', issued_at) AS DATE) m, AVG(fx_rate_to_usd) fx FROM invoices WHERE fx_rate_to_usd IS NOT NULL GROUP BY 1,2),
 t AS (SELECT i.invoice_id, i.account_id, i.issued_at, i.unit_price*r.fx unit_usd, i.subtotal*r.fx subtotal_usd, i.seats_billed,
        (SELECT pc.to_plan FROM plan_changes pc WHERE pc.subscription_id=i.subscription_id AND pc.changed_at<=i.issued_at ORDER BY pc.changed_at DESC, pc.plan_change_id DESC LIMIT 1) plan_then,
        (SELECT pc.to_interval FROM plan_changes pc WHERE pc.subscription_id=i.subscription_id AND pc.changed_at<=i.issued_at ORDER BY pc.changed_at DESC, pc.plan_change_id DESC LIMIT 1) interval_then
       FROM invoices i JOIN ref r ON r.currency=i.currency AND r.m=CAST(date_trunc('month', i.issued_at) AS DATE) WHERE i.status='paid'),
 e AS (SELECT *, (CASE plan_then WHEN 'business' THEN 24.0 ELSE 12.0 END)*(CASE interval_then WHEN 'annual' THEN 0.8 ELSE 1.0 END) expected_usd FROM t)
SELECT CAST(date_trunc('month', issued_at) AS DATE) m, plan_then, interval_then, COUNT(*) invoices, COUNT(DISTINCT account_id) accounts,
       MIN(issued_at) first_inv, MAX(issued_at) last_inv, ROUND(SUM(subtotal_usd/(unit_usd/expected_usd) - subtotal_usd),0) underbilled_usd
FROM e WHERE unit_usd/expected_usd < 0.6 GROUP BY 1,2,3 ORDER BY 1;

-- name: dq06_coupon_stacking_by_start_month
-- H6: coupons.stackable=false should mean one coupon per subscription. Count subscriptions with 2+ redemptions of non-stackable coupons.
WITH r AS (SELECT cr.subscription_id, COUNT(*) n_coupons, SUM(CASE WHEN CAST(c.stackable AS VARCHAR) IN ('False','false','0') THEN 1 ELSE 0 END) n_nonstack
           FROM coupon_redemptions cr JOIN coupons c USING (coupon_id) GROUP BY 1)
SELECT CAST(date_trunc('month', s.started_at) AS DATE) start_month, COUNT(*) subs_with_2plus, SUM(CASE WHEN s.status='active' THEN 1 ELSE 0 END) still_active
FROM r JOIN subscriptions s USING (subscription_id) WHERE r.n_nonstack >= 2 GROUP BY 1 ORDER BY 1;

-- name: dq06b_discount_depth
-- How deep is the discount (discount / subtotal) on invoices with 1 vs 2+ coupons?
WITH r AS (SELECT subscription_id, COUNT(*) n FROM coupon_redemptions GROUP BY 1)
SELECT CASE WHEN r.n IS NULL THEN '0 coupons' WHEN r.n=1 THEN '1 coupon' ELSE '2+ coupons' END grp, COUNT(*) invoices,
       ROUND(100.0*SUM(i.discount_amount)/SUM(i.subtotal),1) discount_pct_of_subtotal, ROUND(AVG(100.0*i.discount_amount/i.subtotal),1) avg_invoice_discount_pct
FROM invoices i LEFT JOIN r USING (subscription_id) WHERE i.status='paid' GROUP BY 1 ORDER BY 1;

-- name: dq07_dunning_by_month
-- H7: policy = failed first attempt -> retries on day 1/3/7. For each month: failed first attempts,
-- how many got a retry at all, and how many recovered. A month where retries vanish is a process failure.
WITH f AS (SELECT p.invoice_id, CAST(date_trunc('month', p.attempted_at) AS DATE) m FROM payments p WHERE p.attempt_number=1 AND p.status='failed'),
 x AS (SELECT f.m, f.invoice_id, (SELECT COUNT(*) FROM payments q WHERE q.invoice_id=f.invoice_id AND q.attempt_number>1) retries,
       (SELECT COUNT(*) FROM payments q WHERE q.invoice_id=f.invoice_id AND q.status='succeeded') recovered FROM f)
SELECT m, COUNT(*) failed_first, SUM(CASE WHEN retries>0 THEN 1 ELSE 0 END) got_retry,
       ROUND(100.0*SUM(CASE WHEN retries>0 THEN 1 ELSE 0 END)/COUNT(*),0) pct_retried,
       ROUND(100.0*SUM(CASE WHEN recovered>0 THEN 1 ELSE 0 END)/COUNT(*),0) pct_recovered
FROM x GROUP BY 1 ORDER BY 1;

-- name: dq08_seat_provisioned_vs_billed
-- H8: seats_provisioned > seats_billed on a paid account = seats in use that nobody is paying for.
WITH last AS (SELECT account_id, MAX(month_start) mx FROM seat_usage_monthly WHERE seats_billed>0 GROUP BY 1),
 g AS (SELECT u.account_id, u.plan, u.seats_billed, u.seats_provisioned, u.seats_sso_provisioned, u.seats_provisioned-u.seats_billed gap
       FROM seat_usage_monthly u JOIN last l ON l.account_id=u.account_id AND l.mx=u.month_start WHERE u.seats_billed>0)
SELECT plan, COUNT(*) paid_accounts, SUM(CASE WHEN gap>0 THEN 1 ELSE 0 END) accounts_with_gap, SUM(CASE WHEN gap>0 THEN gap ELSE 0 END) unbilled_seats,
       SUM(CASE WHEN gap>0 AND seats_sso_provisioned>0 THEN 1 ELSE 0 END) gap_accounts_with_sso
FROM g GROUP BY 1;

-- name: dq09_channel_label_cleanup
-- H9: how many raw labels, and what share are non-canonical? Canonical = the 9 snake_case names used by marketing.
SELECT COUNT(DISTINCT signup_source) distinct_labels,
       SUM(CASE WHEN signup_source IN ('organic_search','direct','referral','paid_search','paid_social','review_site','affiliate','content_email','partner') THEN 0 ELSE 1 END) noncanonical_accounts,
       ROUND(100.0*SUM(CASE WHEN signup_source IN ('organic_search','direct','referral','paid_search','paid_social','review_site','affiliate','content_email','partner') THEN 0 ELSE 1 END)/COUNT(*),1) pct_noncanonical
FROM accounts;

-- name: dq10_invoice_payment_consistency
-- Does the money trail agree? paid invoices with no successful payment; successful payments on unpaid invoices; amount mismatches.
SELECT 'paid invoice, no succeeded payment' issue, COUNT(*) n FROM invoices i WHERE status='paid' AND NOT EXISTS (SELECT 1 FROM payments p WHERE p.invoice_id=i.invoice_id AND p.status='succeeded') UNION ALL
SELECT 'succeeded payment on non-paid invoice', COUNT(*) FROM payments p JOIN invoices i USING (invoice_id) WHERE p.status='succeeded' AND i.status<>'paid' UNION ALL
SELECT 'succeeded amount <> invoice total', COUNT(*) FROM payments p JOIN invoices i USING (invoice_id) WHERE p.status='succeeded' AND ABS(p.amount-i.total_amount)>0.01 UNION ALL
SELECT 'payments dated after 2025-12-31', COUNT(*) FROM payments WHERE attempted_at > '2025-12-31 23:59:59' UNION ALL
SELECT 'uncollectible invoices', COUNT(*) FROM invoices WHERE status='uncollectible' UNION ALL
SELECT 'void invoices', COUNT(*) FROM invoices WHERE status='void';

-- name: dq11_subscription_vs_plan_history
-- Does the current subscription MRR agree with the last plan_change? (state vs history reconciliation)
WITH lastc AS (SELECT subscription_id, mrr_after_usd, ROW_NUMBER() OVER (PARTITION BY subscription_id ORDER BY changed_at DESC, plan_change_id DESC) rn FROM plan_changes)
SELECT s.status, COUNT(*) subs, SUM(CASE WHEN ABS(s.mrr_usd - l.mrr_after_usd) > 0.01 THEN 1 ELSE 0 END) mismatched
FROM subscriptions s JOIN lastc l ON l.subscription_id=s.subscription_id AND l.rn=1 GROUP BY 1;
