# Stages 4-5: Root cause and leakage (queries: sql/04, sql/05)

**Question:** leadership says "it's just churn". **Test:** decompose the drop in net new MRR (2024 $261K -> 2025 $58K, -$204K MRR = -$2.44M ARR), then test each alternative separately.

| Driver | MRR effect | % of shortfall |
|---|---|---|
| New business (conversion decline) | -$55.7K | 27% |
| Expansion | -$11.4K | 6% |
| Voluntary churn: rate effect (leaving faster) | -$67.7K | 33% |
| Voluntary churn: volume effect (bigger base) | -$23.3K | 11% |
| Involuntary churn: volume effect | -$22.2K | 11% |
| Involuntary churn: dunning outage Feb-Jun 2025 | -$42.0K | 21% |
| Involuntary churn: other rate effect | +$18.2K | -9% |

**Verdict on "it's just churn":** churn is about two-thirds of the shortfall, so leadership is **partly right**; but ~21% of the shortfall is one fixable billing failure, and 27% is a conversion problem that is not churn at all.

| Hypothesis | Test (query) | Verdict |
|---|---|---|
| Billing failures (retries stopped) | dq07, rc02, rc02b | **Proven.** 313 failed first payments Feb-Jun 2025 got 0 retries (100% retried in every other month). Expected recoverable ARR $488K (account method) vs $504K (rate method): two independent methods agree within 3% |
| Coupon stacking | dq06, rc03, rc03b, lk02 | **Proven**, smaller than feared: 137 subs, $75.7K excess discount to date, peak $90K annualised (Jan-25), only $9.7K still running |
| Unbilled usage | dq08, rc04, rc04b | **Proven.** 57 SSO accounts, 734 unbilled seats, $188K ARR, $216K cash to date |
| Pricing errors | dq05b/c, rc05 | **Proven but one-off:** 25 invoices, Mar 3-9 2025, $7.4K, no ARR effect |
| Duplicate accounts | dq01 | Proven but **$0 revenue**; distorts signups (~2-2.7%) and conversion denominators |
| FX/reporting | dq02, rc08 | Proven reporting error (raw total_usd overstates 2024 by $1.2M, 2025 by $0.9M); **no cash effect** |
| Voluntary churn got worse | rc07 | **Proven:** monthly-plan 1.65%->3.26% per month, annual 0.57%->1.58%. **Cause not identifiable** from billing data |
| Conversion got worse | rc06, rc06b | **Proven** (H1 cohorts 11.3%->7.4%, every channel); signups rose ~14%. **Cause unknown**: Q3/Q4-2025 cohorts excluded as right-censored |

## Recoverable ARR (lk04). Assumptions are parameters in the SQL.
| Cause | ARR impact today | Low | Base | High | Assumption |
|---|---|---|---|---|---|
| Dunning outage | $488K | $98K | $195K | $293K | win-back of 20% / 40% / 60% of accounts retries would have saved |
| Unbilled SSO seats | $188K | $94K | $141K | $188K | true-up succeeds 50% / 75% / 100% |
| Coupon stacking | $10K | $5K | $10K | $10K | forward discount removable |
| **Total** | | **$196K** | **$346K** | **$491K** | ~3% / 6% / 8% of ending ARR |

One-time cash (not ARR): seat back-billing up to $216K, stacking $76K, pricing $7K, refunds $0.8K. Realistic collection is partial.
**Limits:** list MRR is contract price before discounts (billed MRR runs 2-6% lower, m20). The dunning win-back rates are assumptions: no reactivation history exists to calibrate them (DQ-13).
