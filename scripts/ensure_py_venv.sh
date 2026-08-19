#!/usr/bin/env bash
# Stamp-based ensure for the project .venv (uv.lock + pyproject.toml).
# Sync runs inside the thin SIF so the venv shebang matches container Python 3.11.
# Usage:
#   source scripts/pipeline_env.sh
#   source scripts/ensure_thin_sif.sh
#   source scripts/ensure_py_venv.sh
#   py_venv_sync_needed && submit_py_venv_job "$RUN_TS"
#   ensure_py_venv
#   ensure_py_venv --build
# shellcheck shell=bash

_ARC_VENV_STAMP_NAME=".arc-venv-hash"

_arc_venv_dir() {
  printf '%s' "${VENV_DIR:-${PROJECT_DIR}/.venv}"
}

_arc_venv_python() {
  printf '%s/bin/python' "$(_arc_venv_dir)"
}

_arc_venv_stamp_path() {
  local venv="${1:-}"
  venv="${venv:-$(_arc_venv_dir)}"
  printf '%s/%s' "${venv}" "${_ARC_VENV_STAMP_NAME}"
}

_arc_venv_lock_inputs() {
  printf '%s\n' \
    "${PROJECT_DIR}/uv.lock" \
    "${PROJECT_DIR}/pyproject.toml" \
    "${PROJECT_DIR}/.python-version"
}

_arc_venv_inputs_hash() {
  local hasher file
  if command -v sha256sum >/dev/null 2>&1; then
    hasher=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    hasher=(shasum -a 256)
  else
    echo "ERROR: need sha256sum or shasum" >&2
    return 1
  fi
  while IFS= read -r file; do
    [[ -f "${file}" ]] || {
      echo "ERROR: missing ${file}" >&2
      return 1
    }
  done < <(_arc_venv_lock_inputs)
  {
    while IFS= read -r file; do
      printf 'file:%s\n' "${file#"${PROJECT_DIR}"/}"
      cat "${file}"
    done < <(_arc_venv_lock_inputs)
  } | "${hasher[@]}" | awk '{print $1}'
}

_arc_venv_stamp_matches() {
  local venv="${1:-}" stamp expected actual
  venv="${venv:-$(_arc_venv_dir)}"
  stamp="$(_arc_venv_stamp_path "${venv}")"
  [[ -f "${stamp}" ]] || return 1
  expected="$(_arc_venv_inputs_hash)" || return 1
  actual="$(tr -d '[:space:]' < "${stamp}")"
  [[ -n "${actual}" && "${actual}" == "${expected}" ]]
}

_arc_venv_write_stamp() {
  local venv="${1:-}" stamp hash
  venv="${venv:-$(_arc_venv_dir)}"
  stamp="$(_arc_venv_stamp_path "${venv}")"
  hash="$(_arc_venv_inputs_hash)" || return 1
  printf '%s\n' "${hash}" > "${stamp}.tmp.$$"
  mv -f "${stamp}.tmp.$$" "${stamp}"
}

_arc_venv_smoke_ok() {
  local py cli
  py="$(_arc_venv_python)"
  [[ -x "${py}" ]] || return 1
  # Prefer smoke inside the thin SIF when present; fall back to host for local tests.
  if [[ -f "${THIN_SIF:-}" ]] && { command -v apptainer >/dev/null 2>&1 || command -v singularity >/dev/null 2>&1; }; then
    cli=apptainer
    command -v apptainer >/dev/null 2>&1 || cli=singularity
    "${cli}" exec \
      --bind "${PROJECT_DIR}:${PROJECT_DIR}" \
      --pwd "${PROJECT_DIR}" \
      "${THIN_SIF}" \
      "${py}" -c 'import cellxgene_census, tiledbsoma, pandas, pyarrow, yaml' >/dev/null 2>&1
  else
    "${py}" -c 'import cellxgene_census, tiledbsoma, pandas, pyarrow, yaml' >/dev/null 2>&1
  fi
}

_sync_py_venv() {
  local venv cli
  venv="$(_arc_venv_dir)"
  [[ -f "${PROJECT_DIR}/uv.lock" ]] || {
    echo "ERROR: missing ${PROJECT_DIR}/uv.lock — run uv lock and commit it" >&2
    return 1
  }

  # Sync inside the thin SIF so shebangs resolve to container Python 3.11.
  if [[ -f "${THIN_SIF:-}" ]] && { command -v apptainer >/dev/null 2>&1 || command -v singularity >/dev/null 2>&1; }; then
    cli=apptainer
    command -v apptainer >/dev/null 2>&1 || cli=singularity
    echo "Syncing .venv from uv.lock inside thin SIF (${THIN_SIF})..." >&2
    "${cli}" exec \
      --bind "${PROJECT_DIR}:${PROJECT_DIR}" \
      --pwd "${PROJECT_DIR}" \
      --env "UV_CACHE_DIR=${UV_CACHE_DIR}" \
      --env "UV_PYTHON_INSTALL_DIR=${UV_PYTHON_INSTALL_DIR}" \
      --env "UV_PROJECT_ENVIRONMENT=${venv}" \
      --env "TMPDIR=${TMPDIR:-${PROJECT_DIR}/tmp}" \
      --env "XDG_CACHE_HOME=${UV_CACHE_DIR}" \
      "${THIN_SIF}" \
      uv sync --frozen --python "${ARC_PY_VERSION}" --extra dev \
      || return 1
  else
    command -v uv >/dev/null 2>&1 || {
      echo "ERROR: uv not on PATH and thin SIF unavailable for in-container sync" >&2
      return 1
    }
    echo "Syncing .venv from uv.lock on host (no thin SIF; local/dev path)..." >&2
    (
      cd "${PROJECT_DIR}"
      UV_PROJECT_ENVIRONMENT="${venv}" uv sync --frozen --python "${ARC_PY_VERSION}" --extra dev
    ) || return 1
  fi
}

py_venv_sync_needed() {
  local venv
  venv="$(_arc_venv_dir)"
  [[ -x "$(_arc_venv_python)" ]] || return 0
  _arc_venv_stamp_matches "${venv}" || return 0
  _arc_venv_smoke_ok && return 1
  return 0
}

submit_py_venv_job() {
  local run_ts="${1:-}"
  run_ts="${run_ts:-$(date +%Y%m%d-%H%M%S)}"
  sbatch --parsable \
    --export=ALL,RUN_TS="${run_ts}",PROJECT_DIR="${PROJECT_DIR}" \
    --partition="${SLURM_CPU_PARTITION}" \
    --cpus-per-task="${PY_VENV_CPUS}" \
    --mem="${PY_VENV_MEM}" \
    --time="${PY_VENV_TIME}" \
    --output="$(arc_log_path py-venv "${run_ts}")" \
    "${PROJECT_DIR}/scripts/build_py_venv.sh"
}

ensure_py_venv() {
  local do_build=0
  [[ "${1:-}" == "--build" ]] && do_build=1
  local venv
  venv="$(_arc_venv_dir)"

  if [[ "${do_build}" -eq 0 ]] \
    && [[ -x "$(_arc_venv_python)" ]] \
    && _arc_venv_stamp_matches "${venv}" \
    && _arc_venv_smoke_ok; then
    echo "py venv OK: ${venv}" >&2
    export VENV_DIR="${venv}"
    return 0
  fi

  if [[ "${do_build}" -eq 0 ]]; then
    echo "ERROR: .venv missing or stale: ${venv}" >&2
    echo "Sync: bash scripts/build_py_venv.sh   # or ensure_py_venv --build" >&2
    return 1
  fi

  _sync_py_venv || return 1
  _arc_venv_write_stamp "${venv}" || return 1
  _arc_venv_smoke_ok || {
    echo "ERROR: venv smoke import failed after sync" >&2
    return 1
  }
  export VENV_DIR="${venv}"
  echo "py venv ready: ${venv}" >&2
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ -z "${PROJECT_DIR:-}" ]]; then
    export PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  # shellcheck source=pipeline_env.sh
  source "${PROJECT_DIR}/scripts/pipeline_env.sh"
  # shellcheck source=ensure_thin_sif.sh
  source "${PROJECT_DIR}/scripts/ensure_thin_sif.sh"
  ensure_thin_sif || true
  ensure_py_venv "${1:-}"
fi
