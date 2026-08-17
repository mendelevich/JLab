"""
schema_convert.py — shared engine that applies schema_map.yaml to one source.

Both converters use this:
    ct_to_shared.py  applies the "ct" side of the map to a cage CSV
    br_to_shared.py  applies the "br" side of the map to a BlackRock CSV

The map is the single source of truth (schema_map.yaml). This module knows how to
*interpret* each spec; the actual transform code for `compute:` specs lives in each
converter's REGISTRY (a dict name -> function(df, ctx) -> Series), so source-specific
logic stays with the source, not in the shared map.
"""

from __future__ import annotations

import warnings
from pathlib import Path

import numpy as np
import pandas as pd
import yaml

DEFAULT_MAP_PATH = Path(__file__).with_name("schema_map.yaml")


def load_map(path=DEFAULT_MAP_PATH) -> list:
    """Load the YAML map as a list of entry dicts (order preserved)."""
    with open(path) as f:
        return yaml.safe_load(f)


def _col(df: pd.DataFrame, name: str, shared: str) -> pd.Series:
    """Return source column `name`, or all-NaN (with a warning) if it's missing."""
    if name in df.columns:
        return df[name]
    warnings.warn(f"[schema_convert] '{shared}': source column '{name}' not found; filling NaN")
    return pd.Series(np.nan, index=df.index)


def _eval_spec(spec, df, ctx, registry, shared) -> pd.Series:
    """Turn one side's spec dict into a column. Exactly one key is expected."""
    idx = df.index
    if spec is None:                       # side omitted entirely -> treat as N/A
        return pd.Series(np.nan, index=idx)

    if "direct" in spec:
        return _col(df, spec["direct"], shared)

    if "by_task" in spec:
        colname = spec["by_task"].get(ctx.get("task"))
        if colname is None:                # this task legitimately lacks the field
            return pd.Series(np.nan, index=idx)
        return _col(df, colname, shared)

    if "const" in spec:
        return pd.Series(spec["const"], index=idx)

    if "const_ctx" in spec:
        return pd.Series(ctx.get(spec["const_ctx"]), index=idx)

    if "na" in spec:
        return pd.Series(np.nan, index=idx)

    if "todo" in spec:
        warnings.warn(f"[schema_convert] TODO ({ctx.get('task')}) '{shared}': {spec['todo']}")
        return pd.Series(np.nan, index=idx)

    if "compute" in spec:
        name = spec["compute"]
        if name not in registry:
            warnings.warn(f"[schema_convert] '{shared}': compute '{name}' not in registry; filling NaN")
            return pd.Series(np.nan, index=idx)
        return pd.Series(registry[name](df, ctx), index=idx)

    warnings.warn(f"[schema_convert] '{shared}': unrecognised spec {spec}; filling NaN")
    return pd.Series(np.nan, index=idx)


def apply_side(df: pd.DataFrame, entries: list, side: str, ctx: dict, registry: dict) -> pd.DataFrame:
    """Build the shared-schema dataframe by applying `side` ("ct" or "br") of every
    entry. Every non-skip column is always emitted (NaN where not applicable), so the
    output schema is stable across tasks and lines up column-for-column between sources.

    Task filtering (via `applies_to`) is applied only when ctx["task"] is set AND the
    entry lists `applies_to`. Pass task=None (e.g. for BR) to skip filtering and rely on
    column presence instead.
    """
    out = pd.DataFrame(index=df.index)
    task = ctx.get("task")

    for e in entries:
        if e.get("flag") == "skip":
            continue
        shared = e["shared"]
        applies_to = e.get("applies_to")            # None -> all tasks

        if task is not None and applies_to is not None and task not in applies_to:
            out[shared] = np.nan                    # present but not applicable to this task
            continue

        out[shared] = _eval_spec(e.get(side), df, ctx, registry, shared)

    return out
