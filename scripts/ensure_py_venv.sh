#!/usr/bin/env bash
# Stamp-based ensure for the project .venv (uv.lock + pyproject.toml).
# Host uv sync — no Apptainer (UCE_runner / ARC-Template pattern).
# Usage:
#   source scripts/pipeline_env.sh
#   source scripts/ensure_py_venv.sh
#   py_venv_sync_needed && submit_py_venv_job "$RUN_TS"
#   ensure_py_venv
#   ensure_py_venv --build
# shellcheck shell=bash

_ARC_VENV_STAMP_NAME=".arc-venv-hash"
_ARC_UV_INSTALL_VERSION="${ARC_UV_INSTALL_VERSION:-0.8.4}"

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
  local py
  py="$(_arc_venv_python)"
  [[ -x "${py}" ]] || return 1
  "${py}" -c 'import cellxgene_census, tiledbsoma, pandas, pyarrow, yaml' >/dev/null 2>&1
}

_ensure_host_uv() {
  # Prefer PATH uv; else use project-local bootstrap under UV_BIN_DIR.
  local bin_dir="${UV_BIN_DIR:-${PROJECT_DIR}/.uv-bin}"
  if command -v uv >/dev/null 2>&1; then
    return 0
  fi
  if [[ -x "${bin_dir}/uv" ]]; then
    export PATH="${bin_dir}:${PATH}"
    return 0
  fi
  return 1
}

_bootstrap_host_uv() {
  # Install uv into PROJECT_DIR/.uv-bin (replaces thin-SIF %post curl).
  # Call only from ensure_py_venv --build on a compute node — never login.
  local bin_dir="${UV_BIN_DIR:-${PROJECT_DIR}/.uv-bin}"
  mkdir -p "${bin_dir}"
  if [[ -x "${bin_dir}/uv" ]]; then
    export PATH="${bin_dir}:${PATH}"
    return 0
  fi
  echo "Bootstrapping uv ${_ARC_UV_INSTALL_VERSION} into ${bin_dir}..." >&2
  curl -LsSf "https://astral.sh/uv/${_ARC_UV_INSTALL_VERSION}/install.sh" \
    | env UV_INSTALL_DIR="${bin_dir}" sh \
    || {
      echo "ERROR: failed to bootstrap uv into ${bin_dir}" >&2
      return 1
    }
  [[ -x "${bin_dir}/uv" ]] || {
    echo "ERROR: uv binary missing after install: ${bin_dir}/uv" >&2
    return 1
  }
  export PATH="${bin_dir}:${PATH}"
  echo "uv ready: $(command -v uv) ($(uv --version))" >&2
}

_sync_py_venv() {
  local venv
  venv="$(_arc_venv_dir)"
  [[ -f "${PROJECT_DIR}/uv.lock" ]] || {
    echo "ERROR: missing ${PROJECT_DIR}/uv.lock — run uv lock and commit it" >&2
    return 1
  }

  if ! _ensure_host_uv; then
    _bootstrap_host_uv || return 1
  fi
  command -v uv >/dev/null 2>&1 || {
    echo "ERROR: uv not on PATH after bootstrap" >&2
    return 1
  }

  echo "Syncing .venv from uv.lock (frozen, python ${ARC_PY_VERSION}) in ${PROJECT_DIR}..." >&2
  (
    cd "${PROJECT_DIR}"
    # Re-export so --export=ALL cannot keep a login-shell ~/.cache/uv.
    UV_CACHE_DIR="${UV_CACHE_DIR}" \
      UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR}" \
      UV_PROJECT_ENVIRONMENT="${venv}" \
      TMPDIR="${TMPDIR:-${PROJECT_DIR}/tmp}" \
      uv sync --frozen --python "${ARC_PY_VERSION}"
  ) || return 1
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
  # Clear ARC_SUBMIT_ONLY so the worker does not re-sbatch.
  sbatch --parsable \
    --export=ALL,ARC_SUBMIT_ONLY=,RUN_TS="${run_ts}",PROJECT_DIR="${PROJECT_DIR}" \
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
  ensure_py_venv "${1:-}"
fi
