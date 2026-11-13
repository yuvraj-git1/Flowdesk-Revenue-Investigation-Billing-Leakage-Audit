# Flowdesk Revenue Investigation & Billing Leakage Audit

## Findings (read this first)
Leadership believes Flowdesk's 2025 MRR stall is "all churn". **It is mostly churn, but not only churn.**
ARR ended 2025 at **$5.91M (+13% YoY vs +151% in 2024)**; net new MRR fell 78% ($261K -> $58K), a **$2.44M ARR shortfall**.

| Driver | Share of shortfall | Proven? |
|---|---|---|
| Voluntary churn (rate doubled + bigger base) | ~44% | Rate shift proven; cause unknown |
| Involuntary churn: **dunning outage Feb-Jun 2025** (313 accounts never retried) | ~21% (**$488K ARR**) | Proven |
| Involuntary churn: bigger base / other | ~2% | Proven |
| New business: 90-day conversion fell 11.3% -> 7.4% in every channel | ~27% | Proven; cause unknown |
| Expansion | ~6% | Proven |

**Other leaks:** unbilled SSO seats (57 accounts, **$188K ARR**, $216K cash), coupon stacking (137 subs, $76K excess discount, $10K still running), half-price invoices (25, $7K one-off), duplicate refunds (5, $801), duplicate accounts (~2-2.7%, $0 revenue), FX reporting error (raw `total_usd` overstates 2024/2025 billings by $1.2M/$0.9M).
**Recoverable ARR: $346K base (range $196K-$491K), ~6% of ARR.** Ranges depend on stated win-back/true-up assumptions.
One-page summary: [`docs/cfo_memo.md`](docs/cfo_memo.md).

## Folder structure
```
sql/            00_setup (DuckDB views) | 01_profiling | 02_data_quality_audit | 03_mrr_waterfall_and_metrics
                04_root_cause | 05_leakage_quantification | 06_tableau_exports   (commented DuckDB SQL)
data/           the 9 source CSVs (synthetic, Flowdesk Project 0; see data/README.md)   data/sample/  first 1,000 rows of each
outputs/        every query result as CSV      tableau/   extracts for the dashboard
charts/         4 PNGs (matplotlib/seaborn)    docs/      profiling summary, issue log, root cause, Tableau spec, CFO memo, scorecard, handoff
run_sql.py      DuckDB runner (writes outputs/)   build_docs.py   charts + issue log from outputs/
```

## How to run
```
git clone <repo-url> flowdesk-p1 && cd flowdesk-p1
python -m venv .venv && source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python run_sql.py sql/01_profiling.sql sql/02_data_quality_audit.sql sql/03_mrr_waterfall_and_metrics.sql \
                  sql/04_root_cause.sql sql/05_leakage_quantification.sql sql/06_tableau_exports.sql    # ~20 s, rewrites outputs/
python build_docs.py                                      # optional: rebuilds charts/ and docs/issue_log.*
```
Works from any directory (paths resolve relative to the scripts). Run all six SQL files in ONE `run_sql.py` call and in order: stages 03-06 create helper tables that later stages reuse.
Plain DuckDB CLI alternative (from the repo root): `duckdb` then `.read sql/00_setup.sql`, `.read sql/01_profiling.sql` ... `.read sql/06_tableau_exports.sql`.
Use your own copy of the data: `FD_DATA=/path/to/csvs python run_sql.py ...` (needs the 9 CSVs named as in `data/`).

**Verification:** run end to end on Python 3.13 / DuckDB 2.0 / pandas 3.0 with no errors. Headline outputs (MRR waterfall, NRR/GRR, leakage register, FX correction, dunning) match the committed `outputs/` exactly. A few day-difference columns can shift slightly (<=1 day, conversion <=0.05 pp) because the committed outputs were first produced through a DuckDB-to-SQLite translation; row order of some un-sorted group-bys also differs. Docs quote the committed outputs.

## Method
MRR is rebuilt per account per month-end from `plan_changes` (list price x seats, before discounts); billed MRR from invoices (converted at a monthly reference FX because `total_usd` is unreliable) is used to reconcile. Waterfall check = 0 in all 36 months, and Dec-2025 MRR x 12 ties to `subscriptions` ($5,908,118).
Findings come from the queries; each issue in [`docs/issue_log.md`](docs/issue_log.md) lists its evidence query, rows and dollars, and whether it is proven or only suggested. [`docs/08_scorecard.md`](docs/08_scorecard.md) grades the findings against the generator's planted-problem list (spoilers if you want to reuse the dataset blind).
