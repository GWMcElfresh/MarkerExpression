# MarkerExpression

Lineage-level percent expression for the Domínguez Conde pan-immune atlas
([CELLxGENE collection 62ef75e4…](https://cellxgene.cziscience.com/collections/62ef75e4-cbea-454e-a0ce-998ec40223d3)).
The pipeline streams the **Global** dataset from the CELLxGENE Census API,
collapses Cell Ontology labels into a closed lineage map, and writes gene-level
percent-expressed tables (pooled by lineage, and stratified by lineage × tissue).

Science dependencies live in a committed `uv.lock` and `$PROJECT_DIR/.venv`.
Python runs on the **host** (UCE_runner / saturn pattern). There is no Apptainer
SIF for this stack — fat or thin unpack on NFS/`$SLURM_TMPDIR` is a known ARC rake.

## Quick start (ARC login node)

```bash
export PROJECT_DIR=/home/exacloud/gscratch/prime-seq/Bimber/GW/MarkerExpression
# clone or sync this repo into PROJECT_DIR, then:
bash submit_run.sh

squeue -u "$USER"
tail -f logs/summarize-*.out
```

`submit_run.sh` is a login launcher only. Do not `sbatch` it. It queues:

1. `uv sync --frozen --python 3.11` into `.venv` (if missing or stale),
2. summarize, with `--dependency=afterok:<venv_job>` when prep ran.

Cancel every printed job ID if you need to stop a run:

```bash
scancel <jobid> …
```

## Runtime layout

| Piece | Role |
|-------|------|
| `uv.lock` + `.venv` | Census / TileDB / pandas stack (host) |
| `.uv-cache/` / `.uv-python/` | UV wheel + managed Python 3.11 (pinned off `$HOME`) |
| `.uv-bin/` | Optional project-local `uv` if PATH lacks it (bootstrapped on batch) |
| `config/lineage_map.yaml` | Closed CL term → lineage table |
| `analysis/summarize_percent.py` | Stream Census `raw` X; write percent tables |

Worker invocation (must run as a module from `$PROJECT_DIR`; the project is
`package = false` so `analysis` is not installed into `.venv`):

```bash
cd "${PROJECT_DIR}"
PYTHONPATH="${PROJECT_DIR}" "${VENV_DIR}/bin/python" -m analysis.summarize_percent
```

## Lineages

| Lineage | Includes |
|---------|----------|
| CD4+_T_Cells | helper, Tfh, EM CD4, naive CD4 |
| Tregs | regulatory T cell |
| CD8+_T_Cells | memory CD8, CD45RO+ memory, TEMRA, naive CD8 |
| Non-Alpha_beta_T_Cells | γδ T and MAIT only |
| Unspecified_Alpha_beta_T_Cells | generic `alpha-beta T cell` (CL:0000789) |
| B_cells | naive/memory/GC B, plasma, plasmablast |
| Pro_pre_B_cells | precursor B cell, pro-B cell |
| NK_cells | CD56-bright and CD56-dim NK |
| Monocytes | classical (CD14+) and non-classical (CD16+) |
| DCs | cDC, dendritic cell human, pDC |
| Macrophages | macrophage, alveolar macrophage |
| Progenitor_cells | generic progenitor cell (CL:0011026) |
| OtherCellTypes | ILC3, lymphocyte, erythroid, mast, megakaryocyte, unknown |

Unmapped ontology terms abort the job. Edit `config/lineage_map.yaml` and re-run.

## Outputs

Under `outputs/<run_id>/`:

- `percent_by_lineage.{parquet,csv}` — gene × lineage (tissues pooled)
- `percent_by_lineage_tissue.{parquet,csv}` — gene × lineage × tissue (non-zero expression rows)
- `cell_type_mapping.tsv` — ontology term → lineage with `n_cells`
- `lineage_cell_counts.tsv`
- `run_summary.json`

Percent expressed is the fraction of cells with raw count > 0. Tables also
carry `n_cells`, `n_expressed`, and `mean_raw`.

Dataset scope: Global only (`dataset_id=1b9d8702-5af8-4142-85ed-020eb06ec4f6`).
Compartment subsets are not unioned (they double-count). `is_primary_data` is
not applied (it drops most of this study because cells also appear in other
Discover collections). Override Census pin with `CENSUS_VERSION` (default
`stable`).

## Resources

Defaults in `config/resources.env` (`batch` only; no GPU, no `long_jobs`):

| Stage | CPUs | Mem | Time |
|-------|------|-----|------|
| uv sync | 2 | 8G | 1h |
| summarize | 8 | 64G | 8h |

## Local checks

```bash
uv sync --frozen --python 3.11 --extra dev
uv run --frozen pytest -q
```

Census streaming requires network access from the compute node. If SOMA open
fails, the log names the exception class; a later fallback is to stage the
Global H5AD onto gscratch (not in this first pass).

## Troubleshooting

Lessons carried from UCE_runner and saturn on ARC:

| Issue | Action |
|-------|--------|
| `sbatch: command not found` | Run `bash submit_run.sh` on an ARC login node; do not `sbatch submit_run.sh` |
| Summarize starts while venv still building | Keep a single `--dependency=afterok:<venv_job>` (stacked `--dependency` flags replace each other in SLURM) |
| `mkdir .../rootfs: no such file or directory` | Do **not** rebuild a SIF. This project uses host `.venv` only. Cancel leftover thin-SIF jobs and resubmit `bash submit_run.sh` |
| `Disk quota exceeded` under `~/.cache/uv` | Confirm `UV_CACHE_DIR` / `UV_PYTHON_INSTALL_DIR` under `$PROJECT_DIR` in the job log; `rm -rf ~/.cache/uv` if home was polluted |
| `ModuleNotFoundError: No module named 'analysis'` | Invoke as `python -m analysis.summarize_percent` from `$PROJECT_DIR` (with `PYTHONPATH=$PROJECT_DIR`). Do not run the `.py` file path; that puts `analysis/` on `sys.path` instead of the repo root |
| `uv` missing on compute | Venv job bootstraps `$PROJECT_DIR/.uv-bin`; or module-load/install `uv` on the node |
| Wrong Python ABI / smoke fails | Sync uses `--python 3.11`. `rm -rf .venv` then `bash scripts/build_py_venv.sh` |
| Census open fails (Timeout, OSError, empty query) | Compute node needs HTTPS to Census. The summarize log names the exception class. Check `sacct` then retry; H5AD ingest is a later fallback |
| Summarize OOM | Raise `SUMMARIZE_MEM` in `config/resources.env` from `sacct … MaxRSS`; logs are unbuffered so progress prints before the kill |
| Stale venv after lock/pyproject change | `bash scripts/build_py_venv.sh` |
