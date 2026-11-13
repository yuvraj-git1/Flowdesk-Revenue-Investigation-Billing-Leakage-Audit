# Data quality issue log

| ID | Issue | Evidence (query names in sql/02, 04, 05) | Affected rows | Dollar impact | Proven vs suggests |
|---|---|---|---|---|---|
| DQ-01 | Dunning retries missing Feb-Jun 2025 | dq07_dunning_by_month; rc02b | 313 | $488,344 ARR expected-recoverable ($767,606 ARR at risk) | PROVEN (0% retried vs ~100% in other months) |
| DQ-02 | Unbilled SSO seats (provisioned > billed) | dq08; rc04; rc04b | 57 | $187,891 ARR run-rate; $215,923 cash to date | PROVEN (all 57 have SSO; avg gap 12.8 seats) |
| DQ-03 | Coupon stacking (2+ non-stackable coupons per subscription) | dq06; dq06b; rc03; rc03b; lk02 | 137 | $75,686 excess discount to date; peak $90K annualised (Jan-25); $9.7K ARR still running | PROVEN (all start Sep-24..Jan-25; discount depth 38-51% vs 10% single) |
| DQ-04 | Invoices billed at half contracted price (Mar 3-9 2025) | dq05b; dq05c; lk03 | 25 | $7,372 one-time; $0 ARR (one bad invoice per account) | PROVEN (1 week window, Business plan only) |
| DQ-05 | Duplicate refunds (same payment refunded twice, 1 min apart) | dq04; dq04b | 5 | $801 one-time | PROVEN |
| DQ-06 | Duplicate accounts (same owner re-signs up within 30d) | dq01; dq01b; dq01b2 | 796 | $0 revenue; signups overstated ~2.0% (strong) to ~2.7% (incl. 297 webmail suggestive) | PROVEN for domain matches; SUGGESTIVE for webmail name matches |
| DQ-07 | FX: 1,761 non-USD invoices with no fx/total_usd; ~3% total_usd left in local currency | dq02; rc08 | 1,761 | Summing total_usd misstates billings: 2024 +1,175,204, 2025 +890,116 (INR unconverted inflates, missing fx deflates). Cash unaffected. | PROVEN |
| DQ-08 | EUR/INR invoice issued_at is local time (payments precede invoices 100% of the time) | dq03; tb03 | 9,894 | Only 9 invoices land in the wrong month | PROVEN, immaterial |
| DQ-09 | USD invoices carry fx_rate 0.97-1.03 (should be 1.0) | dq02b | 18,214 | Net +$45 on 17.8K invoices | SUGGESTS system artifact; immaterial net |
| DQ-10 | 46 distinct channel labels, 14.9% non-canonical | dq09; m02 | 5,957 | Splits channel reporting; fixed by mapping rule (0 unmapped) | PROVEN |
| DQ-11 | 40 internal test accounts (flowdesk.com) | dq01c | 40 | $0 | NOISE: exclude from growth metrics |
| DQ-12 | 8 retry payments dated after 2025-12-31 | dq10 | 8 | $0 | NOISE: dunning still running at cutoff |
| DQ-13 | No reactivation events exist (reactivation MRR = 0) | m03 | 0 | Cannot measure win-back baseline | SUGGESTS churn is permanent or reactivation is not tracked |
| DQ-14 | 121 void invoices, 695 uncollectible (matches 688 payment_failure cancels) | dq10 | 121 | Void is 0.4% of invoices | NOISE / consistent |
