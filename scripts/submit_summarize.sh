#!/bin/bash
#SBATCH --job-name=me-summarize
#SBATCH --time=8:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --partition=batch

# Dual-mode CPU summarize: stream Census Global dataset -> lineage percent tables.
# Login: bash scripts/submit_summarize.sh (requires RUN_ID from submit_run.sh)
# Runtime: host .venv python (no Apptainer).

set -euo pipefail

if [[ -z "${PROJECT_DIR:-}" ]]; then
  export PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# shellcheck source=pipeline_env.sh
source "${PROJECT_DIR}/scripts/pipeline_env.sh"

if [[ -n "${ARC_SUBMIT_ONLY:-}" || -z "${SLURM_JOB_ID:-}" ]]; then
  if [[ -z "${RUN_ID:-}" ]]; then
    echo "ERROR: RUN_ID required (submit_run.sh sets it)" >&2
    exit 1
  fi
  _TS="${RUN_TS:-$(date +%Y%m%d-%H%M%S)}"
  _DEPS="${ARC_SUMMARIZE_DEPS:-}"
  # shellcheck disable=SC2086
  exec sbatch --parsable \
    --export=ALL,ARC_SUBMIT_ONLY=,RUN_TS="${_TS}",RUN_ID="${RUN_ID}",PROJECT_DIR="${PROJECT_DIR}",OUTPUT_ROOT="${OUTPUT_ROOT}",CENSUS_VERSION="${CENSUS_VERSION}" \
    --partition="${SLURM_CPU_PARTITION}" \
    --cpus-per-task="${SUMMARIZE_CPUS}" \
    --mem="${SUMMARIZE_MEM}" \
    --time="${SUMMARIZE_TIME}" \
    ${_DEPS} \
    --output="$(arc_log_path summarize "${_TS}")" \
    "${BASH_SOURCE[0]}"
fi

if [[ -z "${RUN_ID:-}" ]]; then
  echo "ERROR: RUN_ID required on compute node" >&2
  exit 1
fi

tmpdir="$(arc_pin_job_scratch summarize)"
trap 'rm -rf "${tmpdir}"' EXIT
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-8}"
export RUN_ID OUTPUT_ROOT CENSUS_VERSION

# shellcheck source=ensure_py_venv.sh
source "${PROJECT_DIR}/scripts/ensure_py_venv.sh"
ensure_py_venv || exit 1

echo "=== MarkerExpression summarize ==="
echo "SLURM_JOB_ID=${SLURM_JOB_ID}"
echo "RUN_ID=${RUN_ID}"
echo "PROJECT_DIR=${PROJECT_DIR}"
echo "VENV_DIR=${VENV_DIR}"
echo "CENSUS_VERSION=${CENSUS_VERSION}"

"${VENV_DIR}/bin/python" "${PROJECT_DIR}/analysis/summarize_percent.py"

out_dir="${OUTPUT_ROOT}/${RUN_ID}"
for f in \
  percent_by_lineage.parquet \
  percent_by_lineage.csv \
  percent_by_lineage_tissue.parquet \
  percent_by_lineage_tissue.csv \
  cell_type_mapping.tsv \
  lineage_cell_counts.tsv \
  run_summary.json
do
  [[ -f "${out_dir}/${f}" ]] || {
    echo "ERROR: missing ${out_dir}/${f}" >&2
    exit 1
  }
done
echo "summarize OK -> ${out_dir}"
