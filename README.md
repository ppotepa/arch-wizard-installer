# Archforge

Two-stage Arch Linux setup for a KDE desktop:

- Stage 1: base install + KDE + GPU stack + services
- Stage 2: optional desktop tools and apps

## Structure

- `bin/install.sh` - stage 1 wizard (partitions, locale, timezone, base packages)
- `bin/wizard.sh` - modular wizard (base + optional modules like KDE/dev/gaming)
- `bin/tools.sh` - stage 2 tools bundle (apps, office, comms, remoting)
- `bin/add-user.sh` - create/repair a user
- `bin/user-groups.sh` - add common desktop groups
- `bin/patch.sh` - remediation for login/driver issues
- `bin/kde-repair.sh` - KDE login loop repair
- `config/defaults.conf` - defaults for wizard (locale/timezone)

## Quick start

1. Base install:
   `sudo bin/install.sh`

2. Tools/apps:
   `sudo bin/tools.sh <username>`

3. Modular wizard (base + optional modules):
   `sudo bin/wizard.sh`

## Notes

- Stage 1 expects `/` and `/boot` partitions to be prepared and mounted.
- The wizard will warn and stop if they are not ready.
- Use `fdisk`, `cfdisk`, or `gparted` if you need to prepare partitions.

## VM testing (QEMU)

- All VM data is stored in `vm/`.
- Script auto-installs dependencies, auto-downloads latest Arch ISO (if missing), and starts QEMU.
- Project directory is shared to guest as 9p `toolset` and should be mounted in guest at `/mnt/toolset`.
- Downloaded ISO is patched to include helper script on boot media: `/run/archiso/bootmnt/root/mount-toolset.sh`.

Run GUI VM:

`bin/test-vm.sh`

Run web mode (noVNC/websockify):

`bin/test-vm.sh --web`

Clean everything in `vm/`:

`bin/test-vm.sh --clean`

Inside guest mount project:

`bash /run/archiso/bootmnt/root/mount-toolset.sh`
