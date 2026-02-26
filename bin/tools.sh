#!/usr/bin/env bash
# tools (Arch Linux) — regular KDE desktop toolset + comms + office + remoting + dev essentials
#
# Usage:
#   sudo ./tools.sh <username>
#
# Default user for home/XDG init: inferred from sudo (or skipped)
#
# Installs (high level):
# - KDE desktop apps (Dolphin, Gwenview, Okular, Spectacle, etc.)
# - WebView runtime for Qt/KDE apps (qt6-webengine)
# - GUI app manager (Discover + Flatpak + fwupd + optional PackageKit backend)
# - Browsers/mail/comms (Firefox, Thunderbird, Telegram, Edge via Flatpak)
# - IRC (Konversation + WeeChat)
# - Remote desktop/remoting (KRDC, Remmina, FreeRDP, TigerVNC, SSH/SFTP)
# - Office (LibreOffice Fresh + PL + EN-GB lang packs if available)
# - Multimedia + utilities + dev basics
#
# Notes:
# - Discover on Arch is best used mainly for Flatpak/fwupd.
# - Prefer pacman for full system updates: pacman -Syu
# - No pacman package GROUPS are used (avoids interactive "Enter a selection" prompts)

set -Eeuo pipefail
trap 'echo "[ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

USERNAME="${1:-}"

log(){ echo -e "\n[+] $*"; }
warn(){ echo -e "\n[!] $*" >&2; }
die(){ echo -e "\n[x] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
[[ -f /etc/arch-release ]] || die "This script is for Arch Linux."
command -v pacman >/dev/null 2>&1 || die "pacman not found"

pkg_exists_repo() { pacman -Si "$1" >/dev/null 2>&1; }
add_if_repo() {
  local p
  for p in "$@"; do
    if pkg_exists_repo "$p"; then
      PKGS+=("$p")
    else
      warn "Package not found in repos, skipping: $p"
    fi
  done
}

# ---------- Build package list ----------
log "Building package list (KDE regular desktop + tools)"

PKGS=()

# KDE / Plasma desktop apps (regular user expectations)
add_if_repo \
  dolphin dolphin-plugins \
  konsole kate ark \
  gwenview okular spectacle \
  filelight partitionmanager \
  plasma-systemmonitor kinfocenter \
  kcalc kcharselect \
  kdeconnect plasma-browser-integration \
  kio-admin kio-extras \
  ffmpegthumbs qt6-imageformats

# Qt/KDE "webview" runtime for embedded web content in apps
add_if_repo \
  qt6-webengine qt6-webchannel

# GUI software center / package manager UX (Discover)
# packagekit-qt6 is optional on Arch (works, but pacman remains preferred for system updates)
add_if_repo \
  discover packagekit-qt6 flatpak flatpak-kcm fwupd

# Desktop integration / portals / XDG dirs
add_if_repo \
  xdg-user-dirs xdg-desktop-portal xdg-desktop-portal-kde

# Networking UI integration
add_if_repo \
  networkmanager plasma-nm

# Browsers / mail / comms
add_if_repo \
  firefox \
  thunderbird thunderbird-i18n-pl thunderbird-i18n-en-gb \
  telegram-desktop

# Office suite (regular desktop expectation)
add_if_repo \
  libreoffice-fresh \
  libreoffice-fresh-pl \
  libreoffice-fresh-en-gb \
  hunspell hunspell-pl hunspell-en_gb \
  hyphen hyphen-pl hyphen-en \
  mythes-pl mythes-en

# IRC clients
add_if_repo \
  konversation \
  weechat

# Remote desktop / remoting
add_if_repo \
  krdc \
  remmina freerdp \
  tigervnc \
  openssh sshfs \
  samba

# Printing / scanning (common desktop use)
add_if_repo \
  cups system-config-printer \
  sane simple-scan \
  hplip

# Audio / Bluetooth / media support (common desktop quality-of-life)
add_if_repo \
  pavucontrol \
  bluedevil bluez bluez-utils \
  mpv vlc \
  ffmpeg

# File archive / filesystem helpers
add_if_repo \
  unzip zip p7zip unrar \
  rsync

# Clipboard / screenshots / productivity extras
add_if_repo \
  flameshot \
  qalculate-qt

# System utilities
add_if_repo \
  git curl wget jq ripgrep fd bat \
  micro vim tmux htop btop fastfetch \
  usbutils pciutils bind net-tools nmap \
  tree dosfstools exfatprogs ntfs-3g

# Dev basics (explicit, no base-devel group prompt)
add_if_repo \
  gcc make cmake pkgconf \
  python python-pip \
  nodejs npm \
  sqlite sqlitebrowser

# Containers (optional but useful)
add_if_repo \
  docker docker-compose

# Optional fonts for nicer desktop compatibility
add_if_repo \
  noto-fonts noto-fonts-emoji ttf-dejavu ttf-liberation

# ---------- Install ----------
# Deduplicate
mapfile -t PKGS < <(printf "%s\n" "${PKGS[@]}" | awk '!seen[$0]++')

log "Installing packages via pacman"
pacman -Sy --needed archlinux-keyring
pacman -Syu --needed "${PKGS[@]}"

# ---------- Enable useful services ----------
log "Enabling useful services (if installed)"
systemctl enable --now NetworkManager.service >/dev/null 2>&1 || true
systemctl enable --now bluetooth.service >/dev/null 2>&1 || true
systemctl enable --now cups.service >/dev/null 2>&1 || true
systemctl enable --now fwupd.service >/dev/null 2>&1 || true
systemctl enable --now docker.service >/dev/null 2>&1 || true

# ---------- Flatpak + Flathub + Microsoft Edge ----------
if command -v flatpak >/dev/null 2>&1; then
  log "Configuring Flatpak + Flathub (system-wide)"
  if ! flatpak remotes --system | awk '{print $1}' | grep -qx flathub; then
    flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo
  fi

  log "Installing Microsoft Edge (Flatpak)"
  flatpak install -y --system flathub com.microsoft.Edge || warn "Edge Flatpak install failed"

  log "Installing Flatseal (Flatpak permissions manager, optional but recommended)"
  flatpak install -y --system flathub com.github.tchx84.Flatseal || true
else
  warn "flatpak not available; skipping Microsoft Edge install"
fi

# ---------- User init (home + Desktop/Documents/etc) ----------
if [[ -z "$USERNAME" ]]; then
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    USERNAME="$SUDO_USER"
  fi
fi

if [[ -n "$USERNAME" ]] && id "$USERNAME" >/dev/null 2>&1; then
  HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
  USER_GROUP="$(id -gn "$USERNAME")"

  log "Initializing/fixing home + XDG folders for '$USERNAME'"
  mkdir -p "$HOME_DIR"
  chown "$USERNAME:$USER_GROUP" "$HOME_DIR"
  chmod 755 "$HOME_DIR" || true

  install -d -o "$USERNAME" -g "$USER_GROUP" -m 700 \
    "$HOME_DIR/.config" "$HOME_DIR/.cache" "$HOME_DIR/.local" "$HOME_DIR/.local/share" "$HOME_DIR/.local/state"

  for d in Desktop Documents Downloads Music Pictures Videos Public Templates; do
    install -d -o "$USERNAME" -g "$USER_GROUP" -m 755 "$HOME_DIR/$d"
  done

  # Copy /etc/skel defaults (do not overwrite existing files)
  if [[ -d /etc/skel ]]; then
    cp -a -n /etc/skel/. "$HOME_DIR"/ 2>/dev/null || true
  fi

  # Generate/update XDG user dirs config if available
  if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    su -s /bin/sh -c "HOME='$HOME_DIR' xdg-user-dirs-update --force >/dev/null 2>&1 || true" "$USERNAME" || true
  fi

  # Fix top-level root-owned files if any
  find "$HOME_DIR" -maxdepth 1 -user root -exec chown -h "$USERNAME:$USER_GROUP" {} + 2>/dev/null || true
else
  warn "No valid username provided — skipping user home/XDG init"
fi

# ---------- Summary ----------
log "Done — installed regular desktop tools"
cat <<EOF
Installed (highlights):
- KDE apps: Dolphin, Gwenview, Okular, Spectacle, Konsole, Kate, Ark
- WebView runtime: qt6-webengine
- GUI app manager: Discover (+ Flatpak + fwupd + packagekit-qt6)
- Browsers/Mail/Comms: Firefox, Thunderbird, Telegram Desktop, Microsoft Edge (Flatpak)
- Office: LibreOffice Fresh (+ PL + EN-GB lang packs, spelling/hyphenation packages)
- IRC: Konversation + WeeChat
- Remote desktop: KRDC, Remmina, FreeRDP, TigerVNC, SSH/SSHFS
- Extras: VLC, MPV, Flameshot, Bluetooth, Printing, Docker, dev basics

Recommended after a large install:
  reboot

Tips:
- Use Discover mostly for Flatpaks / firmware
- Use pacman for system upgrades:
  sudo pacman -Syu
- For RDP, Remmina usually gives the best UX
- For IRC, Konversation is the KDE-native choice
EOF
