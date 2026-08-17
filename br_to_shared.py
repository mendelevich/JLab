"""
br_to_shared.py — Convert BlackRock trial CSVs to the shared CT/BR schema.

Reads the `Blackrock_<date>_trials_matlab.csv` produced by BlackrockLoader (one row
per trial) and emits a CSV whose columns are the shared variable names.

Uses the SAME map as the cage converter (`schema_map.yaml`), but applies the `br:`
side of each entry. Most BR specs are `direct:` because BlackrockLoader already exports
these exact column names, so this REGISTRY is nearly empty — add a function here only
if a shared variable needs a real transform on the BlackRock side.

Note on task filtering: this converter passes task=None, so `applies_to` is NOT used to
gate columns — BR columns that don't exist for a given session simply come through as
NaN (via column-presence). That keeps single- vs multi-target sessions robust without
having to translate BlackRock's task names into the cage task vocabulary.

Not yet validated against a real BlackRock trials CSV.

Usage:
    python br_to_shared.py --csv Blackrock_2026-07-24_trials_matlab.csv \
                           --monkey Athos --out shared_br_2026-07-24.csv
"""

from __future__ import annotations

import argparse

import pandas as pd

from schema_convert import apply_side, load_map


# BlackRock-side compute transforms. Empty for now — BlackrockLoader's CSV already
# carries the columns the map points at, so every br spec is `direct`/`na`. Add
# (name -> function(df, ctx) -> Series) here if a shared variable ever needs a real
# transform on the BR side, then reference it from the map as `br: { compute: NAME }`.
REGISTRY = {}


def convert_blackrock_to_shared(df: pd.DataFrame, monkey: str, map_path=None) -> pd.DataFrame:
    entries = load_map(map_path) if map_path else load_map()
    # task=None -> no applies_to filtering; rely on column presence (see module docstring).
    ctx = {"task": None, "monkey": monkey}
    return apply_side(df, entries, side="br", ctx=ctx, registry=REGISTRY)


def main():
    ap = argparse.ArgumentParser(description="Convert a BlackRock trials CSV to the shared schema.")
    ap.add_argument("--csv", required=True, help="input Blackrock_<date>_trials_matlab.csv")
    ap.add_argument("--monkey", required=True, help="monkey name (from the folder name)")
    ap.add_argument("--out", required=True, help="output CSV path")
    ap.add_argument("--map", default=None, help="path to schema_map.yaml (default: alongside this script)")
    args = ap.parse_args()

    df = pd.read_csv(args.csv)
    shared = convert_blackrock_to_shared(df, monkey=args.monkey, map_path=args.map)
    shared.to_csv(args.out, index=False)
    print(f"Wrote {len(shared)} rows x {shared.shape[1]} cols -> {args.out}")


if __name__ == "__main__":
    main()
