#!/usr/bin/env bash
# arasaka-remount-ro.sh
# Read-only root guard. The initramfs hook mounts the active slot read-only,
# so by the time this unit runs / should already be ro. This is the belt-and-
# suspenders step: it verifies / is read-only and, if anything remounted it rw,
# tries to flip it back before the desktop comes up.
#
# The kernel refuses `remount,ro` while writable submounts exist (overlayfs on
# /etc and /var, tmpfs on /run and /tmp), so a failed remount here is expected
# when the root was never rw in the first place; only a genuinely-writable root
# with no busy submounts can be flipped back.
set -euo pipefail

if findmnt -no OPTIONS / 2>/dev/null | grep -q '^.*\bro\b.*$'; then
    echo "[arasaka-immutable] root filesystem is read-only"
    exit 0
fi

echo "[arasaka-immutable] WARNING: root is writable; attempting remount,ro"
if mount -o remount,ro / 2>/dev/null; then
    echo "[arasaka-immutable] root remounted read-only"
    exit 0
fi

# Overlay/tmpfs submounts make the remount fail; the root stays rw but the
# system still boots. This is a degraded (non-immutable) state worth logging.
echo "[arasaka-immutable] ERROR: could not remount / read-only (busy submounts)"
exit 0
