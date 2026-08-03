#!/usr/bin/env bash
# arasaka-boot-succeeded.sh
# Commits a pending A/B slot swap once the new slot boots successfully.
#
# During an update, arasaka-update.sh writes swap-pending and flips
# active-slot to the new slot. On the next boot the initramfs hook
# (arasaka-ab) leaves a swap-tried marker. If this service reaches
# multi-user.target (i.e. the new slot actually booted and came up), the
# swap is committed: swap-pending + swap-tried are removed.
#
# If the new slot never gets this far, the markers survive, and the next
# boot of the initramfs hook rolls back to the previous slot automatically.
set -euo pipefail

if [ -f /boot/ab/swap-pending ]; then
    active="$(cat /boot/ab/active-slot 2>/dev/null || echo '?')"
    rm -f /boot/ab/swap-pending /boot/ab/swap-tried
    echo "[arasaka-boot] Slot swap committed; active slot is now '${active}'."
else
    echo "[arasaka-boot] No pending slot swap; nothing to commit."
fi
