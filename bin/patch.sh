#!/usr/bin/env bash
# patch.sh
#
# Fixes issues from the previous Arch setup run:
# - avoids perl dependency for pacman.conf multilib edit
# - installs `hostname` command (inetutils) if missing
# - avoids JACK provider conflict blocking the patch (jack2 vs pipewire-jack)
# - repairs KDE/SDDM login loop path (adds X11 fallback + safe SDDM config)
# - adds NVIDIA KMS settings for Wayland readiness
# - fixes common user ownership/session file problems
#
# Usage:
#   sudo bash patch.sh
#   sudo bash patch.sh --user <user>
#   sudo bash patch.sh --user <user> --hostname <name>
#   sudo bash patch.sh --dry-run
#
set -euo pipefail

TARGET_USER=""
TARGET_HOSTNAME=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) TARGET_USER="$2"; shift 2 ;;
    --hostname) TARGET_HOSTNAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '1,120p' "$0"
      exit 0
      ;;
    *)
      echo "[WARN] Unknown arg: $1"
      shift
      ;;
  esac
done

if [[ -z "$TARGET_USER" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  TARGET_USER="$SUDO_USER"
fi

if [[ $EUID -ne 0 ]]; then
  echo "[ERR] Run as root: sudo bash $0 [--user <user>] [--hostname <name>]"
  exit 1
fi

LOG_FILE="/var/log/arch-patch-kde-sddm-nvidia-$(date +%Y%m%d-%H%M%S).log"
mkdir -p /var/log
touch "$LOG_FILE"
chmod 600 "$LOG_FILE" || true
exec > >(tee -a "$LOG_FILE") 2>&1

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

msg()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }

pkg_installed() { pacman -Qq "$1" >/dev/null 2>&1; }
pkg_available() { pacman -Si "$1" >/dev/null 2>&1; }

ensure_multilib() {
  local conf="/etc/pacman.conf"
  msg "Ensuring [multilib] is enabled in $conf (without perl)."

  if grep -Eq '^\[multilib\]' "$conf"; then
    msg "multilib already enabled."
    return 0
  fi

  run cp -a "$conf" "${conf}.bak.$(date +%Y%m%d-%H%M%S)"

  # Uncomment an existing block if present
  if grep -Eq '^\s*#\s*\[multilib\]' "$conf"; then
    run sed -i \
      '/^\s*#\s*\[multilib\]/s/^\s*#\s*//; /^\s*#\s*Include\s*=\s*\/etc\/pacman\.d\/mirrorlist/s/^\s*#\s*//' \
      "$conf"
  fi

  # If still not enabled, append a fresh block
  if ! grep -Eq '^\[multilib\]' "$conf"; then
    run_shell "printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> '$conf'"
  fi

  grep -Eq '^\[multilib\]' "$conf" || { echo "[ERR] Failed to enable multilib."; exit 1; }
  msg "multilib enabled."
}

set_hostname_fix() {
  msg "Setting hostname to: $TARGET_HOSTNAME"
  if command -v hostnamectl >/dev/null 2>&1; then
    run hostnamectl set-hostname "$TARGET_HOSTNAME"
  else
    warn "hostnamectl not found; writing /etc/hostname directly"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] echo '$TARGET_HOSTNAME' > /etc/hostname"
    else
      printf '%s\n' "$TARGET_HOSTNAME" > /etc/hostname
    fi
  fi
}

ensure_hostname_command() {
  if ! command -v hostname >/dev/null 2>&1; then
    msg "Installing inetutils to provide the 'hostname' command."
    run pacman -S --needed --noconfirm inetutils
  else
    msg "'hostname' command already available."
  fi
}

preinstall_provider_choices() {
  msg "Pre-installing provider packages to reduce pacman provider prompts..."
  # ttf-font provider + qt6 multimedia backend
  local pkgs=(noto-fonts qt6-multimedia-ffmpeg wireplumber)
  run pacman -S --needed --noconfirm "${pkgs[@]}"
}

fix_jack_conflict() {
  msg "Handling JACK provider conflict (jack2 vs pipewire-jack)..."

  # If jack2 was pulled in earlier (provider prompt during plasma install), keep it for now.
  # This allows the patch to finish non-interactively and fixes SDDM/login first.
  if pkg_installed jack2; then
    warn "jack2 is already installed. Keeping it for now (safe non-interactive path)."
    warn "Skipping pipewire-jack in this patch run to avoid pacman conflict prompt under --noconfirm."

    local audio_pkgs=(pipewire wireplumber pipewire-alsa pipewire-pulse pavucontrol)
    run pacman -S --needed --noconfirm "${audio_pkgs[@]}"
    return 0
  fi

  # Fresh path (no jack provider installed yet): prefer PipeWire JACK provider
  local audio_pkgs=(pipewire wireplumber pipewire-alsa pipewire-pulse pipewire-jack pavucontrol)
  run pacman -S --needed --noconfirm "${audio_pkgs[@]}"
}

detect_nvidia_driver_pkg() {
  if pkg_available nvidia-open; then
    echo "nvidia-open"
  else
    echo "nvidia"
  fi
}

install_login_graphics_stack() {
  local nvidia_pkg
  nvidia_pkg="$(detect_nvidia_driver_pkg)"
  msg "Installing/repairing KDE+SDDM+graphics packages (NVIDIA package: $nvidia_pkg)..."

  local pkgs=(
    # display/login/session
    plasma-meta
    sddm sddm-kcm
    plasma-x11-session kwin-x11
    xorg-xwayland xdg-user-dirs
    xdg-desktop-portal xdg-desktop-portal-kde xdg-desktop-portal-gtk

    # network + basics
    networkmanager
    bluez bluez-utils

    # intel + nvidia graphics
    linux-headers
    mesa lib32-mesa
    vulkan-icd-loader lib32-vulkan-icd-loader
    vulkan-tools mesa-utils
    vulkan-intel lib32-vulkan-intel
    intel-media-driver
    "$nvidia_pkg" nvidia-utils lib32-nvidia-utils
    nvidia-settings
    egl-wayland
    libva-nvidia-driver

    # misc
    util-linux
  )

  run pacman -S --needed --noconfirm "${pkgs[@]}"
}

fix_user_shell_and_ownership() {
  if ! id "$TARGET_USER" >/dev/null 2>&1; then
    warn "User '$TARGET_USER' not found. Skipping home ownership/shell fixes."
    return 0
  fi

  local home shell_path
  home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  shell_path="$(getent passwd "$TARGET_USER" | cut -d: -f7)"

  msg "User: $TARGET_USER"
  msg "Home: $home"
  msg "Shell: $shell_path"

  if [[ ! -x "$shell_path" ]]; then
    warn "User shell is invalid: $shell_path -> switching to /bin/bash"
    run usermod -s /bin/bash "$TARGET_USER"
  fi

  if [[ -d "$home" ]]; then
    msg "Fixing ownership for common user login/session files..."
    local paths=(
      "$home/.Xauthority"
      "$home/.ICEauthority"
      "$home/.config"
      "$home/.cache"
      "$home/.local"
    )
    for p in "${paths[@]}"; do
      if [[ -e "$p" ]]; then
        run chown -R "$TARGET_USER:$TARGET_USER" "$p"
      fi
    done
    run chown "$TARGET_USER:$TARGET_USER" "$home" || true
    run chmod 700 "$home" || true
  fi
}

configure_sddm_safe_mode() {
  msg "Configuring SDDM for safer first login (X11 greeter + X11 session fallback)."
  run mkdir -p /etc/sddm.conf.d

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<'EOF'
[DRY-RUN] write /etc/sddm.conf.d/10-safe-display.conf:
[General]
DisplayServer=x11
EOF
  else
    cat > /etc/sddm.conf.d/10-safe-display.conf <<'EOF'
[General]
DisplayServer=x11
EOF
  fi

  # Force first login to Plasma (X11) to get into desktop reliably, then test Wayland later.
  if [[ -n "$TARGET_USER" ]] && id "$TARGET_USER" >/dev/null 2>&1 && [[ -f /usr/share/xsessions/plasma.desktop ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      cat <<EOF
[DRY-RUN] write /var/lib/sddm/state.conf:
[Last]
User=$TARGET_USER
Session=/usr/share/xsessions/plasma.desktop
EOF
    else
      install -d -m 0755 /var/lib/sddm
      cat > /var/lib/sddm/state.conf <<EOF
[Last]
User=$TARGET_USER
Session=/usr/share/xsessions/plasma.desktop
EOF
      chown sddm:sddm /var/lib/sddm/state.conf 2>/dev/null || true
      chmod 0644 /var/lib/sddm/state.conf
    fi
  fi
}

configure_nvidia_for_wayland() {
  msg "Applying NVIDIA KMS settings for Wayland compatibility..."

  run mkdir -p /etc/modprobe.d
  if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<'EOF'
[DRY-RUN] write /etc/modprobe.d/nvidia-wayland.conf:
options nvidia_drm modeset=1
EOF
  else
    cat > /etc/modprobe.d/nvidia-wayland.conf <<'EOF'
options nvidia_drm modeset=1
EOF
  fi

  # Add NVIDIA modules to mkinitcpio MODULES=() (best effort)
  if [[ -f /etc/mkinitcpio.conf ]]; then
    if ! grep -Eq 'MODULES=\(.*\bnvidia\b.*\bnvidia_modeset\b.*\bnvidia_uvm\b.*\bnvidia_drm\b' /etc/mkinitcpio.conf; then
      msg "Patching /etc/mkinitcpio.conf MODULES=() to include NVIDIA modules..."
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] sed patch /etc/mkinitcpio.conf MODULES=()"
      else
        sed -i -E 's/^MODULES=\(([^)]*)\)/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm \1)/' /etc/mkinitcpio.conf
      fi
    else
      msg "mkinitcpio NVIDIA modules already present."
    fi
  fi

  # GRUB kernel parameter (best effort)
  if [[ -f /etc/default/grub ]]; then
    if ! grep -Eq 'GRUB_CMDLINE_LINUX_DEFAULT=.*nvidia_drm\.modeset=1' /etc/default/grub; then
      msg "Adding nvidia_drm.modeset=1 to GRUB_CMDLINE_LINUX_DEFAULT..."
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] patch /etc/default/grub"
      else
        sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT=")(.*)"/\1\2 nvidia_drm.modeset=1"/' /etc/default/grub
      fi
    else
      msg "GRUB kernel parameter already present."
    fi
  fi

  # systemd-boot entries (best effort)
  local loader_dirs=(/boot/loader/entries /efi/loader/entries)
  for d in "${loader_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*.conf; do
      [[ -e "$f" ]] || continue
      if grep -Eq '^\s*options\s+.*nvidia_drm\.modeset=1' "$f"; then
        continue
      fi
      msg "Adding nvidia_drm.modeset=1 to $f"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] patch $f"
      else
        sed -i -E '/^\s*options\s+/ s/$/ nvidia_drm.modeset=1/' "$f"
      fi
    done
  done
}

rebuild_boot_artifacts() {
  msg "Rebuilding initramfs (mkinitcpio -P)..."
  run mkinitcpio -P

  if command -v grub-mkconfig >/dev/null 2>&1 && [[ -f /etc/default/grub ]]; then
    if [[ -d /boot/grub ]]; then
      msg "Regenerating GRUB config: /boot/grub/grub.cfg"
      run grub-mkconfig -o /boot/grub/grub.cfg
    elif [[ -d /boot/grub2 ]]; then
      msg "Regenerating GRUB config: /boot/grub2/grub.cfg"
      run grub-mkconfig -o /boot/grub2/grub.cfg
    else
      warn "GRUB detected but grub.cfg path not found; skipping grub-mkconfig output write."
    fi
  fi
}

enable_services() {
  msg "Enabling required services..."
  run systemctl enable --now NetworkManager.service
  run systemctl enable sddm.service
  run systemctl enable --now bluetooth.service || true
  run systemctl enable fstrim.timer || true
}

collect_diagnostics() {
  msg "Collecting SDDM/session diagnostics (best-effort)..."
  run mkdir -p /root/patch-diagnostics
  run_shell "journalctl -b -u sddm --no-pager | tail -200 > /root/patch-diagnostics/sddm-journal.txt || true"
  run_shell "journalctl -b --no-pager | grep -Ei 'sddm|kwin|plasma|wayland|nvidia' | tail -300 > /root/patch-diagnostics/session-grep.txt || true"
  run_shell "ls -la /usr/share/xsessions /usr/share/wayland-sessions > /root/patch-diagnostics/session-files.txt 2>&1 || true"
  run_shell "pacman -Q | grep -E '^(plasma|sddm|kwin|pipewire|wireplumber|jack2|nvidia|mesa|vulkan|networkmanager)' > /root/patch-diagnostics/pkg-state.txt || true"
}

main() {
  msg "Patch start (user=${TARGET_USER:-<none>}, hostname=${TARGET_HOSTNAME:-<none>})"
  msg "Log: $LOG_FILE"

  ensure_multilib
  run pacman -Syu --noconfirm

  if [[ -n "$TARGET_HOSTNAME" ]]; then
    set_hostname_fix
  else
    msg "Hostname not provided; skipping hostname change."
  fi
  ensure_hostname_command

  preinstall_provider_choices
  fix_jack_conflict

  # Critical path for your current state (login loop)
  install_login_graphics_stack
  if [[ -n "$TARGET_USER" ]]; then
    fix_user_shell_and_ownership
  else
    warn "Target user not provided; skipping user shell/ownership fixes."
  fi
  configure_sddm_safe_mode
  configure_nvidia_for_wayland

  rebuild_boot_artifacts
  enable_services
  collect_diagnostics

  cat <<EOF

============================================================
PATCH COMPLETE
============================================================
Hostname set to: ${TARGET_HOSTNAME:-<not changed>}

What this patch fixed:
- Avoided perl dependency for multilib edit
- Installed hostname command (inetutils) if missing
- Avoided jack2/pipewire-jack conflict blocking the patch (keeps jack2 if already present)
- Installed PipeWire audio stack (without forcing pipewire-jack when jack2 exists)
- Installed X11 fallback Plasma session (plasma-x11-session + kwin-x11)
- Configured SDDM to use an X11 greeter for safer first login
- Added NVIDIA KMS settings (nvidia_drm.modeset=1) for Wayland readiness
- Fixed common user ownership/shell causes of login loops
- Enabled NetworkManager + SDDM services
- Rebuilt initramfs and (if present) GRUB config

NEXT STEPS:
1) Reboot.
2) At SDDM, log into "Plasma (X11)" first.
3) After you confirm it works, test "Plasma (Wayland)".
4) If it still login-loops, send me:
   - /root/patch-diagnostics/sddm-journal.txt
   - /root/patch-diagnostics/session-grep.txt

Optional later (audio cleanup):
- If you want PipeWire JACK instead of jack2, switch manually (interactive) after the system is stable:
    pacman -S pipewire-jack
  and answer 'y' when pacman asks to remove jack2.

Log file:
  $LOG_FILE
============================================================

EOF
}

main
