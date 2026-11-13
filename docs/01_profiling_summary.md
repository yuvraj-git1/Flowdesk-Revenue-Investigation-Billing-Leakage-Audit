# Stage 1: Profiling summary (queries: sql/01_profiling.sql)

| Table | Rows | Grain (verified) | Key (verified unique) | Notes |
|---|---|---|---|---|
| accounts | 39,974 | 1 workspace | account_id | 35,789 free / 2,506 paid / 1,679 churned; 14,272 null industry, 7,257 null email_domain, 796 null country |
| subscriptions | 4,185 | 1 paid lifecycle, **1 per paid account** | subscription_id (= account_id unique) | current-state snapshot only; 2,499 active, 7 past_due, 1,679 canceled |
| plan_changes | 7,813 | 1 contract change | plan_change_id | history: start_paid 4,185, seat_change 1,666, cancel 1,679, upgrade 145, interval_switch 114, downgrade 24. **No reactivation events** |
| invoices | 33,039 | 1 invoice per subscription billing period | invoice_id; (subscription, period_start) | 32,223 paid, 695 uncollectible, 121 void; 5 currencies; fx/total_usd NULL on 1,761 rows |
| payments | 35,149 | 1 payment attempt | payment_id; (invoice, attempt_number) | attempts 1-4; 8 dated after the data cutoff (retries) |
| refunds | 714 | 1 refund | refund_id | **709 distinct payments -> 5 payments refunded twice** |
| coupons | 25 | 1 code | coupon_id | stackable flag present |
| coupon_redemptions | 1,172 | 1 use of a coupon on a subscription | redemption_id | |
| seat_usage_monthly | 252,168 | account x month | (account_id, month_start) | free + paid accounts |

**Referential integrity:** all 7 FK checks return 0 orphans. **Money:** invoices are in local currency (USD/EUR/GBP/CAD/INR); `total_usd` cannot be trusted raw (see issue log). **Time:** timestamps assumed UTC; tested in DQ-08.
**Hypotheses raised by profiling (tested in Stage 2/4):** refunds repeat per payment; fx nulls; fewer retries than failures; lumpy billed USD by month; 46 channel labels; no reactivation.
