import argparse
import sys

import pandas as pd
from rich.console import Console
from rich.table import Table

from acme_core import slugify


def main(argv=None):
    p = argparse.ArgumentParser(prog="acme-report", description="Summarise a CSV file.")
    p.add_argument("csv", nargs="?", help="CSV file (default: built-in sample)")
    args = p.parse_args(argv)
    if args.csv:
        df = pd.read_csv(args.csv)
    else:
        df = pd.DataFrame({"Region": ["North", "South", "East"], "Sales": [120, 95, 143]})
    t = Table(title="acme-report")
    t.add_column("column")
    t.add_column("mean", justify="right")
    for col in df.select_dtypes("number").columns:
        t.add_row(slugify(col), f"{df[col].mean():.2f}")
    Console().print(t)
    return 0


if __name__ == "__main__":
    sys.exit(main())
