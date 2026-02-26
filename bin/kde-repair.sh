#!/usr/bin/env bash
# KDE.sh (Arch) — KDE/Plasma + dev + gaming base, bez interaktywnych pytań grup pakietów
# Domyślny user: z sudo (lub podaj jako argument)
#
# Użycie:
#   sudo bash kde-repair.sh <user>
#
# Opcjonalnie:
#   RESET_KDE_CONFIG=1 sudo bash kde-repair.sh <user>   # reset/backup config KDE usera (gdy dalej loop loginu)

set -Eeuo pipefail
trap 'echo "[ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

USERNAME="${1:-}"
RESET_KDE_CONFIG="${RESET_KDE_CONFIG:-0}"

log(){ echo -e "\n[+] $*"; }
warn(){ echo -e "\n[!] $*" >&2; }
die(){ echo -e "\n[x] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Uruchom jako root (sudo)."
[[ -f /etc/arch-release ]] || die "To jest skrypt dla Arch Linux."

if [[ -z "$USERNAME" ]]; then
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    USERNAME="$SUDO_USER"
  fi
fi

[[ -n "$USERNAME" ]] || die "Podaj nazwę użytkownika (np. sudo bash KDE.sh <user>)."
id "$USERNAME" >/dev/null 2>&1 || die "Użytkownik '$USERNAME' nie istnieje."
HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
USER_GROUP="$(id -gn "$USERNAME")"
USER_SHELL="$(getent passwd "$USERNAME" | cut -d: -f7)"

# --- helpers ---
pkg_exists_repo() { pacman -Si "$1" >/dev/null 2>&1; }
pkg_installed()   { pacman -Q "$1" >/dev/null 2>&1; }

add_if_repo() {
  local p
  for p in "$@"; do
    if pkg_exists_repo "$p"; then
      PKGS+=("$p")
    fi
  done
}

unit_exists() {
  local unit="$1"
  systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit" && return 0
  [[ -f "/usr/lib/systemd/system/$unit" ]] && return 0
  [[ -f "/etc/systemd/system/$unit" ]] && return 0
  return 1
}

dir_non_empty() {
  local d="$1"
  [[ -d "$d" ]] && [[ -n "$(ls -A "$d" 2>/dev/null)" ]]
}

# --- base sanity ---
log "Podstawowe sanity checks"
chmod 1777 /tmp || true
[[ -s /etc/machine-id ]] || systemd-machine-id-setup

# --- package selection (NO package groups like xorg-apps) ---
PKGS=()

log "Buduję listę pakietów (KDE + dev + gaming base, bez interaktywnych promptów)"

# Plasma / desktop
add_if_repo \
  plasma-meta \
  plasma \
  plasma-desktop \
  konsole dolphin kate ark \
  sddm \
  xorg-server xorg-xinit xorg-xrandr xorg-xset xorg-xinput xorg-xauth \
  mesa egl-wayland \
  xdg-desktop-portal xdg-desktop-portal-kde \
  pipewire pipewire-pulse wireplumber \
  networkmanager \
  noto-fonts noto-fonts-emoji \
  git base-devel curl wget unzip zip tar rsync htop fastfetch micro nano vim \
  firefox

# Plasma appearance/themes/wallpapers (full UI experience)
add_if_repo \
  plasma-workspace-wallpapers \
  kdeplasma-addons \
  breeze breeze-gtk \
  kde-gtk-config \
  qqc2-desktop-style \
  kimageformats \
  knewstuff \
  ocean-sound-theme \
  kvantum kvantum-qt5 \
  papirus-icon-theme

# X11 fallback session (ważne przy loopie logowania na Wayland)
add_if_repo kwin-x11 plasma-x11-session

# Dev extras (lekkie, sensowne)
add_if_repo \
  python python-pip \
  nodejs npm \
  docker docker-compose \
  jq ripgrep fd

# Gaming base (Steam / tools)
add_if_repo \
  steam lutris \
  gamemode lib32-gamemode \
  mangohud lib32-mangohud \
  vulkan-icd-loader lib32-vulkan-icd-loader

# GPU-specific Vulkan/userspace (auto-detect vendor; NIE wymusza modułu kernela NVIDIA)
GPU_INFO="$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true)"
log "Wykryte GPU:"
echo "${GPU_INFO:-Brak lspci / brak danych}"

if echo "$GPU_INFO" | grep -Eqi 'AMD|Radeon'; then
  add_if_repo vulkan-radeon lib32-vulkan-radeon libva-mesa-driver lib32-libva-mesa-driver
elif echo "$GPU_INFO" | grep -Eqi 'Intel'; then
  add_if_repo vulkan-intel lib32-vulkan-intel intel-media-driver
elif echo "$GPU_INFO" | grep -Eqi 'NVIDIA'; then
  add_if_repo nvidia-utils lib32-nvidia-utils egl-wayland
  if ! pacman -Qq | grep -Eq '^nvidia($|-)|^nvidia-open($|-)|^nvidia-dkms$'; then
    warn "NVIDIA wykryta, ale nie widzę zainstalowanego sterownika kernela (nvidia / nvidia-open / nvidia-dkms)."
    warn "To CZĘSTA przyczyna black screen/login loop."
    warn "Doinstaluj właściwy sterownik do swojego kernela ręcznie."
  fi
fi

# Remove duplicates
mapfile -t PKGS < <(printf "%s\n" "${PKGS[@]}" | awk '!seen[$0]++')

log "Instalacja pakietów"
pacman -Sy --needed archlinux-keyring
pacman -Syu --needed "${PKGS[@]}"

# --- user groups (optional/common) ---
log "Dodaję common desktop/dev groups dla $USERNAME (jeśli istnieją)"
GROUP_CANDIDATES=(wheel audio video input render storage optical lp scanner uucp network docker)
EXISTING_GROUPS=()
for g in "${GROUP_CANDIDATES[@]}"; do
  getent group "$g" >/dev/null && EXISTING_GROUPS+=("$g")
done
if ((${#EXISTING_GROUPS[@]})); then
  usermod -aG "$(IFS=,; echo "${EXISTING_GROUPS[*]}")" "$USERNAME"
fi

# --- fix login-loop common causes ---
log "Naprawiam typowe przyczyny login loop (home perms, stale auth files)"
[[ -d "$HOME_DIR" ]] || die "Brak home: $HOME_DIR"
chown "$USERNAME:$USER_GROUP" "$HOME_DIR"
install -d -o "$USERNAME" -g "$USER_GROUP" -m 700 "$HOME_DIR/.config" "$HOME_DIR/.cache" "$HOME_DIR/.local" "$HOME_DIR/.local/share" "$HOME_DIR/.local/state"
chown -R "$USERNAME:$USER_GROUP" "$HOME_DIR/.config" "$HOME_DIR/.cache" "$HOME_DIR/.local" || true
rm -f "$HOME_DIR/.Xauthority" "$HOME_DIR/.ICEauthority" "$HOME_DIR/.xsession-errors" "$HOME_DIR/.xsession-errors.old"
find "$HOME_DIR" -maxdepth 1 -user root -exec chown -h "$USERNAME:$USER_GROUP" {} + 2>/dev/null || true
chmod 755 "$HOME_DIR" || true

# Optional KDE config reset (backup)
if [[ "$RESET_KDE_CONFIG" == "1" ]]; then
  log "RESET_KDE_CONFIG=1 -> backup/reset config KDE usera"
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="$HOME_DIR/kde-reset-$stamp"
  install -d -o "$USERNAME" -g "$USER_GROUP" -m 700 "$backup_dir"

  move_if_exists() { [[ -e "$1" ]] && mv "$1" "$backup_dir"/; }
  move_if_exists "$HOME_DIR/.config/kdeglobals"
  move_if_exists "$HOME_DIR/.config/plasmarc"
  move_if_exists "$HOME_DIR/.config/kwinrc"
  move_if_exists "$HOME_DIR/.config/ksmserverrc"
  move_if_exists "$HOME_DIR/.config/kscreenlockerrc"
  move_if_exists "$HOME_DIR/.config/plasmashellrc"
  move_if_exists "$HOME_DIR/.config/plasma-org.kde.plasma.desktop-appletsrc"
  move_if_exists "$HOME_DIR/.local/share/kscreen"
  shopt -s nullglob
  for f in "$HOME_DIR"/.cache/ksycoca* "$HOME_DIR"/.cache/plasmashell*; do mv "$f" "$backup_dir"/; done
  shopt -u nullglob
  chown -R "$USERNAME:$USER_GROUP" "$backup_dir"
fi

# Rebuild KDE app/plugin cache as target user
if command -v kbuildsycoca6 >/dev/null 2>&1; then
  su -s /bin/sh -c "HOME='$HOME_DIR' kbuildsycoca6 --noincremental >/dev/null 2>&1 || true" "$USERNAME" || true
fi

# --- choose DM (prefer SDDM on Arch, fallback to Plasma Login Manager) ---
log "Konfiguracja display managera"
DM=""
if unit_exists sddm.service; then
  DM="sddm.service"
elif unit_exists plasmalogin.service; then
  DM="plasmalogin.service"
else
  warn "systemctl nie widzi managera logowania przez list-unit-files."
  warn "Sprawdź: pacman -Q sddm && ls -l /usr/lib/systemd/system/sddm.service"
  die "Nie znaleziono ani plasmalogin.service, ani sddm.service"
fi

for svc in gdm.service lightdm.service lxdm.service ly.service sddm.service plasmalogin.service; do
  if unit_exists "$svc" && [[ "$svc" != "$DM" ]]; then
    systemctl disable "$svc" >/dev/null 2>&1 || true
    systemctl stop "$svc" >/dev/null 2>&1 || true
  fi
done

systemctl enable NetworkManager.service
systemctl set-default graphical.target
systemctl enable "$DM"

# --- UI completeness checks ---
log "Sprawdzam kompletność UI KDE (motywy/tapety)"
pkg_installed plasma-workspace-wallpapers || warn "Brak plasma-workspace-wallpapers (tapety mogą być puste)"
pkg_installed kdeplasma-addons || warn "Brak kdeplasma-addons (część dodatków wyglądu niedostępna)"
pkg_installed breeze || warn "Brak breeze (domyślny motyw KDE)"
pkg_installed kde-gtk-config || warn "Brak kde-gtk-config (integracja motywów GTK)"

dir_non_empty /usr/share/wallpapers || warn "Katalog /usr/share/wallpapers jest pusty lub nie istnieje"
dir_non_empty /usr/share/plasma/look-and-feel || warn "Katalog /usr/share/plasma/look-and-feel jest pusty lub nie istnieje"
dir_non_empty /usr/share/icons || warn "Katalog /usr/share/icons jest pusty lub nie istnieje"

# --- summary ---
log "Podsumowanie"
echo "User:        $USERNAME"
echo "Home:        $HOME_DIR"
echo "Shell:       $USER_SHELL"
echo "Groups:      $(id -nG "$USERNAME")"
echo "DM:          $DM"
echo "Home owner:  $(stat -c '%U:%G' "$HOME_DIR" 2>/dev/null || echo '?')"
echo "Home perms:  $(stat -c '%a' "$HOME_DIR" 2>/dev/null || echo '?')"

echo
echo "Recent DM warnings (current boot):"
journalctl -b -u plasmalogin.service -u sddm.service -p warning --no-pager -n 60 2>/dev/null || true

cat <<EOF

OK. Zrób reboot:
  reboot

Jeśli po reboot nadal login loop:
1) Na ekranie logowania wybierz sesję: Plasma (X11) zamiast Wayland.
2) Jeśli dalej loop:
   Ctrl+Alt+F3 i uruchom:
     journalctl -b -u $DM --no-pager -n 200
     journalctl -b _UID=\$(id -u $USERNAME) --no-pager -n 200
3) Spróbuj resetu configu KDE:
     RESET_KDE_CONFIG=1 sudo bash KDE.sh $USERNAME

EOF
