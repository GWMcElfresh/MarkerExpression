#!/usr/bin/env bash
# Shared ARC environment contract for MarkerExpression.
# Source only after PROJECT_DIR is exported by the launcher/wrapper.
# Do not derive PROJECT_DIR from BASH_SOURCE here — SLURM copies job scripts to spool.
# Python stages use host uv.lock + .venv (no Apptainer).
# shellcheck disable=SC2034

set -euo pipefail

if [[ -z "${PROJECT_DIR:-}" ]]; then
  echo "ERROR: PROJECT_DIR is unset. Export it to the checkout root before sourcing pipeline_env.sh." >&2
  exit 1
fi

# shellcheck source=../config/resources.env
source "${PROJECT_DIR}/config/resources.env"

_DEFAULT_PROJECT_DIR="/home/exacloud/gscratch/prime-seq/Bimber/GW/MarkerExpression"
OUTPUT_ROOT="${OUTPUT_ROOT:-${PROJECT_DIR}/outputs}"
LOGS_DIR="${LOGS_DIR:-${PROJECT_DIR}/logs}"
VENV_DIR="${VENV_DIR:-${PROJECT_DIR}/.venv}"
SLURM_CPU_PARTITION="${SLURM_CPU_PARTITION:-batch}"
SLURM_GPU_PARTITION="${SLURM_GPU_PARTITION:-gpu}"

# Force overwrite so --export=ALL cannot keep login-shell home caches.
UV_CACHE_DIR="${PROJECT_DIR}/.uv-cache"
UV_PYTHON_INSTALL_DIR="${PROJECT_DIR}/.uv-python"
UV_BIN_DIR="${UV_BIN_DIR:-${PROJECT_DIR}/.uv-bin}"
ARC_PY_VERSION="${ARC_PY_VERSION:-3.11}"
CENSUS_VERSION="${CENSUS_VERSION:-stable}"

mkdir -p \
  "${LOGS_DIR}" \
  "${OUTPUT_ROOT}" \
  "${PROJECT_DIR}/tmp" \
  "${UV_CACHE_DIR}" \
  "${UV_PYTHON_INSTALL_DIR}" \
  "${UV_BIN_DIR}"

arc_log_path() {
  local step="${1:-}"
  local ts="${2:-$(date +%Y%m%d-%H%M%S)}"
  printf '%s/%s-%s-%%j.out' "${LOGS_DIR}" "${step}" "${ts}"
}

arc_log_file() {
  local step="${1:-}"
  local ts="${2:-}"
  local job_id="${3:-}"
  printf '%s/%s-%s-%s.out' "${LOGS_DIR}" "${step}" "${ts}" "${job_id}"
}

arc_stage_tmpdir() {
  # Prefer project-local scratch; ARC $SLURM_TMPDIR is ~32GB and fills quickly.
  local stage="${1:-stage}"
  printf '%s/tmp/%s-%s-%s' "${PROJECT_DIR}" "${stage}" "${USER:-user}" "${SLURM_JOB_ID:-local}"
}

arc_pin_job_scratch() {
  # Per-job scratch plus library caches off $HOME. Prints the tmpdir path.
  local stage="${1:-stage}"
  local tmpdir
  tmpdir="$(arc_stage_tmpdir "${stage}")"
  mkdir -p -m 700 "${tmpdir}" "${tmpdir}/xdg-cache" "${tmpdir}/mpl"
  export TMPDIR="${tmpdir}"
  export XDG_CACHE_HOME="${tmpdir}/xdg-cache"
  export MPLCONFIGDIR="${tmpdir}/mpl"
  export PYTHONUNBUFFERED=1
  export MPLBACKEND="${MPLBACKEND:-Agg}"
  printf '%s' "${tmpdir}"
}

export PROJECT_DIR OUTPUT_ROOT LOGS_DIR VENV_DIR
export UV_CACHE_DIR UV_PYTHON_INSTALL_DIR UV_BIN_DIR
export SLURM_CPU_PARTITION SLURM_GPU_PARTITION ARC_PY_VERSION
export CENSUS_VERSION
export PY_VENV_TIME PY_VENV_CPUS PY_VENV_MEM
export SUMMARIZE_TIME SUMMARIZE_CPUS SUMMARIZE_MEM
# shellcheck disable=SC2034
export _DEFAULT_PROJECT_DIR
export -f arc_log_path arc_log_file arc_stage_tmpdir arc_pin_job_scratch
