#!/usr/bin/env bash
# Reset VM test state by removing overlay and stopping helper processes.
# Keeps base image by default.

set -Eeuo pipefail
trap 'echo "[ERR] line $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VM_DIR="$ROOT_DIR/vm"

BASE_IMAGE="$VM_DIR/arch-base.qcow2"
OVERLAY_IMAGE="$VM_DIR/arch-test.qcow2"
NOVNC_PID_FILE="$VM_DIR/novnc.pid"

REMOVE_BASE=0
OWNER_USER="ppotepa"
OWNER_GROUP="ppotepa"

usage() {
  cat <<'USAGE'
Usage:
  bin/reset-vm.sh [flags]

Flags:
  --all       Remove overlay and base image
  -h, --help  Show help

Default behavior:
  - stop noVNC if started by test-vm.sh
  - remove only overlay (arch-test.qcow2)
  - keep base image (arch-base.qcow2)
USAGE
}

msg() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }

init_owner() {
  if [[ "$EUID" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    if id "$SUDO_USER" >/dev/null 2>&1; then
      OWNER_USER="$SUDO_USER"
      OWNER_GROUP="$(id -gn "$SUDO_USER")"
      return 0
    fi
  fi

  if id ppotepa >/dev/null 2>&1; then
    OWNER_USER="ppotepa"
    OWNER_GROUP="$(id -gn ppotepa)"
  fi
}

fix_vm_ownership() {
  [[ "$EUID" -eq 0 ]] || return 0
  [[ -d "$VM_DIR" ]] || return 0
  chown -R "${OWNER_USER}:${OWNER_GROUP}" "$VM_DIR" || true
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) REMOVE_BASE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "[ERR] Unknown arg: $1" >&2; exit 1 ;;
    esac
  done
}

stop_novnc() {
  [[ -f "$NOVNC_PID_FILE" ]] || return 0
  local pid
  pid="$(cat "$NOVNC_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    msg "Stopping noVNC (PID $pid)"
    kill "$pid" || true
  fi
  rm -f "$NOVNC_PID_FILE"
}

main() {
  parse_args "$@"
  init_owner
  mkdir -p "$VM_DIR"
  fix_vm_ownership

  stop_novnc

  if [[ -f "$OVERLAY_IMAGE" ]]; then
    msg "Removing overlay image: $OVERLAY_IMAGE"
    rm -f "$OVERLAY_IMAGE"
  else
    warn "Overlay image not found: $OVERLAY_IMAGE"
  fi

  if [[ "$REMOVE_BASE" -eq 1 ]]; then
    if [[ -f "$BASE_IMAGE" ]]; then
      msg "Removing base image: $BASE_IMAGE"
      rm -f "$BASE_IMAGE"
    else
      warn "Base image not found: $BASE_IMAGE"
    fi
  else
    msg "Keeping base image: $BASE_IMAGE"
  fi

  fix_vm_ownership
  msg "VM reset complete."
}

main "$@"
