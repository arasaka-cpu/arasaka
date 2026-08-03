#!/usr/bin/env bash
# arasaka-reboot-after-update.sh
# Reboots the system after a successful update, triggered by systemd timer.
set -euo pipefail

SLOT_FILE="/boot/ab/active-slot"
UPDATE_LOG="/var/log/arasaka-update.log"

log() { echo "[arasaka-reboot] $*"; }

# Only reboot if an update actually happened recently
if [ -f "$UPDATE_LOG" ]; then
    last_update=$(stat -c %Y "$UPDATE_LOG" 2>/dev/null || echo "0")
    now=$(date +%s)
    age=$(( now - last_update ))

    # If last update was within the last 2 hours, reboot
    if [ "$age" -lt 7200 ]; then
        log "Update detected ${age}s ago. Rebooting to apply..."
        systemctl reboot
    else
        log "No recent update (last update was ${age}s ago). Skipping reboot."
    fi
else
    log "No update log found. Skipping reboot."
fi
