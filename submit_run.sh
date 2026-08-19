#!/usr/bin/env bash
# Login-node launcher: thin SIF + uv sync (one afterok list), then summarize.
#
# Usage (ARC login node):
#   export PROJECT_DIR=/home/exacloud/gscratch/prime-seq/Bimber/GW/MarkerExpression
#   bash submit_run.sh
#
# Do NOT sbatch this file. It only submits child jobs and prints IDs.

set -euo pipefail

if [[ -z "${PROJECT_DIR:-}" ]]; then
  export PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
# shellcheck source=scripts/pipeline_env.sh
source "${PROJECT_DIR}/scripts/pipeline_env.sh"
# shellcheck source=scripts/ensure_env.sh
source "${PROJECT_DIR}/scripts/ensure_env.sh"
# shellcheck source=scripts/ensure_thin_sif.sh
source "${PROJECT_DIR}/scripts/ensure_thin_sif.sh"
# shellcheck source=scripts/ensure_py_venv.sh
source "${PROJECT_DIR}/scripts/ensure_py_venv.sh"

cd "${PROJECT_DIR}"

ensure_arc_host || exit 1

RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_ID="${RUN_ID:-${RUN_TS}-$(openssl rand -hex 3 2>/dev/null || python3 -c 'import secrets; print(secrets.token_hex(3))')}"
export RUN_TS RUN_ID
export ARC_SUBMIT_ONLY=1

mkdir -p "${OUTPUT_ROOT}/${RUN_ID}"
printf '%s\n' "${RUN_ID}" > "${OUTPUT_ROOT}/${RUN_ID}/run_id.txt"

PREP_JOBS=()

if thin_sif_build_needed; then
  SJ="$(submit_thin_sif_job "${RUN_TS}")"
  PREP_JOBS+=("${SJ}")
  echo "Submitted thin SIF build: ${SJ}"
else
  ensure_thin_sif || exit 1
  echo "thin SIF already ready: ${THIN_SIF}"
fi

# uv sync must wait for a fresh SIF when one was just queued; otherwise the
# venv job races the image pull and fails ensure_thin_sif.
if py_venv_sync_needed; then
  if ((${#PREP_JOBS[@]})); then
    export ARC_PY_VENV_DEPS="--dependency=afterok:${PREP_JOBS[0]}"
  else
    export ARC_PY_VENV_DEPS=""
  fi
  VJ="$(bash "${PROJECT_DIR}/scripts/build_py_venv.sh")"
  PREP_JOBS+=("${VJ}")
  echo "Submitted py .venv sync: ${VJ}"
else
  ensure_py_venv || exit 1
  echo "py venv already ready: ${VENV_DIR}"
fi

# Single --dependency flag: repeated --dependency options replace each other in SLURM.
PREP_DEPS=""
if ((${#PREP_JOBS[@]})); then
  _prep_ids="$(IFS=:; echo "${PREP_JOBS[*]}")"
  PREP_DEPS="--dependency=afterok:${_prep_ids}"
fi

export ARC_SUMMARIZE_DEPS="${PREP_DEPS}"
SUMMARIZE_JOB="$(bash "${PROJECT_DIR}/scripts/submit_summarize.sh")"
echo "Submitted summarize: ${SUMMARIZE_JOB}"

ALL_JOBS=("${PREP_JOBS[@]+"${PREP_JOBS[@]}"}" "${SUMMARIZE_JOB}")

cat <<EOF

=== MarkerExpression run submitted ===
PROJECT_DIR=${PROJECT_DIR}
RUN_ID=${RUN_ID}
OUTPUT=${OUTPUT_ROOT}/${RUN_ID}
CENSUS_VERSION=${CENSUS_VERSION}
logs: ${LOGS_DIR}/<stage>-${RUN_TS}-<jobid>.out

Job IDs:
  prep:      ${PREP_JOBS[*]:-(none)}
  summarize: ${SUMMARIZE_JOB}

Monitor:
  squeue -u "\$USER"
  sacct -j $(IFS=,; echo "${ALL_JOBS[*]}") --format=JobID,State,ExitCode,Elapsed,MaxRSS
  tail -f $(arc_log_file summarize "${RUN_TS}" "${SUMMARIZE_JOB}")

Cancel this run:
  scancel $(IFS=' '; echo "${ALL_JOBS[*]}")
EOF
