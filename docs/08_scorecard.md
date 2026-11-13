# Stage 8: Scorecard (Project 1 findings vs the answer key)

Scope: Project 1 only had 9 billing/finance tables plus channel labels, so **B1-B7, G4 (and partly G3/G2) were detectable**. P1-P5, G1 need events, experiments and marketing tables (Projects 2-3). B5's iOS timestamp part is also out of scope.

| ID | Planted | What I found | Verdict |
|---|---|---|---|
| B1 Dunning outage | 313 accounts; $447K ARR recoverable | 313 accounts (exact); $488K expected-recoverable (+9%), $504K by a second method (+13%) | **Detected, count exact, $ within 9-13%** |
| B2 Coupon stacking | 140 subs; $188K ARR; list $319K vs true $132K | 140 subs (exact, dq06). But I measured *excess over one allowed coupon*: $75.7K cash, $90K peak annualised, $9.7K still running | **Detected, count exact; $ not comparable** (different definition, see below) |
| B3 Unbilled SSO seats | 60 accounts; $219K ARR | 57 accounts (95%); $188K ARR (86%) | **Detected, 3 accounts missed** |
| B4 Duplicate accounts | 974 | 796 strong (domain) + 297 suggestive (webmail name) = 1,093 | **Detected**; strong tier ~99.6% of the 799 domain-bearing dups; suggestive tier had ~120 false positives, labelled as weak evidence |
| B5 Currency/timezone | 2,220 rows; reported $6.97M vs true $5.36M | 1,715 missing-fx + 448 unconverted = 2,163 paid rows (97% of 2,220, which includes unpaid); EUR/INR local-time stamps found; reporting error +$2.1M | **Detected; row count 97%, $ gap differs** (see below) |
| B6 Pricing bug | 25 accounts; $6.1K | 25 invoices, 25 accounts, Mar 3-9 (exact); $7.4K (+20%) | **Detected, exact window and count** |
| B7 Duplicate refunds | 5; $797 | 5 payments, $801 (+0.5%) | **Detected, exact** |
| G4 Messy labels | 5,957 (14.9%) | 14.9% non-canonical, 46 labels, mapping rule with 0 unmapped | **Detected, exact** |
| G3 Sales LTV ~3x | 2.71x | Built NRR by motion (66.6% vs 60.2%) but never computed an LTV ratio | **Missed (partial signal only)** |
| G2 Bad review channel | cost/paid 1,130 vs 19/signup | Segment table showed review_site NRR 31.6% (next lowest 51.9%) and conv 1.4%, but I never reported it | **Surfaced in data, not reported** |
| P1-P5, G1 | | Not testable with Project 1 data | n/a |

**Score: 8/8 in-scope billing problems detected; 5 with exact counts (B1, B2, B6, B7, G4); 2 within 5% (B3 95%, B5 97%); B4 right on strong evidence.** Two partial/missed (G3, G2).

## Where I was off, and why
1. **B2 dollars.** The key's $188K is the total discount ARR carried by stacked coupons. I deliberately measured only the *excess beyond one legitimate coupon* ($76K cash, $10K still running), which is the better "leakage" definition, but I should have also reported the gross figure. Lesson: show both the gross and the net-of-policy number.
2. **B3.** 3 accounts missed, probably because I measured only each account's *latest billed month* and priced seats at the contract rate (annual accounts at $19.20, key uses $24). The $ gap is mostly that pricing choice. Lesson: also scan any month, not just the latest.
3. **B1 dollars.** The key's $447K is the ARR of those accounts actually recoverable; mine multiplied all 313 accounts' $768K by an average recovery rate. +9% error from using an average instead of account-level probabilities. The two-method agreement ($488K vs $504K) hid a shared bias.
4. **B5 dollars.** My $2.1M overstatement vs the key's $1.6M: different scope (I used paid invoices only and a recomputed monthly FX; the key sums all non-USD rows). Direction and cause correct; I cannot reconcile exactly without row-level flags.
5. **B6 dollars.** +20%: I priced underbilling at the monthly reference FX rate; the key uses invoice-level rates.
6. **G2/G3.** I had the evidence in a segment table and did not escalate it. Lesson: scan every segment table for outliers before writing the memo.

## Things I flagged that are NOT planted problems (good calibration)
Test accounts (flowdesk.com), 8 post-cutoff retries, void invoices, no reactivation events, USD fx rates 0.97-1.03 (a generator quirk, not in the key). I labelled these noise/suggestive, not proven problems.

## Bigger story, not in the key
The 2025 stall also came from doubled voluntary churn and a conversion drop (11.3% -> 7.4%). These are designed behaviour, not planted problems, and the key has no row for them. I reported them as proven-but-unexplained.
