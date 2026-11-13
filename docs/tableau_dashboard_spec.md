# Tableau dashboard spec: "Where did the MRR go?" (Stage 6)

**Data (tableau/*.csv, one connection each, no joins needed):** `m10_mrr_waterfall_monthly`, `tb02_leakage_monthly_long`, `lk04_leakage_register`, `m13_nrr_grr_ttm`, `m15_waterfall_by_segment_long`, `dq07_dunning_by_month`, `lk01_shortfall_attribution`, `rc06_funnel_conversion_by_signup_quarter`.

## Dashboard 1: MRR waterfall with leakage drill-down (1400x900)
1. **KPI strip (top):** Ending ARR (`[arr]` at latest month), YoY ARR %, TTM NRR, TTM GRR (m13). Month-range parameter `p_start`, `p_end`.
2. **Waterfall (left, main):** one bar per component for the selected period. Build from m10 pivoted to long: `Component` (New, Reactivation, Expansion, Contraction, Voluntary churn, Involuntary churn). Use a Gantt-bar waterfall: `Running = RUNNING_SUM(SUM([Delta]))`, bar size = `SUM([Delta])`, start = `[Running]-SUM([Delta])`. Colours: greens up, orange voluntary, dark red involuntary.
3. **Leakage drill (right):** stacked bars by month from `tb02_leakage_monthly_long` (Category colour). **Dashboard action:** click a Category -> filters sheet 4 and highlights the matching months on the waterfall (Use as Filter).
4. **Leakage register (bottom):** `lk04` table with `Low / Base / High` recoverable ARR columns and `Evidence strength`. Total row via `TOTAL(SUM())`.
5. **Segment drill (tab 2):** `m15` with a dimension parameter (plan, interval, motion, channel) driving the segment field: `CASE [p_dim] WHEN 'plan' THEN ...` is unnecessary because m15 is already long: just filter `dimension = [p_dim]`.

## Calculated fields
- `Net New MRR = SUM(IF [move]<>'flat' THEN [mrr_delta] END)`
- `Churn share involuntary = SUM(involuntary)/SUM(total churn)`
- `Outage flag = [m]>=#2025-02-01# AND [m]<=#2025-06-01#` (reference band on every time chart)
- `Recoverable range = [recoverable_low] & " - " & [recoverable_high]`

## Design notes
- Tooltips: show component, $ and share of net new. Reference line at 0 on waterfall. Shade the outage window.
- Keep dunning chart (`dq07`: % retried by month) as the "proof" sheet: a single bar chart dropping to 0% in Feb-Jun.
- Colour-blind safe palette (teal/orange/dark red). Fixed axis units in $K.
- Refresh: extracts are static CSVs; re-run `sql/06_tableau_exports.sql` after any data change.
- Interview line: "I built one monthly leakage table in long format so a single click drills from the waterfall to a leakage category with no joins in Tableau."
