#!/usr/bin/env python3
"""Stream Domínguez Conde Global cells from CELLxGENE Census and write
lineage-level percent-expressed tables.

Why Global only: the Myeloid / T&ILC / B compartment objects are subsets of
the same study cells; unioning them would double-count. Why we skip
is_primary_data: many of these cells also appear in other Discover
collections, so that filter drops the atlas from ~330k to ~87k cells.

X is streamed as COO tables rather than materialized as AnnData because
330k cells times ~35k genes would force a full sparse matrix into RAM
for a job that only needs per-group nnz and sum accumulators.
"""

from __future__ import annotations

import json
import os
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
import pandas as pd
import tiledbsoma as soma

from analysis.lib.lineage_map import load_lineage_map, map_cell_types_to_lineage
from analysis.lib.paths import REQUIRED_OUTPUT_NAMES, project_dir, run_output_dir

# Domínguez Conde et al. Global object in collection 62ef75e4-...
GLOBAL_DATASET_ID = "1b9d8702-5af8-4142-85ed-020eb06ec4f6"
DEFAULT_CENSUS_VERSION = "stable"
ORGANISM = "homo_sapiens"


def _census_version() -> str:
    return os.environ.get("CENSUS_VERSION", DEFAULT_CENSUS_VERSION)


def _run_id() -> str:
    run_id = os.environ.get("RUN_ID")
    if not run_id:
        raise SystemExit("ERROR: RUN_ID is required (set by submit_run.sh)")
    return run_id


def _obs_value_filter() -> str:
    # Do not add is_primary_data == True: that filter discards most of this study.
    return f"dataset_id == '{GLOBAL_DATASET_ID}'"


def _load_obs_and_lineages(census, term_to_lineage: dict[str, str]) -> pd.DataFrame:
    """Fetch obs for the Global dataset and attach lineage labels."""
    import cellxgene_census

    obs = cellxgene_census.get_obs(
        census,
        ORGANISM,
        value_filter=_obs_value_filter(),
        column_names=[
            "soma_joinid",
            "dataset_id",
            "cell_type",
            "cell_type_ontology_term_id",
            "tissue",
        ],
    )
    if obs.empty:
        raise RuntimeError(
            f"Census query returned zero cells for dataset_id={GLOBAL_DATASET_ID!r} "
            f"(census_version={_census_version()!r}). Check network access to Census "
            "or a version mismatch after a Discover refresh."
        )

    obs = obs.copy()
    obs["lineage"] = map_cell_types_to_lineage(
        obs["cell_type_ontology_term_id"].astype(str).tolist(),
        term_to_lineage,
    )
    return obs


def _build_cell_type_mapping(obs: pd.DataFrame) -> pd.DataFrame:
    counts = (
        obs.groupby(
            ["cell_type_ontology_term_id", "cell_type", "lineage"],
            observed=True,
        )
        .size()
        .reset_index(name="n_cells")
        .sort_values(["lineage", "n_cells"], ascending=[True, False])
    )
    return counts


def _lineage_cell_counts(obs: pd.DataFrame) -> pd.DataFrame:
    return (
        obs.groupby("lineage", observed=True)
        .size()
        .reset_index(name="n_cells")
        .sort_values("n_cells", ascending=False)
    )


def _accumulate_expression(
    query: soma.ExperimentAxisQuery,
    obs: pd.DataFrame,
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """One pass over raw X: percent and mean per gene x lineage and x tissue.

    Returns:
        percent_by_lineage, percent_by_lineage_tissue, var_meta
    """
    var = query.var().concat().to_pandas()
    if "soma_joinid" not in var.columns:
        raise RuntimeError("var axis missing soma_joinid")
    var = var.set_index("soma_joinid", drop=False)
    n_genes = len(var)
    gene_joinids = var["soma_joinid"].to_numpy()

    obs_indexed = obs.set_index("soma_joinid", drop=False)
    lineages = sorted(obs["lineage"].unique())
    lineage_to_idx = {name: i for i, name in enumerate(lineages)}
    n_lineages = len(lineages)

    # Series indexed by soma_joinid so each X chunk can vector-map without a
    # Python dict lookup per nnz.
    lineage_by_joinid = pd.Series(
        obs_indexed["lineage"].map(lineage_to_idx).to_numpy(dtype=np.int32),
        index=obs_indexed["soma_joinid"].to_numpy(),
        dtype=np.int32,
    )
    tissue_by_joinid = pd.Series(
        obs_indexed["tissue"].astype(str).to_numpy(),
        index=obs_indexed["soma_joinid"].to_numpy(),
    )
    gene_pos_by_joinid = pd.Series(
        np.arange(n_genes, dtype=np.int32),
        index=gene_joinids,
        dtype=np.int32,
    )

    n_cells_by_lineage = np.zeros(n_lineages, dtype=np.int64)
    for lineage, count in obs["lineage"].value_counts().items():
        n_cells_by_lineage[lineage_to_idx[lineage]] = int(count)

    n_cells_by_lineage_tissue: dict[tuple[int, str], int] = defaultdict(int)
    for lineage, tissue in zip(obs["lineage"], obs["tissue"], strict=True):
        n_cells_by_lineage_tissue[(lineage_to_idx[lineage], str(tissue))] += 1

    # Accumulators: gene x lineage (dense) and gene x lineage x tissue (sparse keys).
    n_expressed = np.zeros((n_genes, n_lineages), dtype=np.int64)
    sum_raw = np.zeros((n_genes, n_lineages), dtype=np.float64)
    n_expressed_lt: dict[tuple[int, int, str], int] = defaultdict(int)
    sum_raw_lt: dict[tuple[int, int, str], float] = defaultdict(float)

    # Vectorized chunk updates: at this scale (~10^8–10^9 nnz across the Global
    # object) a Python per-nnz loop would dominate wall time; np.add.at keeps
    # work in compiled loops while still streaming one COO batch at a time.
    n_chunks = 0
    for arrow_tbl in query.X("raw").tables():
        n_chunks += 1
        cell_ids = arrow_tbl["soma_dim_0"].to_numpy()
        gene_ids = arrow_tbl["soma_dim_1"].to_numpy()
        values = arrow_tbl["soma_data"].to_numpy().astype(np.float64, copy=False)

        lineage_idx_ser = lineage_by_joinid.reindex(cell_ids)
        gene_pos_ser = gene_pos_by_joinid.reindex(gene_ids)
        mask = (
            (values > 0)
            & lineage_idx_ser.notna().to_numpy()
            & gene_pos_ser.notna().to_numpy()
        )
        if not np.any(mask):
            continue

        gene_pos_m = gene_pos_ser.to_numpy()[mask].astype(np.int32)
        lineage_m = lineage_idx_ser.to_numpy()[mask].astype(np.int32)
        values_m = values[mask]
        np.add.at(n_expressed, (gene_pos_m, lineage_m), 1)
        np.add.at(sum_raw, (gene_pos_m, lineage_m), values_m)

        tissues_m = tissue_by_joinid.reindex(cell_ids[mask]).to_numpy()
        chunk_df = pd.DataFrame(
            {
                "gene_pos": gene_pos_m,
                "lineage_idx": lineage_m,
                "tissue": tissues_m,
                "value": values_m,
            }
        )
        grouped = chunk_df.groupby(
            ["gene_pos", "lineage_idx", "tissue"], sort=False
        ).agg(n_expressed=("value", "size"), sum_raw=("value", "sum"))
        for (gene_pos, lineage_idx, tissue), row in grouped.iterrows():
            key = (int(gene_pos), int(lineage_idx), str(tissue))
            n_expressed_lt[key] += int(row["n_expressed"])
            sum_raw_lt[key] += float(row["sum_raw"])

        if n_chunks % 50 == 0:
            print(
                f"summarize_percent: processed {n_chunks} X chunks",
                flush=True,
            )

    print(f"summarize_percent: finished {n_chunks} X chunks", flush=True)

    feature_id = var["feature_id"].to_numpy() if "feature_id" in var.columns else gene_joinids
    feature_name = (
        var["feature_name"].to_numpy()
        if "feature_name" in var.columns
        else feature_id
    )

    lineage_rows: list[dict] = []
    for gene_pos in range(n_genes):
        for lineage_idx, lineage in enumerate(lineages):
            n_cells = int(n_cells_by_lineage[lineage_idx])
            n_expr = int(n_expressed[gene_pos, lineage_idx])
            total = float(sum_raw[gene_pos, lineage_idx])
            lineage_rows.append(
                {
                    "feature_id": feature_id[gene_pos],
                    "feature_name": feature_name[gene_pos],
                    "lineage": lineage,
                    "n_cells": n_cells,
                    "n_expressed": n_expr,
                    "percent_expressed": (100.0 * n_expr / n_cells) if n_cells else 0.0,
                    "mean_raw": (total / n_cells) if n_cells else 0.0,
                }
            )
    percent_by_lineage = pd.DataFrame(lineage_rows)

    tissue_rows: list[dict] = []
    for (gene_pos, lineage_idx, tissue), n_expr in n_expressed_lt.items():
        n_cells = int(n_cells_by_lineage_tissue[(lineage_idx, tissue)])
        total = float(sum_raw_lt[(gene_pos, lineage_idx, tissue)])
        tissue_rows.append(
            {
                "feature_id": feature_id[gene_pos],
                "feature_name": feature_name[gene_pos],
                "lineage": lineages[lineage_idx],
                "tissue": tissue,
                "n_cells": n_cells,
                "n_expressed": int(n_expr),
                "percent_expressed": (100.0 * n_expr / n_cells) if n_cells else 0.0,
                "mean_raw": (total / n_cells) if n_cells else 0.0,
            }
        )
    # Include zero-expression gene x lineage x tissue groups so the table is complete
    # for groups that have cells but no detected counts for a gene. That would be
    # ~5M rows; instead we only emit groups with n_expressed > 0 and rely on n_cells
    # on the lineage-tissue side for denominators. Callers that need explicit zeros
    # can left-join against the cartesian product of genes and lineage_cell_counts.
    percent_by_lineage_tissue = pd.DataFrame(tissue_rows)
    if not percent_by_lineage_tissue.empty:
        percent_by_lineage_tissue = percent_by_lineage_tissue.sort_values(
            ["lineage", "tissue", "feature_name"]
        ).reset_index(drop=True)

    return percent_by_lineage, percent_by_lineage_tissue, var.reset_index(drop=True)


def _write_outputs(
    out_dir: Path,
    percent_by_lineage: pd.DataFrame,
    percent_by_lineage_tissue: pd.DataFrame,
    cell_type_mapping: pd.DataFrame,
    lineage_counts: pd.DataFrame,
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    percent_by_lineage.to_parquet(out_dir / "percent_by_lineage.parquet", index=False)
    percent_by_lineage.to_csv(out_dir / "percent_by_lineage.csv", index=False)
    percent_by_lineage_tissue.to_parquet(
        out_dir / "percent_by_lineage_tissue.parquet", index=False
    )
    percent_by_lineage_tissue.to_csv(
        out_dir / "percent_by_lineage_tissue.csv", index=False
    )
    cell_type_mapping.to_csv(out_dir / "cell_type_mapping.tsv", sep="\t", index=False)
    lineage_counts.to_csv(out_dir / "lineage_cell_counts.tsv", sep="\t", index=False)

    missing = [name for name in REQUIRED_OUTPUT_NAMES if not (out_dir / name).is_file()]
    if missing:
        raise RuntimeError(f"missing required outputs under {out_dir}: {missing}")


def main() -> int:
    import cellxgene_census

    run_id = _run_id()
    out_dir = run_output_dir(run_id)
    census_version = _census_version()
    map_path = project_dir() / "config" / "lineage_map.yaml"
    term_to_lineage = load_lineage_map(map_path)

    print(f"summarize_percent: PROJECT_DIR={project_dir()}", flush=True)
    print(f"summarize_percent: RUN_ID={run_id}", flush=True)
    print(f"summarize_percent: census_version={census_version}", flush=True)
    print(f"summarize_percent: dataset_id={GLOBAL_DATASET_ID}", flush=True)
    print(f"summarize_percent: output={out_dir}", flush=True)

    try:
        with cellxgene_census.open_soma(census_version=census_version) as census:
            obs = _load_obs_and_lineages(census, term_to_lineage)
            print(
                f"summarize_percent: n_cells={len(obs)} "
                f"n_lineages={obs['lineage'].nunique()} "
                f"n_tissues={obs['tissue'].nunique()}",
                flush=True,
            )
            cell_type_mapping = _build_cell_type_mapping(obs)
            lineage_counts = _lineage_cell_counts(obs)

            human = census["census_data"][ORGANISM]
            with human.axis_query(
                measurement_name="RNA",
                obs_query=soma.AxisQuery(value_filter=_obs_value_filter()),
            ) as query:
                (
                    percent_by_lineage,
                    percent_by_lineage_tissue,
                    _var,
                ) = _accumulate_expression(query, obs)
    except Exception as exc:
        # Name the failure class so ARC logs distinguish network, empty query,
        # and schema drift without reading a full traceback first.
        raise SystemExit(
            f"ERROR: Census summarize failed ({type(exc).__name__}): {exc}"
        ) from exc

    _write_outputs(
        out_dir,
        percent_by_lineage,
        percent_by_lineage_tissue,
        cell_type_mapping,
        lineage_counts,
    )

    summary = {
        "run_id": run_id,
        "census_version": census_version,
        "dataset_id": GLOBAL_DATASET_ID,
        "n_cells": int(len(obs)),
        "n_genes_lineage_table": int(percent_by_lineage["feature_id"].nunique()),
        "n_lineages": int(obs["lineage"].nunique()),
        "n_tissues": int(obs["tissue"].nunique()),
        "output_dir": str(out_dir),
    }
    (out_dir / "run_summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"summarize_percent: wrote {out_dir}", flush=True)
    return 0


if __name__ == "__main__":
    # Unbuffered logs so ARC tails show Census progress before a late OOM/kill.
    os.environ.setdefault("PYTHONUNBUFFERED", "1")
    sys.exit(main())
