#!/usr/bin/env bash
# One-shot QEMU VM launcher for this repo.
# Behavior:
# - auto-installs missing dependencies
# - auto-downloads latest Arch ISO if missing
# - stores all artifacts in ./vm
#
# Flags:
# - --web   run headless + noVNC/websockify (if available), otherwise GUI fallback
# - --clean remove all VM artifacts from ./vm and exit

set -Eeuo pipefail
trap 'echo "[ERR] line $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VM_DIR="$ROOT_DIR/vm"

BASE_IMAGE="$VM_DIR/arch-base.qcow2"
OVERLAY_IMAGE="$VM_DIR/arch-test.qcow2"
ISO_PATH="$VM_DIR/archlinux-x86_64.iso"
SUMS_PATH="$VM_DIR/sha256sums.txt"
NOVNC_PID_FILE="$VM_DIR/novnc.pid"

DISK_SIZE="16G"
RAM_MB="4096"
CPU_COUNT="4"
VNC_BIND="127.0.0.1"
VNC_PORT="5901"
NOVNC_PORT="6080"

WEB=0
CLEAN=0
OWNER_USER="ppotepa"
OWNER_GROUP="ppotepa"

usage() {
  cat <<'USAGE'
Usage:
  bin/test-vm.sh [--web] [--clean]

Flags:
  --web   Start VM headless + noVNC/websockify (fallback to GUI if unavailable)
  --clean Remove all VM artifacts from ./vm and exit
  -h      Show help

Notes:
  - Missing dependencies are auto-installed on Arch hosts.
  - Latest Arch ISO is auto-downloaded to vm/archlinux-x86_64.iso if missing.
USAGE
}

msg() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERR] $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
is_arch() { [[ -f /etc/arch-release ]]; }
pkg_exists_repo() { pacman -Si "$1" >/dev/null 2>&1; }

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
      --web) WEB=1; shift ;;
      --clean) CLEAN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown arg: $1" ;;
    esac
  done
}

find_novnc_web_root() {
  local candidates=(
    "/usr/share/novnc"
    "/usr/share/webapps/novnc"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -d "$c" && -f "$c/vnc.html" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

run_pacman_install() {
  local -a pkgs=("$@")
  [[ "${#pkgs[@]}" -gt 0 ]] || return 0
  if [[ "$EUID" -eq 0 ]]; then
    pacman -S --needed --noconfirm "${pkgs[@]}"
  else
    sudo pacman -S --needed --noconfirm "${pkgs[@]}"
  fi
}

ensure_dependencies() {
  is_arch || die "Auto dependency install is supported only on Arch hosts."

  local -a deps=()
  have qemu-system-x86_64 || deps+=(qemu-desktop)
  have qemu-img || deps+=(qemu-desktop)
  have curl || have wget || deps+=(curl)
  mapfile -t deps < <(printf "%s\n" "${deps[@]}" | awk 'NF && !seen[$0]++')
  if [[ "${#deps[@]}" -gt 0 ]]; then
    msg "Installing dependencies: ${deps[*]}"
    run_pacman_install "${deps[@]}"
  fi

  if [[ "$WEB" -eq 1 ]]; then
    local -a web_deps=()

    if ! have websockify; then
      if pkg_exists_repo python-websockify; then
        web_deps+=(python-websockify)
      elif pkg_exists_repo websockify; then
        web_deps+=(websockify)
      fi
    fi
    if ! find_novnc_web_root >/dev/null 2>&1; then
      if pkg_exists_repo novnc; then
        web_deps+=(novnc)
      fi
    fi

    mapfile -t web_deps < <(printf "%s\n" "${web_deps[@]}" | awk 'NF && !seen[$0]++')
    if [[ "${#web_deps[@]}" -gt 0 ]]; then
      msg "Installing web mode dependencies: ${web_deps[*]}"
      run_pacman_install "${web_deps[@]}"
    fi
  fi
}

download_file() {
  local url="$1"
  local out="$2"
  if have curl; then
    curl -fL "$url" -o "$out"
  else
    wget -O "$out" "$url"
  fi
}

ensure_arch_iso() {
  [[ -f "$ISO_PATH" ]] && return 0

  local base_url="https://geo.mirror.pkgbuild.com/iso/latest"
  local iso_name="archlinux-x86_64.iso"
  local sums_name="sha256sums.txt"

  msg "Downloading latest Arch ISO..."
  download_file "$base_url/$iso_name" "$ISO_PATH"
  download_file "$base_url/$sums_name" "$SUMS_PATH"

  local expected
  expected="$(awk "/[[:space:]]${iso_name}\$/ {print \$1}" "$SUMS_PATH" | head -n1)"
  [[ -n "$expected" ]] || die "Unable to read expected checksum for $iso_name"

  local actual
  actual="$(sha256sum "$ISO_PATH" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$ISO_PATH"
    die "ISO checksum verification failed."
  fi

  msg "ISO ready: $ISO_PATH"
}

stop_novnc() {
  [[ -f "$NOVNC_PID_FILE" ]] || return 0
  local pid
  pid="$(cat "$NOVNC_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" || true
  fi
  rm -f "$NOVNC_PID_FILE"
}

clean_vm() {
  stop_novnc
  if [[ -d "$VM_DIR" ]]; then
    rm -rf "$VM_DIR"
  fi
  mkdir -p "$VM_DIR"
  msg "Clean complete: $VM_DIR"
}

start_novnc() {
  have websockify || return 1
  local web_root
  web_root="$(find_novnc_web_root)" || return 1

  stop_novnc
  msg "Starting noVNC: http://127.0.0.1:${NOVNC_PORT}/vnc.html"
  websockify --web "$web_root" "$NOVNC_PORT" "${VNC_BIND}:${VNC_PORT}" >/dev/null 2>&1 &
  echo "$!" > "$NOVNC_PID_FILE"
  return 0
}

main() {
  parse_args "$@"
  init_owner
  mkdir -p "$VM_DIR"
  fix_vm_ownership

  if [[ "$CLEAN" -eq 1 ]]; then
    clean_vm
    fix_vm_ownership
    exit 0
  fi

  ensure_dependencies
  ensure_arch_iso

  if [[ ! -f "$BASE_IMAGE" ]]; then
    msg "Creating base image: $BASE_IMAGE ($DISK_SIZE)"
    qemu-img create -f qcow2 "$BASE_IMAGE" "$DISK_SIZE" >/dev/null
  fi

  if [[ ! -f "$OVERLAY_IMAGE" ]]; then
    msg "Creating overlay image: $OVERLAY_IMAGE"
    qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$OVERLAY_IMAGE" >/dev/null
  fi

  fix_vm_ownership

  local -a qemu_cmd=(
    qemu-system-x86_64
    -machine type=q35,accel=kvm:tcg
    -cpu host
    -smp "$CPU_COUNT"
    -m "$RAM_MB"
    -drive "file=$OVERLAY_IMAGE,if=virtio,format=qcow2"
    -cdrom "$ISO_PATH"
    -boot d
    -virtfs "local,path=$ROOT_DIR,mount_tag=toolset,security_model=none,id=toolset"
    -netdev "user,id=net0,hostfwd=tcp::2222-:22"
    -device virtio-net-pci,netdev=net0
  )

  if [[ "$WEB" -eq 1 ]]; then
    local display_no=$((VNC_PORT - 5900))
    qemu_cmd+=(-display none -vnc "${VNC_BIND}:${display_no}")
    msg "VNC available at ${VNC_BIND}:${VNC_PORT}"
    if start_novnc; then
      trap stop_novnc EXIT
    else
      warn "Web mode unavailable (noVNC/websockify). Falling back to GUI."
      qemu_cmd=(
        qemu-system-x86_64
        -machine type=q35,accel=kvm:tcg
        -cpu host
        -smp "$CPU_COUNT"
        -m "$RAM_MB"
        -drive "file=$OVERLAY_IMAGE,if=virtio,format=qcow2"
        -cdrom "$ISO_PATH"
        -boot d
        -virtfs "local,path=$ROOT_DIR,mount_tag=toolset,security_model=none,id=toolset"
        -netdev "user,id=net0,hostfwd=tcp::2222-:22"
        -device virtio-net-pci,netdev=net0
        -display gtk
      )
    fi
  else
    qemu_cmd+=(-display gtk)
  fi

  msg "VM files in: $VM_DIR"
  msg "SSH forward: localhost:2222 -> guest:22"
  msg "Host project is shared to guest as 9p tag: toolset"
  msg "In guest run:"
  msg "  mkdir -p /mnt/toolset"
  msg "  mount -t 9p -o trans=virtio,version=9p2000.L toolset /mnt/toolset"
  msg "Starting QEMU..."
  "${qemu_cmd[@]}"
}

main "$@"
