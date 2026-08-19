#!/usr/bin/env bash
# Shared ARC environment contract for MarkerExpression.
# Source only after PROJECT_DIR is exported by the launcher/wrapper.
# Do not derive PROJECT_DIR from BASH_SOURCE here — SLURM copies job scripts to spool.
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
SINGULARITY_CACHEDIR="${PROJECT_DIR}/.singularity_cache"
APPTAINER_CACHEDIR="${SINGULARITY_CACHEDIR}"
UV_CACHE_DIR="${PROJECT_DIR}/.uv-cache"
UV_PYTHON_INSTALL_DIR="${PROJECT_DIR}/.uv-python"
ARC_PY_VERSION="${ARC_PY_VERSION:-3.11}"
THIN_SIF_NAME="${THIN_SIF_NAME:-marker_expression_thin.sif}"
THIN_SIF="${THIN_SIF:-${SINGULARITY_CACHEDIR}/${THIN_SIF_NAME}}"
CENSUS_VERSION="${CENSUS_VERSION:-stable}"
ARC_APPTAINER_BUILD_ARGS="${ARC_APPTAINER_BUILD_ARGS:-}"

mkdir -p \
  "${LOGS_DIR}" \
  "${OUTPUT_ROOT}" \
  "${PROJECT_DIR}/tmp" \
  "${SINGULARITY_CACHEDIR}" \
  "${UV_CACHE_DIR}" \
  "${UV_PYTHON_INSTALL_DIR}"

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

arc_container_cli() {
  if command -v apptainer >/dev/null 2>&1; then
    printf 'apptainer'
  elif command -v singularity >/dev/null 2>&1; then
    printf 'singularity'
  else
    echo "ERROR: apptainer/singularity not on PATH" >&2
    return 1
  fi
}

arc_exec_python() {
  # Run project .venv python inside the thin SIF with PROJECT_DIR bound.
  local cli
  cli="$(arc_container_cli)" || return 1
  [[ -f "${THIN_SIF}" ]] || {
    echo "ERROR: thin SIF missing: ${THIN_SIF}" >&2
    return 1
  }
  [[ -x "${VENV_DIR}/bin/python" ]] || {
    echo "ERROR: venv python missing: ${VENV_DIR}/bin/python" >&2
    return 1
  }
  "${cli}" exec \
    --bind "${PROJECT_DIR}:${PROJECT_DIR}" \
    --pwd "${PROJECT_DIR}" \
    "${THIN_SIF}" \
    "${VENV_DIR}/bin/python" "$@"
}

export PROJECT_DIR OUTPUT_ROOT LOGS_DIR VENV_DIR
export SINGULARITY_CACHEDIR APPTAINER_CACHEDIR UV_CACHE_DIR UV_PYTHON_INSTALL_DIR
export SLURM_CPU_PARTITION SLURM_GPU_PARTITION ARC_PY_VERSION
export THIN_SIF_NAME THIN_SIF CENSUS_VERSION
export THIN_SIF_TIME THIN_SIF_CPUS THIN_SIF_MEM
export PY_VENV_TIME PY_VENV_CPUS PY_VENV_MEM
export SUMMARIZE_TIME SUMMARIZE_CPUS SUMMARIZE_MEM
export ARC_APPTAINER_BUILD_ARGS
# shellcheck disable=SC2034
export _DEFAULT_PROJECT_DIR
export -f arc_log_path arc_log_file arc_stage_tmpdir arc_container_cli arc_exec_python
