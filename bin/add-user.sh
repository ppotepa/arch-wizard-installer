#!/usr/bin/env bash
# adduser (Arch Linux) - create or repair user account + home + XDG folders
# Default: NO password (account password is locked)
#
# Usage:
#   sudo ./add-user.sh <username>
#   sudo ./add-user.sh <username> --shell /bin/zsh
#   sudo ./add-user.sh <username> --home /home/customname
#   sudo ./add-user.sh <username> --with-password   # only unlocks account if password already set manually later
#
# Notes:
# - "No passwd" here means: user is created without prompting for password and password login is LOCKED.
# - To set password later: passwd <username>

set -Eeuo pipefail
trap 'echo "[ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

USERNAME=""
USER_SHELL="/bin/bash"
HOME_OVERRIDE=""
WITH_PASSWORD=0

log(){ echo -e "\n[+] $*"; }
warn(){ echo -e "\n[!] $*" >&2; }
die(){ echo -e "\n[x] $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo ./adduser <username> [--shell /bin/bash] [--home /home/username] [--with-password]

Default behavior:
  - creates user without asking for password
  - password remains LOCKED (safer than empty password)
  - creates/repairs home directory
  - creates XDG folders: Desktop, Documents, Downloads, Music, Pictures, Videos, Public, Templates
EOF
}

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
[[ -f /etc/arch-release ]] || warn "Script written for Arch Linux (should still work on most Linux systems)."

# --- parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell)
      shift; [[ $# -gt 0 ]] || die "--shell requires argument"
      USER_SHELL="$1"
      ;;
    --home)
      shift; [[ $# -gt 0 ]] || die "--home requires argument"
      HOME_OVERRIDE="$1"
      ;;
    --with-password)
      WITH_PASSWORD=1
      ;;
    -h|--help)
      usage; exit 0
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if [[ -z "$USERNAME" ]]; then
        USERNAME="$1"
      else
        die "Unexpected extra argument: $1"
      fi
      ;;
  esac
  shift
done

[[ -n "$USERNAME" ]] || { usage; die "Username is required."; }

# username sanity (simple)
if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  die "Invalid username: '$USERNAME' (use lowercase letters/digits/_/-)"
fi

# shell sanity
if [[ ! -x "$USER_SHELL" ]]; then
  warn "Shell '$USER_SHELL' not found/executable. Falling back to /bin/bash."
  USER_SHELL="/bin/bash"
fi

# determine home
if id "$USERNAME" >/dev/null 2>&1; then
  EXISTING=1
  HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
  [[ -n "$HOME_OVERRIDE" ]] && HOME_DIR="$HOME_OVERRIDE"
else
  EXISTING=0
  HOME_DIR="${HOME_OVERRIDE:-/home/$USERNAME}"
fi

# common groups (only if exist)
COMMON_GROUPS=(wheel audio video input render storage optical lp scanner uucp network docker)
EXISTING_GROUPS=()
for g in "${COMMON_GROUPS[@]}"; do
  getent group "$g" >/dev/null && EXISTING_GROUPS+=("$g")
done
GROUP_CSV=""
if ((${#EXISTING_GROUPS[@]})); then
  GROUP_CSV="$(IFS=,; echo "${EXISTING_GROUPS[*]}")"
fi

create_or_update_user() {
  if [[ "$EXISTING" -eq 0 ]]; then
    log "Creating user '$USERNAME' (no password prompt, locked password by default)"
    # -m creates home, -U creates user private group
    # -k /etc/skel copies skeleton if available
    if [[ -n "$GROUP_CSV" ]]; then
      useradd -m -d "$HOME_DIR" -s "$USER_SHELL" -U -G "$GROUP_CSV" -k /etc/skel "$USERNAME"
    else
      useradd -m -d "$HOME_DIR" -s "$USER_SHELL" -U -k /etc/skel "$USERNAME"
    fi
  else
    log "User '$USERNAME' already exists -> repairing/updating settings"
    # Update shell/home in passwd entry if override passed
    usermod -s "$USER_SHELL" "$USERNAME"
    if [[ -n "$HOME_OVERRIDE" ]]; then
      # Set home path; do not move automatically (we handle directory creation/repair below)
      usermod -d "$HOME_DIR" "$USERNAME"
    fi
    if [[ -n "$GROUP_CSV" ]]; then
      usermod -aG "$GROUP_CSV" "$USERNAME"
    fi
  fi

  # Password handling
  if [[ "$WITH_PASSWORD" -eq 0 ]]; then
    # LOCK password (safe "no passwd" mode)
    passwd -l "$USERNAME" >/dev/null 2>&1 || true
    echo "Password state: LOCKED (no password login)."
  else
    echo "Password state: not forced locked by script."
    echo "If this is a new user, set password manually with: passwd $USERNAME"
  fi
}

ensure_home_exists_and_owned() {
  log "Ensuring home exists and ownership is correct"
  mkdir -p "$HOME_DIR"

  local primary_group
  primary_group="$(id -gn "$USERNAME")"

  chown "$USERNAME:$primary_group" "$HOME_DIR"
  chmod 755 "$HOME_DIR" || true

  # If /etc/skel exists, copy missing files only (do not overwrite existing)
  if [[ -d /etc/skel ]]; then
    # cp -a -n = archive, no-clobber
    cp -a -n /etc/skel/. "$HOME_DIR"/ 2>/dev/null || true
  fi

  # Make sure common dirs exist
  install -d -o "$USERNAME" -g "$primary_group" -m 700 \
    "$HOME_DIR/.config" "$HOME_DIR/.cache" "$HOME_DIR/.local" "$HOME_DIR/.local/share" "$HOME_DIR/.local/state"

  # XDG dirs (English names by default)
  for d in Desktop Documents Downloads Music Pictures Videos Public Templates; do
    install -d -o "$USERNAME" -g "$primary_group" -m 755 "$HOME_DIR/$d"
  done

  # Fix top-level wrong ownership (common when root touched files in home)
  find "$HOME_DIR" -maxdepth 1 -user root -exec chown -h "$USERNAME:$primary_group" {} + 2>/dev/null || true

  # Optional: generate/update xdg-user-dirs config if tool exists
  if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    # Run as user, but don't fail if environment/session is missing
    su -s /bin/sh -c "HOME='$HOME_DIR' xdg-user-dirs-update --force >/dev/null 2>&1 || true" "$USERNAME" || true
  fi
}

print_summary() {
  log "Summary"
  echo "User:        $USERNAME"
  echo "Home:        $(getent passwd "$USERNAME" | cut -d: -f6)"
  echo "Shell:       $(getent passwd "$USERNAME" | cut -d: -f7)"
  echo "Primary grp: $(id -gn "$USERNAME")"
  echo "Groups:      $(id -nG "$USERNAME")"
  echo "Home owner:  $(stat -c '%U:%G' "$HOME_DIR" 2>/dev/null || echo '?')"
  echo "Home perms:  $(stat -c '%a' "$HOME_DIR" 2>/dev/null || echo '?')"

  if passwd -S "$USERNAME" 2>/dev/null | grep -qE '\sL\s'; then
    echo "Password:    LOCKED (expected in default mode)"
  else
    echo "Password:    not locked"
  fi

  echo
  echo "To set password later:"
  echo "  passwd $USERNAME"
  echo
  echo "To allow sudo (if wheel group + sudoers configured):"
  echo "  EDIT /etc/sudoers or /etc/sudoers.d/* and enable wheel"
}

create_or_update_user
ensure_home_exists_and_owned
print_summary
