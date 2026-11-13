# Data

Nine synthetic tables from the Flowdesk data world (fixed seed; no real people or third-party data, so no licence restrictions):
accounts, subscriptions, plan_changes, invoices, payments, refunds, coupons, coupon_redemptions, seat_usage_monthly. Column meanings: `docs/data_dictionary.md`.

- `*.csv` full tables (~23 MB total), read by `sql/00_setup.sql` / `run_sql.py`.
- `sample/` first 1,000 rows of each, for a quick look.
- Regenerate with the Flowdesk generator (`python run_all.py`, writes `data/csv/*.csv`). Byte-identical output needs this one-line fix in `world_a.py`: `rd += [(c_.percent_off or 0) / 100, c_.amount_off_usd or 0., end]` must treat NaN as 0, i.e. `rd += [(0. if pd.isna(c_.percent_off) else c_.percent_off) / 100, 0. if pd.isna(c_.amount_off_usd) else c_.amount_off_usd, end]`. Without it ~11% of invoices get a 100% discount and zero-amount payments.
