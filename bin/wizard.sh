#!/usr/bin/env bash
# Archforge modular wizard
# Usage:
#   sudo ./wizard.sh
#   sudo ./wizard.sh --dry-run
#   sudo ./wizard.sh --yes

set -Eeuo pipefail
trap 'echo "[ERR] line $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=0
ASSUME_YES=0

usage() {
  cat <<'USAGE'
Usage:
  sudo ./wizard.sh [flags]

Flags:
  --dry-run   Print commands without executing them
  --dry       Alias for --dry-run
  --yes       Skip confirmation prompt
  -h, --help  Show this help
USAGE
}

prompt_yes_no() {
  local msg="$1"
  local def="$2"
  local ans

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    echo "$def"
    return 0
  fi

  read -r -p "$msg [$def]: " ans
  ans="${ans:-$def}"
  case "$ans" in
    y|Y|yes|YES) echo "y" ;;
    *) echo "n" ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run|--dry) DRY_RUN=1 ;;
      --yes) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "[WARN] Unknown arg: $1" ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"

  echo ""
  echo "========== Archforge Modular Wizard =========="
  echo "Step 1: Base install (required for a functional system)"
  echo "Step 2: Optional modules (KDE, dev tools, gaming, etc.)"
  echo ""

  local base kde dev gaming qol gpu audio hw printing flatpak zerotier

  base="$(prompt_yes_no "Install base system packages?" "Y")"
  kde="$(prompt_yes_no "Install KDE Plasma desktop?" "Y")"
  dev="$(prompt_yes_no "Install dev toolchain?" "Y")"
  gaming="$(prompt_yes_no "Install gaming stack?" "N")"
  qol="$(prompt_yes_no "Install QoL apps (browsers/media/chat)?" "Y")"
  gpu="$(prompt_yes_no "Install Intel+NVIDIA GPU stack?" "Y")"
  audio="$(prompt_yes_no "Install PipeWire audio stack?" "Y")"
  hw="$(prompt_yes_no "Install hardware/filesystem support?" "Y")"
  printing="$(prompt_yes_no "Install printing stack?" "N")"
  flatpak="$(prompt_yes_no "Install Flatpak + KDE integration?" "N")"
  zerotier="$(prompt_yes_no "Install ZeroTier?" "N")"

  echo ""
  echo "========== Selection Summary =========="
  echo "base:     $base"
  echo "kde:      $kde"
  echo "dev:      $dev"
  echo "gaming:   $gaming"
  echo "qol:      $qol"
  echo "gpu:      $gpu"
  echo "audio:    $audio"
  echo "hw:       $hw"
  echo "printing: $printing"
  echo "flatpak:  $flatpak"
  echo "zerotier: $zerotier"
  echo ""

  if [[ "$ASSUME_YES" -ne 1 ]]; then
    local proceed
    proceed="$(prompt_yes_no "Proceed with install.sh?" "N")"
    if [[ "$proceed" != "y" ]]; then
      echo "Aborted."
      exit 0
    fi
  fi

  local -a args=()
  [[ "$DRY_RUN" -eq 1 ]] && args+=("--dry-run")
  args+=("--yes")

  local any_optional=0
  if [[ "$kde" == "y" ]]; then args+=("--with-kde"); any_optional=1; fi
  if [[ "$dev" == "y" ]]; then args+=("--with-dev"); any_optional=1; fi
  if [[ "$gaming" == "y" ]]; then args+=("--with-gaming"); any_optional=1; fi
  if [[ "$qol" == "y" ]]; then args+=("--with-qol"); any_optional=1; fi
  if [[ "$gpu" == "y" ]]; then args+=("--with-gpu"); any_optional=1; fi
  if [[ "$audio" == "y" ]]; then args+=("--with-audio"); any_optional=1; fi
  if [[ "$hw" == "y" ]]; then args+=("--with-hw"); any_optional=1; fi
  if [[ "$printing" == "y" ]]; then args+=("--with-printing"); fi
  if [[ "$flatpak" == "y" ]]; then args+=("--with-flatpak"); fi
  if [[ "$zerotier" == "y" ]]; then args+=("--with-zerotier"); fi

  if [[ "$base" == "n" ]]; then
    args+=("--no-base")
  else
    if [[ "$any_optional" -eq 0 ]]; then
      args+=("--base-only")
    fi
  fi

  echo ""
  echo "[INFO] Running: $ROOT_DIR/bin/install.sh ${args[*]}"
  "$ROOT_DIR/bin/install.sh" "${args[@]}"
}

main "$@"
