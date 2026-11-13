-- DuckDB setup: expose the 9 CSVs as views, then run the stage files in order in ONE session:
--   duckdb < sql/00_setup.sql   (or in the DuckDB CLI:  .read sql/00_setup.sql  then .read sql/01_profiling.sql ... 06)
-- Stage files 03-06 create helper tables (months, acct_month_mrr, acct_dim, acct_move, billed_mrr, lk_*) that later files reuse.
CREATE OR REPLACE VIEW accounts AS SELECT * FROM read_csv_auto('data/accounts.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW subscriptions AS SELECT * FROM read_csv_auto('data/subscriptions.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW plan_changes AS SELECT * FROM read_csv_auto('data/plan_changes.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW invoices AS SELECT * FROM read_csv_auto('data/invoices.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW payments AS SELECT * FROM read_csv_auto('data/payments.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW refunds AS SELECT * FROM read_csv_auto('data/refunds.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW coupons AS SELECT * FROM read_csv_auto('data/coupons.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW coupon_redemptions AS SELECT * FROM read_csv_auto('data/coupon_redemptions.csv', header=true, sample_size=-1);
CREATE OR REPLACE VIEW seat_usage_monthly AS SELECT * FROM read_csv_auto('data/seat_usage_monthly.csv', header=true, sample_size=-1);
