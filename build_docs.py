"""Support script: charts (matplotlib/seaborn) + issue log, all read from outputs/*.csv (the SQL results)."""
import os, pandas as pd, numpy as np, matplotlib; matplotlib.use("Agg")
os.chdir(os.path.dirname(os.path.abspath(__file__)))  # paths below are relative to the repo root
import matplotlib.pyplot as plt, seaborn as sns
sns.set_theme(style="whitegrid"); R = lambda n: pd.read_csv(f"outputs/{n}.csv")
w = R("m10_mrr_waterfall_monthly"); w["m"] = pd.to_datetime(w.m)
# 1 waterfall components + MRR line
fig, ax = plt.subplots(figsize=(11, 5)); pos = w[["new_mrr", "expansion_mrr"]]; neg = w[["contraction_mrr", "churn_voluntary_mrr", "churn_involuntary_mrr"]]
cols = {"new_mrr": "#2a9d8f", "expansion_mrr": "#8ab17d", "contraction_mrr": "#e9c46a", "churn_voluntary_mrr": "#e76f51", "churn_involuntary_mrr": "#9d0208"}
b = np.zeros(len(w)); n = np.zeros(len(w))
for c in pos: ax.bar(w.m, w[c], bottom=b, width=25, color=cols[c], label=c.replace("_mrr", "")); b += w[c].values
for c in neg: ax.bar(w.m, w[c], bottom=n, width=25, color=cols[c], label=c.replace("_mrr", "")); n += w[c].values
ax.axvspan(pd.Timestamp("2025-02-01"), pd.Timestamp("2025-06-30"), color="grey", alpha=.15); ax.text(pd.Timestamp("2025-02-10"), 36000, "dunning outage", fontsize=9)
ax.set_ylabel("MRR movement ($)"); ax2 = ax.twinx(); ax2.plot(w.m, w.closing, color="black", lw=2, label="closing MRR"); ax2.set_ylabel("closing MRR ($)"); ax2.grid(False)
ax.legend(loc="upper left", fontsize=8, ncol=2); ax.set_title("Flowdesk MRR waterfall: growth, then churn eats net new"); fig.tight_layout(); fig.savefig("charts/01_mrr_waterfall.png", dpi=140)
# 2 churn rates
r = R("rc02_involuntary_churn_rate_by_month"); r["m"] = pd.to_datetime(r.m); fig, ax = plt.subplots(figsize=(10, 4))
ax.plot(r.m, r.invol_rate_pct, color="#9d0208", marker="o", label="involuntary (payment failure)"); ax.plot(r.m, r.vol_rate_pct, color="#e76f51", marker="o", label="voluntary")
ax.axvspan(pd.Timestamp("2025-02-01"), pd.Timestamp("2025-06-30"), color="grey", alpha=.15); ax.set_ylabel("% of opening MRR"); ax.legend(); ax.set_title("Monthly churn rate by type: involuntary spikes Feb-Jun 2025")
fig.tight_layout(); fig.savefig("charts/02_churn_by_type.png", dpi=140)
# 3 recoverable ARR range
k = R("lk04_leakage_register"); k = k[k.recoverable_high > 0].copy(); k["c"] = k.cause.str.split("(").str[0].str.strip(); fig, ax = plt.subplots(figsize=(9, 3.6))
ax.barh(k.c, k.recoverable_high, color="#cfe3df", label="high"); ax.barh(k.c, k.recoverable_base, color="#2a9d8f", label="base"); ax.barh(k.c, k.recoverable_low, color="#1b5e55", label="low")
ax.set_xlabel("recoverable ARR ($)"); ax.legend(); ax.set_title(f"Recoverable ARR: ${k.recoverable_low.sum()/1e3:,.0f}K low / ${k.recoverable_base.sum()/1e3:,.0f}K base / ${k.recoverable_high.sum()/1e3:,.0f}K high"); fig.tight_layout(); fig.savefig("charts/03_recoverable_arr.png", dpi=140)
# 4 conversion by signup cohort (flag censored)
c = R("rc06_funnel_conversion_by_signup_quarter"); fig, ax = plt.subplots(figsize=(9, 4)); ax.bar(c.cohort, c.conv_90d_pct, color=["#2a9d8f"] * 4 + ["#e76f51"] * 2 + ["#f4a261"] * 2 + ["#2a9d8f"] * 0)[:0] if False else None
col = ["#264653"] * 8 + ["#e76f51"] * 2 + ["#bbbbbb"] * 2; ax.bar(c.cohort, c.conv_90d_pct, color=col); ax.set_ylabel("% paid within 90d"); plt.xticks(rotation=45)
ax.set_title("Signup->paid conversion: 2025 drops (grey = last two cohorts, window not fully matured)"); fig.tight_layout(); fig.savefig("charts/04_conversion_cohorts.png", dpi=140)
# issue log
a = R("dq04b_refund_overage_usd").iloc[0]; fx = R("rc08_reported_vs_corrected_revenue_by_year"); lk = R("lk04_leakage_register").set_index(R("lk04_leakage_register").cause.str[:7])
L = [("DQ-01", "Dunning retries missing Feb-Jun 2025", "billing process", "dq07_dunning_by_month; rc02b", 313, f"${lk.iloc[0].arr_lost_to_cause:,.0f} ARR expected-recoverable (${767606:,.0f} ARR at risk)", "PROVEN (0% retried vs ~100% in other months)", "Restore retry job; win back affected accounts"),
     ("DQ-02", "Unbilled SSO seats (provisioned > billed)", "billing / entitlement", "dq08; rc04; rc04b", 57, "$187,891 ARR run-rate; $215,923 cash to date", "PROVEN (all 57 have SSO; avg gap 12.8 seats)", "True-up billing; alert on provisioned>billed"),
     ("DQ-03", "Coupon stacking (2+ non-stackable coupons per subscription)", "discount control", "dq06; dq06b; rc03; rc03b; lk02", 137, "$75,686 excess discount to date; peak $90K annualised (Jan-25); $9.7K ARR still running", "PROVEN (all start Sep-24..Jan-25; discount depth 38-51% vs 10% single)", "Enforce stackable flag at checkout"),
     ("DQ-04", "Invoices billed at half contracted price (Mar 3-9 2025)", "pricing bug", "dq05b; dq05c; lk03", 25, "$7,372 one-time; $0 ARR (one bad invoice per account)", "PROVEN (1 week window, Business plan only)", "Back-bill; add price-vs-contract check"),
     ("DQ-05", "Duplicate refunds (same payment refunded twice, 1 min apart)", "payments", "dq04; dq04b", int(a.extra_refund_rows), f"${a.extra_refund_usd:,.0f} one-time", "PROVEN", "Idempotency key on refunds"),
     ("DQ-06", "Duplicate accounts (same owner re-signs up within 30d)", "data / funnel", "dq01; dq01b; dq01b2", 796, "$0 revenue; signups overstated ~2.0% (strong) to ~2.7% (incl. 297 webmail suggestive)", "PROVEN for domain matches; SUGGESTIVE for webmail name matches", "Dedupe on domain+name before funnel metrics"),
     ("DQ-07", "FX: 1,761 non-USD invoices with no fx/total_usd; ~3% total_usd left in local currency", "reporting", "dq02; rc08", 1761, f"Summing total_usd misstates billings: 2024 {fx.reporting_error_usd[1]:+,.0f}, 2025 {fx.reporting_error_usd[2]:+,.0f} (INR unconverted inflates, missing fx deflates). Cash unaffected.", "PROVEN", "Recompute USD from fx table; never sum total_usd raw"),
     ("DQ-08", "EUR/INR invoice issued_at is local time (payments precede invoices 100% of the time)", "timestamp", "dq03; tb03", 9894, "Only 9 invoices land in the wrong month", "PROVEN, immaterial", "Store UTC"),
     ("DQ-09", "USD invoices carry fx_rate 0.97-1.03 (should be 1.0)", "anomaly", "dq02b", 18214, "Net +$45 on 17.8K invoices", "SUGGESTS system artifact; immaterial net", "Force fx=1 for USD"),
     ("DQ-10", "46 distinct channel labels, 14.9% non-canonical", "dimension hygiene", "dq09; m02", 5957, "Splits channel reporting; fixed by mapping rule (0 unmapped)", "PROVEN", "Controlled vocabulary at capture"),
     ("DQ-11", "40 internal test accounts (flowdesk.com)", "natural noise", "dq01c", 40, "$0", "NOISE: exclude from growth metrics", "Flag at source"),
     ("DQ-12", "8 retry payments dated after 2025-12-31", "natural noise", "dq10", 8, "$0", "NOISE: dunning still running at cutoff", "None"),
     ("DQ-13", "No reactivation events exist (reactivation MRR = 0)", "suspicious", "m03", 0, "Cannot measure win-back baseline", "SUGGESTS churn is permanent or reactivation is not tracked", "Track reactivations"),
     ("DQ-14", "121 void invoices, 695 uncollectible (matches 688 payment_failure cancels)", "natural noise", "dq10", 121, "Void is 0.4% of invoices", "NOISE / consistent", "None")]
pd.DataFrame(L, columns=["id", "issue", "type", "evidence_queries", "affected_rows", "dollar_impact", "proven_or_suggests", "recommended_fix"]).to_csv("docs/issue_log.csv", index=False)
open("docs/issue_log.md", "w").write("# Data quality issue log\n\n| ID | Issue | Evidence (query names in sql/02, 04, 05) | Affected rows | Dollar impact | Proven vs suggests |\n|---|---|---|---|---|---|\n" + "\n".join(f"| {x[0]} | {x[1]} | {x[3]} | {x[4]:,} | {x[5]} | {x[6]} |" for x in L) + "\n")
print("ok")
