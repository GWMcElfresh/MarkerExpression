"""Path helpers for MarkerExpression run outputs."""

from __future__ import annotations

import os
from pathlib import Path


def project_dir() -> Path:
    return Path(os.environ.get("PROJECT_DIR", Path.cwd())).resolve()


def output_root() -> Path:
    env = os.environ.get("OUTPUT_ROOT")
    if env:
        return Path(env).resolve()
    return project_dir() / "outputs"


def run_output_dir(run_id: str) -> Path:
    return output_root() / run_id


REQUIRED_OUTPUT_NAMES = (
    "percent_by_lineage.parquet",
    "percent_by_lineage.csv",
    "percent_by_lineage_tissue.parquet",
    "percent_by_lineage_tissue.csv",
    "cell_type_mapping.tsv",
    "lineage_cell_counts.tsv",
)
