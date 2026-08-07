#!/usr/bin/env bash
# arasaka-verify-boot.sh
# Verifies that the kernel/initramfs actually booted matches what was recorded
# when the slot was made primary. If the kernel files on /boot were tampered
# with or do not match the freshly-written rootfs slot, the slot is marked BAD
# so RAUC/set-primary will not trust it.
set -euo pipefail

BOOT_DIR="/boot"
STATE_DIR="/data/rauc/boot"
LOG_FILE="/var/log/arasaka-ota.log"

log() { echo "[arasaka-verify] $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }

booted_bootname() {
    # Extract rauc.slot=A|B from /proc/cmdline (written by the loader entries).
    for p in /proc/cmdline; do
        if grep -q 'rauc\.slot=' "$p"; then
            grep -o 'rauc\.slot=[A-Za-z0-9]*' "$p" | cut -d= -f2
            return 0
        fi
    done
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
    local bootname slot
    bootname=$(booted_bootname) || { log "no rauc.slot in cmdline; skipping verify"; exit 0; }
    slot=$(slot_of_bootname "$bootname") || { log "unknown bootname $bootname"; exit 0; }

    local expected_kernel expected_initrd
    expected_kernel="${STATE_DIR}/${bootname}.kernel.sha256"
    expected_initrd="${STATE_DIR}/${bootname}.initrd.sha256"

    if [ ! -f "$expected_kernel" ]; then
        # First boot after a fresh install: record the current kernel hashes
        # so future boots have a baseline to compare against.
        mkdir -p "$STATE_DIR"
        sha256sum "${BOOT_DIR}/vmlinuz-arasaka-${slot}" 2>/dev/null | cut -d' ' -f1 > "$expected_kernel" || true
        sha256sum "${BOOT_DIR}/initramfs-arasaka-${slot}.img" 2>/dev/null | cut -d' ' -f1 > "$expected_initrd" || true
        log "Recorded baseline kernel hashes for slot $bootname"
        exit 0
    fi

    local cur_kernel cur_initrd
    cur_kernel=$(sha256sum "${BOOT_DIR}/vmlinuz-arasaka-${slot}" 2>/dev/null | cut -d' ' -f1 || true)
    cur_initrd=$(sha256sum "${BOOT_DIR}/initramfs-arasaka-${slot}.img" 2>/dev/null | cut -d' ' -f1 || true)

    if [ "$cur_kernel" != "$(cat "$expected_kernel")" ] || [ "$cur_initrd" != "$(cat "$expected_initrd")" ]; then
        log "KERNEL MISMATCH on slot $bootname - marking BAD"
        rauc status mark-bad "$bootname" 2>&1 | tee -a "$LOG_FILE" || true
        exit 1
    fi

    log "Kernel verified for slot $bootname"
    exit 0
}

main "$@"
