#!/usr/bin/env bash
# Arch Linux baseline installer
#
# Target profile:
# - KDE Plasma (Wayland-first)
# - Dev environment
# - Gaming stack (optional)
# - Intel + NVIDIA hybrid graphics
# - Docker intentionally omitted
#
# Usage:
#   sudo ./install.sh
#   sudo ./install.sh --dry-run
#   sudo ./install.sh --yes --with-flatpak --with-printing

set -Eeuo pipefail
trap 'echo "[ERR] line $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=0
ASSUME_YES=0
WITH_FLATPAK=0
WITH_ZEROTIER=0
WITH_PRINTING=0
SKIP_QOL=0
SKIP_GAMING=0
SKIP_DOTNET=0
SKIP_CODE=0
SHOW_REBOOT_NOTE=1
DEFAULT_LOCALE="en_US.UTF-8"
DEFAULT_TZ="UTC"

if [[ -f "$ROOT_DIR/config/defaults.conf" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/config/defaults.conf"
fi

LOG_FILE=""
declare -a UNIT_FILES=()

usage() {
  cat <<'USAGE'
Usage:
  sudo ./install.sh [flags]

Flags:
  --dry-run           Print commands without executing them
  --dry               Alias for --dry-run
  --yes               Skip confirmation prompt
  --with-flatpak      Install flatpak + KDE integration
  --with-zerotier     Install zerotier-one and enable service
  --with-printing     Install cups/printing stack and enable services
  --skip-qol          Skip browsers/media/chat/QoL packages
  --skip-gaming       Skip gaming packages
  --skip-dotnet       Skip dotnet-sdk
  --skip-code         Skip VS Code OSS (package: code)
  --no-reboot-note    Suppress final reboot recommendation
  -h, --help          Show this help
USAGE
}

msg() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERR] $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    echo "[RUN] $*"
    "$@"
  fi
}

run_shell() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] bash -lc $*"
  else
    echo "[RUN] bash -lc $*"
    bash -lc "$*"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --dry) DRY_RUN=1 ;;
      --yes) ASSUME_YES=1 ;;
      --with-flatpak) WITH_FLATPAK=1 ;;
      --with-zerotier) WITH_ZEROTIER=1 ;;
      --with-printing) WITH_PRINTING=1 ;;
      --skip-qol) SKIP_QOL=1 ;;
      --skip-gaming) SKIP_GAMING=1 ;;
      --skip-dotnet) SKIP_DOTNET=1 ;;
      --skip-code) SKIP_CODE=1 ;;
      --no-reboot-note) SHOW_REBOOT_NOTE=0 ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        warn "Unknown arg: $1"
        ;;
    esac
    shift
  done
}

validate_environment() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo ./setup.sh [flags...]"
  [[ -f /etc/arch-release ]] || warn "This script targets Arch Linux."
  have pacman || die "pacman is required"
}

prompt() {
  local msg="$1"
  local def="${2:-}"
  local ans

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    echo "$def"
    return 0
  fi

  if [[ -n "$def" ]]; then
    read -r -p "$msg [$def]: " ans
    echo "${ans:-$def}"
  else
    read -r -p "$msg: " ans
    echo "$ans"
  fi
}

wizard_partitions() {
  echo
  echo "========== Step 1/4: Partitions =========="
  echo "This setup requires only:"
  echo "  - / (root)"
  echo "  - /boot (boot)"
  echo
  echo "If partitions are not created/mounted yet, STOP and do it now."
  echo "Recommended tools: fdisk, cfdisk, or gparted."
  echo

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    msg "ASSUME_YES=1 -> skipping partition prompt."
    return 0
  fi

  local ans
  read -r -p "Are root (/) and /boot ready and mounted? [y/N]: " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *)
      echo "Aborted. Prepare partitions and re-run."
      exit 1
      ;;
  esac
}

wizard_locale() {
  echo
  echo "========== Step 2/4: Locale =========="
  local locale
  local tries=0

  while true; do
    locale="$(prompt "Locale (e.g., en_US.UTF-8)" "$DEFAULT_LOCALE")"
    [[ -n "$locale" ]] || { warn "Locale cannot be empty."; continue; }

    if [[ -f /etc/locale.gen ]] && grep -Eq "^\s*#?\s*${locale//./\\.}\s*$" /etc/locale.gen; then
      break
    fi

    warn "Locale '$locale' not found in /etc/locale.gen."
    warn "Edit /etc/locale.gen or choose a different locale."
    ((tries++))
    [[ "$tries" -ge 3 ]] && die "Too many invalid locale attempts."
  done

  msg "Configuring locale: $locale"
  if [[ -f /etc/locale.gen ]]; then
    run sed -i -E "s/^\\s*#\\s*(${locale//./\\.})\\s*$/\\1/" /etc/locale.gen
  fi
  run locale-gen
  run_shell "printf 'LANG=%s\n' '$locale' > /etc/locale.conf"
}

wizard_timezone() {
  echo
  echo "========== Step 3/4: Time Zone =========="
  local tz
  local tries=0

  while true; do
    tz="$(prompt "Time zone (e.g., America/New_York, Europe/Warsaw)" "$DEFAULT_TZ")"
    [[ -n "$tz" ]] || { warn "Time zone cannot be empty."; continue; }

    if [[ -e "/usr/share/zoneinfo/$tz" ]]; then
      break
    fi

    warn "Time zone '$tz' not found under /usr/share/zoneinfo."
    ((tries++))
    [[ "$tries" -ge 3 ]] && die "Too many invalid time zone attempts."
  done

  msg "Configuring time zone: $tz"
  run ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
  if have timedatectl; then
    run timedatectl set-timezone "$tz"
  fi
  run hwclock --systohc || true
}

wizard_summary() {
  echo
  echo "========== Step 4/4: Summary =========="
  echo "Locale and time zone have been configured."
  echo "Continuing with package installation."
}

setup_logging() {
  LOG_FILE="/var/log/arch-baseline-kde-dev-gaming-$(date +%Y%m%d-%H%M%S).log"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" || true
  exec > >(tee -a "$LOG_FILE") 2>&1
}

load_unit_files() {
  mapfile -t UNIT_FILES < <(systemctl list-unit-files --no-legend | awk '{print $1}')
}

service_exists() {
  local svc="$1"
  local unit
  for unit in "${UNIT_FILES[@]}"; do
    [[ "$unit" == "$svc" ]] && return 0
  done
  return 1
}

enable_service_if_present() {
  local svc="$1"
  if service_exists "$svc"; then
    run systemctl enable "$svc"
  else
    msg "Service not found (skip enable): $svc"
  fi
}

enable_now_if_present() {
  local svc="$1"
  if service_exists "$svc"; then
    run systemctl enable --now "$svc"
  else
    msg "Service not found (skip enable --now): $svc"
  fi
}

ensure_multilib() {
  local conf="/etc/pacman.conf"
  local backup="/etc/pacman.conf.bak.$(date +%Y%m%d-%H%M%S)"

  msg "Ensuring [multilib] is enabled in $conf"

  if grep -Eq '^\[multilib\]' "$conf"; then
    msg "multilib already enabled."
    return 0
  fi

  run cp -a "$conf" "$backup"
  msg "Backup created: $backup"

  if grep -Eq '^\s*#\s*\[multilib\]' "$conf"; then
    run sed -i \
      '/^\s*#\s*\[multilib\]/s/^\s*#\s*//; /^\s*#\s*Include\s*=\s*\/etc\/pacman\.d\/mirrorlist/s/^\s*#\s*//' \
      "$conf"
  fi

  if ! grep -Eq '^\[multilib\]' "$conf"; then
    run_shell "printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> '$conf'"
  fi

  grep -Eq '^\[multilib\]' "$conf" || die "Failed to enable multilib automatically."
  msg "multilib enabled."
}

refresh_system() {
  msg "Refreshing package databases and updating system..."
  run pacman -Syu --noconfirm
}

pkg_exists_repo() {
  pacman -Si "$1" >/dev/null 2>&1
}

install_group() {
  local label="$1"
  shift

  local -a requested=("$@")
  local -a installable=()
  local p

  for p in "${requested[@]}"; do
    if pkg_exists_repo "$p"; then
      installable+=("$p")
    else
      warn "Package not found in repos, skipping: $p"
    fi
  done

  if [[ "${#installable[@]}" -eq 0 ]]; then
    msg "No installable packages in group: $label"
    return 0
  fi

  echo
  echo "========== Installing: $label =========="
  run pacman -S --needed --noconfirm "${installable[@]}"
}

print_plan() {
  cat <<PLAN

============================================================
ARCH BASELINE PLAN (Intel iGPU + NVIDIA RTX 3070 Ti, no Docker)
============================================================
Dry run: $DRY_RUN
Flatpak: $WITH_FLATPAK
ZeroTier: $WITH_ZEROTIER
Printing: $WITH_PRINTING
Skip QoL apps: $SKIP_QOL
Skip Gaming: $SKIP_GAMING
Skip dotnet: $SKIP_DOTNET
Skip code: $SKIP_CODE
Log file: $LOG_FILE

It will:
  - enable multilib
  - run full system update (pacman -Syu)
  - install KDE Plasma + SDDM + Wayland helpers
  - install PipeWire audio stack
  - install dev toolchain + .NET (unless skipped)
  - install Intel + NVIDIA graphics stack
  - install gaming stack (unless skipped)
  - enable NetworkManager, SDDM, bluetooth, fstrim.timer
PLAN
}

confirm_or_exit() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0

  local ans
  read -r -p "Proceed? [y/N]: " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *)
      echo "Aborted."
      exit 0
      ;;
  esac
}

configure_flatpak_remote() {
  [[ "$WITH_FLATPAK" -eq 1 ]] || return 0
  have flatpak || return 0

  local cmd="flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] $cmd"
  else
    $cmd || true
  fi
}

post_user_setup() {
  [[ -n "${SUDO_USER:-}" ]] || return 0
  [[ "${SUDO_USER}" != "root" ]] || return 0
  id "$SUDO_USER" >/dev/null 2>&1 || return 0

  echo
  echo "========== User post-setup =========="
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] sudo -u $SUDO_USER xdg-user-dirs-update"
  else
    sudo -u "$SUDO_USER" xdg-user-dirs-update || true
  fi
}

install_all_packages() {
  local -a CORE_PKGS=(
    sudo bash-completion
    nano vim neovim
    curl wget rsync openssh
    unzip 7zip
    htop btop fastfetch
    lsof strace ltrace
    tree
    chrony
    man-db man-pages
    reflector
  )

  local -a BUILD_PKGS=(
    autoconf automake binutils bison debugedit fakeroot file findutils flex gawk gcc gettext grep groff gzip libtool m4 make patch pkgconf sed texinfo which
  )

  local -a NETWORK_PKGS=(
    networkmanager
    nmap tcpdump traceroute bind net-tools mosh
  )

  local -a KDE_WAYLAND_PKGS=(
    plasma-meta
    sddm sddm-kcm
    xdg-user-dirs
    xorg-xwayland
    wl-clipboard
    qt5-wayland qt6-wayland
    xdg-desktop-portal xdg-desktop-portal-kde xdg-desktop-portal-gtk
  )

  local -a KDE_APPS_PKGS=(
    dolphin konsole kate
    ark okular gwenview
    spectacle kcalc filelight
    kdeconnect
    kio-admin
    partitionmanager
  )

  local -a AUDIO_PKGS=(
    pipewire wireplumber
    pipewire-alsa pipewire-pulse pipewire-jack
    pavucontrol
  )

  local -a HW_SUPPORT_PKGS=(
    bluez bluez-utils
    fwupd
    power-profiles-daemon
    ntfs-3g exfatprogs dosfstools mtools btrfs-progs
  )

  local -a PRINTING_PKGS=(
    cups print-manager system-config-printer
    avahi nss-mdns
  )

  local -a DEV_CORE_PKGS=(
    git git-lfs
    ripgrep fd fzf bat jq
    cmake ninja
    clang lld llvm
    gdb valgrind
    python python-pip python-virtualenv python-pipx
    nodejs npm pnpm
    sqlite postgresql-libs mariadb-clients
    httpie
  )

  local -a DOTNET_PKGS=(dotnet-sdk)
  local -a EDITOR_PKGS=(code)

  local -a QOL_PKGS=(
    firefox chromium
    mpv vlc
    obs-studio
    remmina freerdp
    discord telegram-desktop
    qbittorrent
    noto-fonts noto-fonts-cjk noto-fonts-emoji
    ttf-dejavu ttf-liberation
    ttf-fira-code ttf-jetbrains-mono
  )

  local -a GPU_INTEL_NVIDIA_PKGS=(
    linux-headers
    mesa lib32-mesa
    vulkan-icd-loader lib32-vulkan-icd-loader
    vulkan-tools mesa-utils
    vulkan-intel lib32-vulkan-intel
    intel-media-driver
    nvidia-open nvidia-utils lib32-nvidia-utils
    nvidia-settings
    libva-nvidia-driver
    opencl-nvidia lib32-opencl-nvidia
  )

  local -a GAMING_PKGS=(
    steam steam-devices
    gamemode lib32-gamemode
    mangohud lib32-mangohud
    gamescope
    wine winetricks
    cabextract innoextract
  )

  local -a FLATPAK_PKGS=(flatpak flatpak-kcm)
  local -a ZEROTIER_PKGS=(zerotier-one)

  install_group "Core tools" "${CORE_PKGS[@]}"
  install_group "Build toolchain (base-devel-like)" "${BUILD_PKGS[@]}"
  install_group "Networking tools" "${NETWORK_PKGS[@]}"
  install_group "KDE Plasma + Wayland" "${KDE_WAYLAND_PKGS[@]}"
  install_group "KDE Apps" "${KDE_APPS_PKGS[@]}"
  install_group "Audio (PipeWire)" "${AUDIO_PKGS[@]}"
  install_group "Hardware support / filesystems" "${HW_SUPPORT_PKGS[@]}"
  install_group "Dev core (C/C++/Python/Node/etc.)" "${DEV_CORE_PKGS[@]}"

  if [[ "$SKIP_DOTNET" -eq 0 ]]; then
    install_group ".NET SDK" "${DOTNET_PKGS[@]}"
  else
    msg "Skipping .NET SDK"
  fi

  if [[ "$SKIP_CODE" -eq 0 ]]; then
    install_group "Editor (VS Code OSS)" "${EDITOR_PKGS[@]}"
  else
    msg "Skipping VS Code OSS"
  fi

  install_group "GPU stack (Intel + NVIDIA RTX 3070 Ti)" "${GPU_INTEL_NVIDIA_PKGS[@]}"

  if [[ "$SKIP_GAMING" -eq 0 ]]; then
    install_group "Gaming stack" "${GAMING_PKGS[@]}"
  else
    msg "Skipping gaming stack"
  fi

  if [[ "$SKIP_QOL" -eq 0 ]]; then
    install_group "QoL apps" "${QOL_PKGS[@]}"
  else
    msg "Skipping QoL apps"
  fi

  [[ "$WITH_PRINTING" -eq 1 ]] && install_group "Printing stack" "${PRINTING_PKGS[@]}"
  [[ "$WITH_FLATPAK" -eq 1 ]] && install_group "Flatpak support" "${FLATPAK_PKGS[@]}"
  [[ "$WITH_ZEROTIER" -eq 1 ]] && install_group "ZeroTier" "${ZEROTIER_PKGS[@]}"
}

enable_services() {
  load_unit_files

  echo
  echo "========== Services =========="
  enable_now_if_present "NetworkManager.service"
  enable_service_if_present "sddm.service"
  enable_now_if_present "bluetooth.service"
  enable_service_if_present "chronyd.service"
  enable_service_if_present "fstrim.timer"

  if [[ "$WITH_PRINTING" -eq 1 ]]; then
    enable_now_if_present "cups.service"
    enable_now_if_present "avahi-daemon.service"
  fi

  if [[ "$WITH_ZEROTIER" -eq 1 ]]; then
    enable_now_if_present "zerotier-one.service"
  fi
}

print_summary() {
  cat <<'POST'
============================================================
DONE
============================================================
What was installed:
- KDE Plasma (Wayland-first) + SDDM
- PipeWire audio stack
- Dev toolchain (C/C++, Python, Node, etc.)
- Intel + NVIDIA graphics stack (nvidia-open + nvidia-utils)
- Gaming stack (Steam, Wine, MangoHud, GameMode) unless skipped
- NO Docker (intentionally omitted)

Recommended next steps:
1) Reboot before gaming / Plasma Wayland login.
2) In SDDM, choose "Plasma (Wayland)" session.
3) For Steam/Proton:
   - Start Steam, enable Steam Play / Proton in settings.
4) Optional NVIDIA tuning (only if needed):
   - If Wayland session has issues, check ArchWiki NVIDIA page and ensure nvidia_drm modeset is enabled.
5) Install AUR helper later (paru) only if you need AUR packages (Heroic, Chrome, etc.).

Useful checks after reboot:
- glxinfo -B            (from mesa-utils)
- vulkaninfo --summary  (from vulkan-tools)
- nvidia-smi
- systemctl status NetworkManager sddm
POST

  if [[ "$SHOW_REBOOT_NOTE" -eq 1 ]]; then
    echo
    echo "[NOTE] Reboot recommended now."
  fi

  echo "[INFO] Log saved to: $LOG_FILE"
}

main() {
  parse_args "$@"
  validate_environment
  setup_logging
  load_unit_files

  msg "Starting Arch baseline setup..."
  wizard_partitions
  wizard_locale
  wizard_timezone
  wizard_summary
  print_plan
  confirm_or_exit

  ensure_multilib
  refresh_system
  install_all_packages
  enable_services
  configure_flatpak_remote
  post_user_setup
  print_summary
}

main "$@"
