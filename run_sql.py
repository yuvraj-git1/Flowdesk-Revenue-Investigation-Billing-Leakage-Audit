"""Run SQL files made of `-- name: x` blocks on DuckDB; save each block's final SELECT to outputs/x.csv.

Usage (from anywhere):  python run_sql.py sql/01_profiling.sql sql/02_data_quality_audit.sql ...
Files must be run in ONE call, in order: stages 03-06 build helper tables that later stages reuse.
Env: FD_DATA = folder with the 9 CSVs (default: data/), SHOW = rows to print per block (default 6).
"""
import os, re, sys, time
from pathlib import Path
import duckdb, pandas as pd

ROOT = Path(__file__).resolve().parent
DATA = Path(os.environ.get("FD_DATA", ROOT / "data"))
OUT = ROOT / "outputs"; OUT.mkdir(exist_ok=True)
TABLES = ["accounts", "subscriptions", "plan_changes", "invoices", "payments", "refunds", "coupons", "coupon_redemptions", "seat_usage_monthly"]

con = duckdb.connect()
for t in TABLES:
    con.execute(f"CREATE VIEW {t} AS SELECT * FROM read_csv_auto('{(DATA / (t + '.csv')).as_posix()}', header=true, sample_size=-1)")


def run_file(path, show):
    blocks = re.split(r"^-- name:\s*(\w+)\s*$", Path(path).read_text(), flags=re.M)
    for name, sql in zip(blocks[1::2], blocks[2::2]):
        stmts = [s.strip() for s in re.split(r";\s*\n", sql.strip().rstrip(";") + "\n")]
        stmts = [s for s in stmts if re.search(r"(?i)\b(select|create|drop)\b", s)]
        for st in stmts[:-1]:
            con.execute(st)
        last = stmts[-1]
        if re.match(r"(?i)\s*(create|drop)", last):
            con.execute(last); print(f"\n== {name}: ok"); continue
        t0 = time.time(); df = con.execute(last).df(); df.to_csv(OUT / f"{name}.csv", index=False)
        print(f"\n== {name} ({len(df)} rows, {time.time() - t0:.1f}s)"); print(df.head(show).to_string(index=False))


if __name__ == "__main__":
    pd.set_option("display.width", 220, "display.max_columns", 30)
    for p in sys.argv[1:]:
        run_file(p, int(os.environ.get("SHOW", 6)))
