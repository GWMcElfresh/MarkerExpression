# MarkerExpression

Lineage-level percent expression for the Domínguez Conde pan-immune atlas
([CELLxGENE collection 62ef75e4…](https://cellxgene.cziscience.com/collections/62ef75e4-cbea-454e-a0ce-998ec40223d3)).
The pipeline streams the **Global** dataset from the CELLxGENE Census API,
collapses Cell Ontology labels into a closed lineage map, and writes gene-level
percent-expressed tables (pooled by lineage, and stratified by lineage × tissue).

Science dependencies live in a committed `uv.lock` and `$PROJECT_DIR/.venv`.
A **thin** Apptainer SIF supplies OS / Python 3.11 / `uv` glue only; it does not
bake `cellxgene-census` or `tiledbsoma` into the image.

## Quick start (ARC login node)

```bash
export PROJECT_DIR=/home/exacloud/gscratch/prime-seq/Bimber/GW/MarkerExpression
# clone or sync this repo into PROJECT_DIR, then:
bash submit_run.sh

squeue -u "$USER"
tail -f logs/summarize-*.out
```

`submit_run.sh` is a login launcher only. Do not `sbatch` it. It queues:

1. thin SIF build (if missing or stale),
2. `uv sync --frozen` inside the SIF (if `.venv` is missing or stale),
3. summarize, with one `--dependency=afterok:id1:id2` over the prep jobs.

Cancel every printed job ID if you need to stop a run:

```bash
scancel <jobid> …
```

## Runtime layout

| Piece | Role |
|-------|------|
| `docker/Dockerfile.thin` | `python:3.11-slim-bookworm` + CA certs + `uv` |
| `.singularity_cache/marker_expression_thin.sif` | Built on `batch`; scratch under `$PROJECT_DIR/tmp` |
| `uv.lock` + `.venv` | Census / TileDB / pandas stack |
| `config/lineage_map.yaml` | Closed CL term → lineage table |
| `analysis/summarize_percent.py` | Stream Census `raw` X; write percent tables |

Worker invocation:

```bash
apptainer exec --bind "${PROJECT_DIR}:${PROJECT_DIR}" "${THIN_SIF}" \
  "${VENV_DIR}/bin/python" analysis/summarize_percent.py
```

## Lineages

| Lineage | Includes |
|---------|----------|
| CD4+ T Cells | helper, Tfh, EM CD4, naive CD4, Treg |
| CD8+ T Cells | memory CD8, CD45RO+ memory, TEMRA, naive CD8 |
| CD8-CD4- T Cells | γδ T and MAIT only |
| Unspecified alpha-beta T Cells | generic `alpha-beta T cell` (CL:0000789) |
| B cells | naive/memory/GC/pro/precursor B, plasma, plasmablast |
| Monocytes | classical (CD14+) and non-classical (CD16+) |
| DCs | cDC, dendritic cell human, pDC |
| Macrophages | macrophage, alveolar macrophage |
| Everything else | NK, ILC3, lymphocyte, erythroid, mast, megakaryocyte, progenitor, unknown |

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
| thin SIF | 2 | 8G | 2h |
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
| Summarize starts while SIF/venv still building | Keep a single `--dependency=afterok:id1:id2` (stacked `--dependency` flags replace each other in SLURM) |
| `mkdir .../rootfs: no such file or directory` during SIF build | Login-shell `TMPDIR` leaked via `--export=ALL` (often under `pip_cache`). Wrappers force `$PROJECT_DIR/tmp`. Resubmit `bash scripts/build_thin_sif.sh` |
| Disk full during SIF unpack | Do not use `$SLURM_TMPDIR` (~32GB). Scratch is `$PROJECT_DIR/tmp/<stage>-…` |
| `Disk quota exceeded` under `~/.cache/uv` | Confirm `UV_CACHE_DIR` / `UV_PYTHON_INSTALL_DIR` under `$PROJECT_DIR` in the job log; `rm -rf ~/.cache/uv` if home was polluted |
| `.venv` works on login, fails inside SIF | ABI/shebang mismatch (host 3.12 vs SIF 3.11). Do not `uv sync` on the login node for ARC runs. `rm -rf .venv` then `bash scripts/build_py_venv.sh` |
| Apptainer build permission errors | `ARC_APPTAINER_BUILD_ARGS=--fakeroot bash scripts/build_thin_sif.sh` |
| Census open fails (Timeout, OSError, empty query) | Compute node needs HTTPS to Census. The summarize log names the exception class. Check `sacct` then retry; H5AD ingest is a later fallback |
| Summarize OOM | Raise `SUMMARIZE_MEM` in `config/resources.env` from `sacct … MaxRSS`; logs are unbuffered so progress prints before the kill |
| Stale SIF after Dockerfile change | `bash scripts/build_thin_sif.sh` |
| Stale venv after lock/pyproject change | `bash scripts/build_py_venv.sh` |
