#!/usr/bin/env bash
# Stamp-based ensure for the thin MarkerExpression SIF (OS/Python glue only).
# Usage:
#   source scripts/pipeline_env.sh
#   source scripts/ensure_thin_sif.sh
#   thin_sif_build_needed && submit_thin_sif_job "$RUN_TS"
#   ensure_thin_sif
#   ensure_thin_sif --build
# shellcheck shell=bash

THIN_SIF_NAME="${THIN_SIF_NAME:-marker_expression_thin.sif}"

_thin_sif_path() {
  local path="${1:-}"
  path="${path:-${SINGULARITY_CACHEDIR}/${THIN_SIF_NAME}}"
  printf '%s' "${path}"
}

_thin_sif_stamp_path() {
  local sif="${1:-}"
  sif="$(_thin_sif_path "${sif}")"
  printf '%s.build-hash' "${sif}"
}

_thin_sif_inputs_hash() {
  local hasher
  if command -v sha256sum >/dev/null 2>&1; then
    hasher=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    hasher=(shasum -a 256)
  else
    echo "ERROR: need sha256sum or shasum" >&2
    return 1
  fi
  {
    printf 'file:docker/Dockerfile.thin\n'
    cat "${PROJECT_DIR}/docker/Dockerfile.thin"
  } | "${hasher[@]}" | awk '{print $1}'
}

_thin_sif_stamp_matches() {
  local sif="${1:-}" stamp expected actual
  sif="$(_thin_sif_path "${sif}")"
  stamp="$(_thin_sif_stamp_path "${sif}")"
  [[ -f "${sif}" && -f "${stamp}" ]] || return 1
  expected="$(_thin_sif_inputs_hash)" || return 1
  actual="$(tr -d '[:space:]' < "${stamp}")"
  [[ -n "${actual}" && "${actual}" == "${expected}" ]]
}

_tmpdir_usable() {
  local path="${1:-}"
  [[ -n "${path}" && -d "${path}" && -w "${path}" ]] || return 1
  # ARC login shells often export TMPDIR under pip_cache via --export=ALL;
  # Apptainer unpack then fails (mkdir .../rootfs: no such file or directory).
  [[ "${path}" != *"/pip_cache/"* && "${path}" != *"/pip_cache" ]] || return 1
  # Never keep system /tmp or limited node SLURM_TMPDIR as SIF scratch.
  [[ "${path}" != "/tmp" && "${path}" != /tmp/* ]] || return 1
  return 0
}

_ensure_build_tmpdir() {
  local tmpdir=""
  # Project-local scratch only (ARC $SLURM_TMPDIR is ~32GB).
  if _tmpdir_usable "${TMPDIR:-}" \
    && { [[ "${TMPDIR}" == "${PROJECT_DIR}/tmp" || "${TMPDIR}" == "${PROJECT_DIR}/tmp"/* ]]; }; then
    export APPTAINER_TMPDIR="${TMPDIR}"
    export SINGULARITY_TMPDIR="${TMPDIR}"
    return 0
  fi

  tmpdir="${PROJECT_DIR}/tmp/thin-sif-build-${USER:-user}-${SLURM_JOB_ID:-$$}"
  mkdir -p -m 700 "${tmpdir}"
  export TMPDIR="${tmpdir}"
  export APPTAINER_TMPDIR="${tmpdir}"
  export SINGULARITY_TMPDIR="${tmpdir}"
  echo "TMPDIR=${TMPDIR} SINGULARITY_CACHEDIR=${SINGULARITY_CACHEDIR:-} APPTAINER_CACHEDIR=${APPTAINER_CACHEDIR:-}" >&2
}

_thin_apptainer_build_args() {
  # Optional extras, e.g. ARC_APPTAINER_BUILD_ARGS='--fakeroot'
  # shellcheck disable=SC2206
  local args=( ${ARC_APPTAINER_BUILD_ARGS:-} )
  if ((${#args[@]})); then
    printf '%s\n' "${args[@]}"
  fi
}

_thin_sif_smoke_ok() {
  local sif="${1:-}" cli
  sif="$(_thin_sif_path "${sif}")"
  [[ -f "${sif}" ]] || return 1
  cli=apptainer
  command -v apptainer >/dev/null 2>&1 || cli=singularity
  command -v "${cli}" >/dev/null 2>&1 || return 1
  "${cli}" exec "${sif}" python3 -c 'import sys; assert sys.version_info[:2] == (3, 11)' >/dev/null 2>&1
}

thin_sif_build_needed() {
  local path="${1:-}"
  path="$(_thin_sif_path "${path}")"
  [[ -f "${path}" ]] || return 0
  _thin_sif_stamp_matches "${path}" || return 0
  _thin_sif_smoke_ok "${path}" && return 1
  return 0
}

submit_thin_sif_job() {
  local run_ts="${1:-}"
  run_ts="${run_ts:-$(date +%Y%m%d-%H%M%S)}"
  sbatch --parsable \
    --export=ALL,RUN_TS="${run_ts}",PROJECT_DIR="${PROJECT_DIR}" \
    --partition="${SLURM_CPU_PARTITION}" \
    --cpus-per-task="${THIN_SIF_CPUS}" \
    --mem="${THIN_SIF_MEM}" \
    --time="${THIN_SIF_TIME}" \
    --output="$(arc_log_path thin-sif "${run_ts}")" \
    "${PROJECT_DIR}/scripts/build_thin_sif.sh"
}

ensure_thin_sif() {
  local do_build=0 path cli tmp_sif
  local -a build_args=()
  [[ "${1:-}" == "--build" ]] && do_build=1
  path="$(_thin_sif_path "${2:-}")"

  if [[ "${do_build}" -eq 0 ]] \
    && _thin_sif_stamp_matches "${path}" \
    && _thin_sif_smoke_ok "${path}"; then
    echo "thin SIF OK: ${path}" >&2
    export THIN_SIF="${path}"
    return 0
  fi

  if [[ "${do_build}" -eq 0 ]]; then
    echo "ERROR: thin SIF missing or stale: ${path}" >&2
    echo "Build: bash scripts/build_thin_sif.sh" >&2
    return 1
  fi

  cli=apptainer
  command -v apptainer >/dev/null 2>&1 || cli=singularity
  command -v "${cli}" >/dev/null 2>&1 || {
    echo "ERROR: apptainer/singularity not on PATH" >&2
    return 1
  }
  [[ -f "${PROJECT_DIR}/docker/Dockerfile.thin" ]] || {
    echo "ERROR: missing ${PROJECT_DIR}/docker/Dockerfile.thin" >&2
    return 1
  }

  # Keep previous .sif until atomic replace. Invalidate stamp first so concurrent
  # thin_sif_build_needed stays true during rebuild.
  mkdir -p "$(dirname "${path}")"
  rm -f "$(_thin_sif_stamp_path "${path}")"
  _ensure_build_tmpdir
  tmp_sif="${path}.building.$$"
  build_args=()
  while IFS= read -r arg; do
    [[ -n "${arg}" ]] && build_args+=("${arg}")
  done < <(_thin_apptainer_build_args)
  echo "Building thin SIF from docker/Dockerfile.thin -> ${tmp_sif}" >&2
  if ((${#build_args[@]})); then
    "${cli}" build --force "${build_args[@]}" "${tmp_sif}" "${PROJECT_DIR}/docker/Dockerfile.thin" \
      || { rm -f "${tmp_sif}"; return 1; }
  else
    "${cli}" build --force "${tmp_sif}" "${PROJECT_DIR}/docker/Dockerfile.thin" \
      || { rm -f "${tmp_sif}"; return 1; }
  fi
  mv -f "${tmp_sif}" "${path}"
  _thin_sif_inputs_hash > "$(_thin_sif_stamp_path "${path}").tmp.$$"
  mv -f "$(_thin_sif_stamp_path "${path}").tmp.$$" "$(_thin_sif_stamp_path "${path}")"
  _thin_sif_smoke_ok "${path}" || return 1
  export THIN_SIF="${path}"
  echo "thin SIF ready: ${path}" >&2
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ -z "${PROJECT_DIR:-}" ]]; then
    export PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  # shellcheck source=pipeline_env.sh
  source "${PROJECT_DIR}/scripts/pipeline_env.sh"
  ensure_thin_sif "${1:-}"
fi
