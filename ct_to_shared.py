"""
ct_to_shared.py — Convert Cage-Training trial CSVs to the shared CT/BR schema.

Reads the CSV produced by `CageTrainingDataLoading.m` (`all_trials_<date>.csv`, one
row per trial) and emits a CSV whose columns are the shared variable names.

The MAP now lives in `schema_map.yaml` (the single source of truth). This file only
holds the CT-specific `compute:` transforms (the REGISTRY) and the CLI. The generic
apply logic is in `schema_convert.py`, shared with `br_to_shared.py`.

To change WHICH cage column feeds a shared variable, edit schema_map.yaml.
To change HOW a derived value is computed, edit a function in REGISTRY below.

Not yet validated against real cage data — transforms marked CHECK are unverified.

Usage:
    python ct_to_shared.py --csv all_trials_2026-06-05.csv --task timedelay \
                           --monkey Porthos --out shared_2026-06-05.csv
"""

from __future__ import annotations

import argparse

import numpy as np
import pandas as pd

from schema_convert import apply_side, load_map, _col

ALL_TASKS = ["touch", "touchdot", "touchdotRL", "motion", "timedelay"]


# ----------------------------------------------------------------------------------
# CT compute transforms. Each is (df, ctx) -> Series/array, referenced from the map by
# `ct: { compute: NAME }`. Mark CHECK where the encoding is unconfirmed on real data.
# ----------------------------------------------------------------------------------
def _row_index(df, ctx):
    # 0-based row counter to mirror the BlackRock `index` column.
    return pd.Series(np.arange(len(df)), index=df.index)


def _session(df, ctx):
    # CHECK: a single cage CSV is one date/task folder. Start at session 1 and bump
    # whenever `trialnumber` resets (current < previous). Confirm this matches how you
    # want cage "sessions" defined vs BlackRock's Session join key.
    tn = pd.to_numeric(_col(df, "trialnumber", "session"), errors="coerce")
    return (tn.diff() < 0).cumsum().astype("Int64") + 1


def _direction_sign(df, ctx):
    # `direction` is a bool: True = right (+1), False = left (-1).
    # CHECK: after CSV round-trip the value may be True/False, 1/0, or "true"/"false".
    d = _col(df, "direction", "stimulus_direction")
    return d.map({True: 1, False: -1, 1: 1, 0: -1,
                  "true": 1, "false": -1, "True": 1, "False": -1})


def _stimulus_coherence(df, ctx):
    # CHECK: is cage `coherence` already signed by direction (Notion shows "-76.8 | 76.8"),
    # or a 0-1 magnitude to be signed here? If already signed, change the map to
    # `ct: { direct: coherence }` and delete this function.
    return _col(df, "coherence", "stimulus_coherence") * _direction_sign(df, ctx)


def _choice_rightward(df, ctx):
    # response string -> rightward sign (+1 right, -1 left).
    # CHECK: some cage tasks may use up/down responses; extend this map if so.
    return _col(df, "response", "choice_rightward").map({"right": 1, "left": -1})


def _choice_target(df, ctx):
    # target 1 is DEFINED as the correct target, so accuracy==1 => chose target 1.
    acc = pd.to_numeric(_col(df, "accuracy", "choice_target"), errors="coerce")
    return pd.Series(np.where(acc == 1, 1, np.where(acc == 0, 2, np.nan)), index=df.index)


def _fixation_x(df, ctx):
    # touchdotRL saves an absolute touch position; every other cage task uses screen
    # center (0). BR carries a real Fixation_position_x on its own side.
    if ctx.get("task") == "touchdotRL":
        return _col(df, "xposAbs", "fixation_x")
    return pd.Series(0.0, index=df.index)


def _fixation_y(df, ctx):
    if ctx.get("task") == "touchdotRL":
        return _col(df, "yposAbs", "fixation_y")
    return pd.Series(0.0, index=df.index)


def _is_single_choice(df, ctx):
    # True when only the correct target is shown at choice (so the answer can't be
    # wrong). applies_to = multi_target, so this only runs for motion/timedelay; if you
    # later want single-target tasks to read True, drop applies_to in the map.
    return _col(df, "onlyShowCorrect", "is_single_choice").astype("boolean")


REGISTRY = {
    "row_index": _row_index,
    "session": _session,
    "direction_sign": _direction_sign,
    "stimulus_coherence": _stimulus_coherence,
    "choice_rightward": _choice_rightward,
    "choice_target": _choice_target,
    "fixation_x": _fixation_x,
    "fixation_y": _fixation_y,
    "is_single_choice": _is_single_choice,
}


def convert_cage_to_shared(df: pd.DataFrame, task: str, monkey: str, map_path=None) -> pd.DataFrame:
    entries = load_map(map_path) if map_path else load_map()
    ctx = {"task": task, "monkey": monkey}
    return apply_side(df, entries, side="ct", ctx=ctx, registry=REGISTRY)


def main():
    ap = argparse.ArgumentParser(description="Convert a cage-training trial CSV to the shared schema.")
    ap.add_argument("--csv", required=True, help="input all_trials_<date>.csv from CageTrainingDataLoading")
    ap.add_argument("--task", required=True, choices=ALL_TASKS, help="cage task (from the folder name)")
    ap.add_argument("--monkey", required=True, help="monkey name (from the folder name)")
    ap.add_argument("--out", required=True, help="output CSV path")
    ap.add_argument("--map", default=None, help="path to schema_map.yaml (default: alongside this script)")
    args = ap.parse_args()

    df = pd.read_csv(args.csv)
    shared = convert_cage_to_shared(df, task=args.task, monkey=args.monkey, map_path=args.map)
    shared.to_csv(args.out, index=False)
    print(f"Wrote {len(shared)} rows x {shared.shape[1]} cols -> {args.out}")


if __name__ == "__main__":
    main()
