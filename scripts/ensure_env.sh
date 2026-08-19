#!/usr/bin/env bash
# Host-side runtime checks (login node). Never builds on the login node.
# shellcheck shell=bash

ensure_host_scheduler() {
  command -v sbatch >/dev/null 2>&1 || {
    echo "ERROR: sbatch not found on PATH (run on an ARC login node)" >&2
    return 1
  }
}

ensure_host_container_cli() {
  if command -v apptainer >/dev/null 2>&1 || command -v singularity >/dev/null 2>&1; then
    return 0
  fi
  echo "WARNING: apptainer/singularity not on PATH (login nodes may lack it; SIF builds run on batch)" >&2
  return 0
}

ensure_arc_host() {
  ensure_host_scheduler || return 1
  ensure_host_container_cli
}
