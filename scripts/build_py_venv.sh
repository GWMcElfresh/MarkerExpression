#!/bin/bash
#SBATCH --job-name=me-py-venv
#SBATCH --time=1:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --partition=batch

# Dual-mode batch worker: uv sync --frozen into PROJECT_DIR/.venv (inside thin SIF).

set -euo pipefail

if [[ -z "${PROJECT_DIR:-}" ]]; then
  export PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# shellcheck source=pipeline_env.sh
source "${PROJECT_DIR}/scripts/pipeline_env.sh"

if [[ -n "${ARC_SUBMIT_ONLY:-}" || -z "${SLURM_JOB_ID:-}" ]]; then
  _TS="${RUN_TS:-$(date +%Y%m%d-%H%M%S)}"
  _DEPS="${ARC_PY_VENV_DEPS:-}"
  # shellcheck disable=SC2086
  exec sbatch --parsable \
    --export=ALL,ARC_SUBMIT_ONLY=,RUN_TS="${_TS}",PROJECT_DIR="${PROJECT_DIR}" \
    --partition="${SLURM_CPU_PARTITION}" \
    --cpus-per-task="${PY_VENV_CPUS}" \
    --mem="${PY_VENV_MEM}" \
    --time="${PY_VENV_TIME}" \
    ${_DEPS} \
    --output="$(arc_log_path py-venv "${_TS}")" \
    "${BASH_SOURCE[0]}"
fi

tmpdir="$(arc_stage_tmpdir py-venv)"
mkdir -p -m 700 "${tmpdir}"
export TMPDIR="${tmpdir}"
trap 'rm -rf "${tmpdir}"' EXIT

# shellcheck source=ensure_thin_sif.sh
source "${PROJECT_DIR}/scripts/ensure_thin_sif.sh"
ensure_thin_sif || exit 1

# shellcheck source=ensure_py_venv.sh
source "${PROJECT_DIR}/scripts/ensure_py_venv.sh"
ensure_py_venv --build
echo "build_py_venv OK -> ${VENV_DIR}"
