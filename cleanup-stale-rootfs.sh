#!/bin/bash
# cleanup-stale-rootfs.sh - remove old ArchImmortal/immortal branding files
# from the built rootfs, in the rootfs chroot, before re-running build.sh.
set -euo pipefail

ROOTFS="$(cd "$(dirname "$0")" && pwd)/build/rootfs"

# Unmount leftover binds so arch-chroot and later mksquashfs are clean
for mp in proc sys dev run; do
    sudo umount -lf "${ROOTFS}/$mp" 2>/dev/null || true
done
sudo umount -lf "${ROOTFS}" 2>/dev/null || true

# Clean stale ArchImmortal/immortal files inside the rootfs
sudo arch-chroot "$ROOTFS" /bin/bash -c '
set -e
# old systemd units (any archimmortal-*/immortal-* under /etc/systemd/system)
find /etc/systemd/system -maxdepth 2 -name "*archimmortal*" -o -name "*immortal*" 2>/dev/null | while read -r f; do
    rm -f "$f"
done
# old enabled symlinks
find /etc/systemd/system/*.wants -maxdepth 1 -name "*archimmortal*" -o -maxdepth 1 -name "*immortal*" 2>/dev/null | while read -r f; do
    rm -f "$f"
done
# old scripts
rm -f /usr/local/bin/immortal-*.sh
# old config dir / files
rm -rf /etc/immortal
rm -f /etc/tmpfiles.d/00-immortal.conf
rm -f /etc/systemd/system.conf.d/00-immortal-env.conf
# old flatpak override content refreshed by build.sh
echo "cleanup done"
'
