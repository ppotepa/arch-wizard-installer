#!/usr/bin/env bash
# setup-kde-user-groups.sh
# Arch Linux / KDE Plasma helper for user (provide explicitly or via sudo)
# Usage:
#   sudo bash user-groups.sh <username>

set -euo pipefail

USERNAME="${1:-}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (use sudo)." >&2
  exit 1
fi

if [[ -z "$USERNAME" ]]; then
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    USERNAME="$SUDO_USER"
  fi
fi

if [[ -z "$USERNAME" ]]; then
  echo "Username is required (or run via sudo so SUDO_USER is set)." >&2
  exit 1
fi

if ! id "$USERNAME" &>/dev/null; then
  echo "User '$USERNAME' does not exist."
  echo "Create it first, e.g.:"
  echo "  useradd -m -s /bin/bash $USERNAME"
  echo "  passwd $USERNAME"
  exit 1
fi

# For KDE/Plasma on modern Arch (with systemd-logind), there are usually NO strictly required
# extra groups just to log in. These are common/recommended desktop groups.
# We add only groups that exist on the system.
CANDIDATE_GROUPS=(
  wheel        # sudo/admin (optional, but common)
  audio        # audio device access (often ACLs handle this, but harmless if present)
  video        # display/video devices (often ACLs handle this)
  input        # input devices (often ACLs handle this)
  render       # GPU render node access (Wayland/OpenGL/Vulkan related on some setups)
  storage      # removable storage access (legacy/common)
  optical      # optical drives (optional)
  lp           # printers (optional)
  scanner      # scanners (optional)
  uucp         # serial devices (optional)
  network      # legacy networking group (optional; NM usually uses polkit instead)
)

EXISTING_GROUPS=()
SKIPPED_GROUPS=()

for g in "${CANDIDATE_GROUPS[@]}"; do
  if getent group "$g" >/dev/null; then
    EXISTING_GROUPS+=("$g")
  else
    SKIPPED_GROUPS+=("$g")
  fi
done

if ((${#EXISTING_GROUPS[@]} > 0)); then
  GROUPS_CSV="$(IFS=,; echo "${EXISTING_GROUPS[*]}")"
  usermod -aG "$GROUPS_CSV" "$USERNAME"
  echo "Added '$USERNAME' to groups: $GROUPS_CSV"
else
  echo "No candidate groups exist on this system. Nothing to add."
fi

# Nice-to-have checks for login issues unrelated to groups:
HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
SHELL_PATH="$(getent passwd "$USERNAME" | cut -d: -f7)"

echo
echo "=== Quick checks ==="
echo "User:      $USERNAME"
echo "Home:      $HOME_DIR"
echo "Shell:     $SHELL_PATH"
echo "Groups:    $(id -nG "$USERNAME")"

if [[ -d "$HOME_DIR" ]]; then
  OWNER="$(stat -c '%U:%G' "$HOME_DIR")"
  PERMS="$(stat -c '%a' "$HOME_DIR")"
  echo "Home owner:$OWNER"
  echo "Home perms:$PERMS"
else
  echo "WARNING: Home directory does not exist: $HOME_DIR"
fi

if passwd -S "$USERNAME" 2>/dev/null | grep -qE '\sL\s'; then
  echo "WARNING: Account appears locked. Unlock with: passwd -u $USERNAME"
fi

echo
echo "Done."
