#!/bin/bash
#SBATCH --job-name=me-thin-sif
#SBATCH --time=2:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --partition=batch

# Dual-mode batch worker for thin SIF build.
# Forces PROJECT_DIR/tmp scratch before Apptainer unpack (never $SLURM_TMPDIR).

set -euo pipefail

if [[ -z "${PROJECT_DIR:-}" ]]; then
  export PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# shellcheck source=pipeline_env.sh
source "${PROJECT_DIR}/scripts/pipeline_env.sh"

if [[ -n "${ARC_SUBMIT_ONLY:-}" || -z "${SLURM_JOB_ID:-}" ]]; then
  _TS="${RUN_TS:-$(date +%Y%m%d-%H%M%S)}"
  exec sbatch --parsable \
    --export=ALL,ARC_SUBMIT_ONLY=,RUN_TS="${_TS}",PROJECT_DIR="${PROJECT_DIR}" \
    --partition="${SLURM_CPU_PARTITION}" \
    --cpus-per-task="${THIN_SIF_CPUS}" \
    --mem="${THIN_SIF_MEM}" \
    --time="${THIN_SIF_TIME}" \
    --output="$(arc_log_path thin-sif "${_TS}")" \
    "${BASH_SOURCE[0]}"
fi

tmpdir="$(arc_stage_tmpdir thin-sif)"
mkdir -p -m 700 "${tmpdir}"
export TMPDIR="${tmpdir}"
export APPTAINER_TMPDIR="${tmpdir}"
export SINGULARITY_TMPDIR="${tmpdir}"
trap 'rm -rf "${tmpdir}"' EXIT

# shellcheck source=ensure_thin_sif.sh
source "${PROJECT_DIR}/scripts/ensure_thin_sif.sh"
ensure_thin_sif --build
echo "build_thin_sif OK -> ${THIN_SIF}"
