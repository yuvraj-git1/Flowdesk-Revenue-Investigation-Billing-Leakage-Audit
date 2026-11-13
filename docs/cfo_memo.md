**MEMO: Flowdesk revenue stall: it is not only churn**
**To:** CFO  **From:** Data Analytics  **Re:** Q4 revenue investigation  **Data:** Jan 2023 - Dec 2025

**Bottom line.** ARR ended 2025 at **$5.91M, up 13%** after +151% in 2024. Net new MRR fell 78% ($261K -> $58K), a **$2.44M ARR shortfall** against 2024's pace. Churn explains about two-thirds of it, so the leadership view is partly right. But **one fixable billing failure explains ~21%**, and **27% is a conversion problem, not churn**.

**What drove the shortfall**
- **Voluntary churn rate rose ~2x** (monthly plans 1.65% -> 3.26% a month; annual 0.57% -> 1.58%): ~33% of the shortfall, plus ~22% from a larger base churning at the old rate.
- **Dunning outage, Feb-Jun 2025:** failed card payments stopped being retried for 313 accounts, so they cancelled. Normally ~64% of failures recover. Cost: **$488K ARR** (two methods agree: $488K and $504K): ~21% of the shortfall.
- **Conversion fell** from 11.3% to 7.4% of signups paying within 90 days, in every channel, while signups grew 14%: ~27% of the shortfall.

**Other leaks (proven in billing data)**
| Leak | Scale | ARR today | One-time cash |
|---|---|---|---|
| Unbilled SSO seats (57 Business accounts, 734 seats) | provisioned > billed | $188K | $216K |
| Coupon stacking (137 subscriptions, Sep-24 to Jan-25) | excess discount | $10K still running | $76K |
| Half-price invoices (25, Mar 3-9) and duplicate refunds (5) | one-offs | $0 | $8K |

**Recoverable ARR: $346K base (range $196K - $491K), about 6% of ARR.** The range comes from win-back and true-up success assumptions (stated in the appendix), since there is no reactivation history to calibrate against.

**Reporting warning.** Summing `total_usd` overstates billings by $1.2M (2024) and $0.9M (2025): INR invoices were never converted and some FX rates are missing. Cash is unaffected; use the corrected series.

**Decisions requested**
1. Confirm dunning retries are running and alert if retry rate drops; launch win-back for the 313 accounts.
2. True-up billing on the 57 SSO accounts; alert whenever provisioned > billed.
3. Enforce the non-stackable coupon rule at checkout.
4. Replace raw `total_usd` with the corrected USD series in finance reporting.
5. Open a product/pricing investigation into the doubled voluntary churn and the conversion drop. **Billing data cannot explain why**; this is the largest remaining gap.

*What is proven vs suggested: all billing leaks and both rate shifts are proven in the data. Causes of the churn and conversion shifts are not. Win-back and true-up rates are assumptions.*
