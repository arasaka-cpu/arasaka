#!/usr/bin/env bash
# arasaka-verify-boot.sh
# Verifies that the Unified Kernel Image (UKI) actually booted matches what was
# recorded when the slot was made primary. If the UKI on the ESP was tampered
# with or does not match the freshly-written rootfs slot, the slot is marked
# BAD so RAUC/set-primary will not trust it.
set -euo pipefail

BOOT_DIR="/boot"
STATE_DIR="/data/rauc/boot"
LOG_FILE="/var/log/arasaka-ota.log"

log() { echo "[arasaka-verify] $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }

esp_dir() {
    # The ESP mount root (fstab mounts it at /boot/efi on the Arasaka layout).
    for d in "${BOOT_DIR}/efi" /efi "${BOOT_DIR}"; do
        if [ -d "${d}/EFI/arasaka" ]; then
            echo "$d"
            return 0
        fi
    done
    echo "${BOOT_DIR}/efi"
    return 0
}

booted_bootname() {
    # Extract rauc.slot=A|B from /proc/cmdline (embedded in the UKI).
    if grep -q 'rauc\.slot=' /proc/cmdline; then
        grep -o 'rauc\.slot=[A-Za-z0-9]*' /proc/cmdline | cut -d= -f2
        return 0
    fi
    return 1
}

slot_of_bootname() {
    case "$1" in
        A) echo a ;;
        B) echo b ;;
        *) return 1 ;;
    esac
}

main() {
    local bootname slot esp
    bootname=$(booted_bootname) || { log "no rauc.slot in cmdline; skipping verify"; exit 0; }
    slot=$(slot_of_bootname "$bootname") || { log "unknown bootname $bootname"; exit 0; }
    esp=$(esp_dir)

    local uki="${esp}/EFI/arasaka/arasaka-${slot}.efi"
    local expected="${STATE_DIR}/${bootname}.uki.sha256"

    if [ ! -f "$expected" ]; then
        # First boot after a fresh install: record the current UKI hash so
        # future boots have a baseline to compare against.
        mkdir -p "$STATE_DIR"
        sha256sum "$uki" 2>/dev/null | cut -d' ' -f1 > "$expected" || true
        log "Recorded baseline UKI hash for slot $bootname"
        exit 0
    fi

    local cur
    cur=$(sha256sum "$uki" 2>/dev/null | cut -d' ' -f1 || true)

    if [ "$cur" != "$(cat "$expected")" ]; then
        log "UKI MISMATCH on slot $bootname - marking BAD"
        rauc status mark-bad "$bootname" 2>&1 | tee -a "$LOG_FILE" || true
        exit 1
    fi

    log "UKI verified for slot $bootname"
    exit 0
}

main "$@"
