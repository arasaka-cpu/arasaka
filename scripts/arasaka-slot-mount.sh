#!/usr/bin/env bash
# arasaka-slot-mount.sh
# Detects the active A/B slot and mounts the squashfs root.
# Part of systemd boot sequence.
set -euo pipefail

SLOT_FILE="/boot/ab/active-slot"
ROOTFS_IMG="/boot/ab/arasaka-rootfs.sfs"
MOUNT_TARGET="/sysroot"

log() { echo "[arasaka-slot] $*"; }

detect_slot() {
    if [ -f "$SLOT_FILE" ]; then
        cat "$SLOT_FILE"
    else
        echo "a"
        echo "a" > "$SLOT_FILE"
    fi
}

mount_root() {
    local slot
    slot=$(detect_slot)
    log "Active slot: ${slot}"

    if [ ! -f "$ROOTFS_IMG" ]; then
        log "WARNING: No rootfs image found at ${ROOTFS_IMG}"
        log "Attempting to use raw partition fallback..."
        return 0
    fi

    # Mount squashfs read-only as the new root
    mkdir -p "${MOUNT_TARGET}"
    mount -t squashfs -o ro,loop "${ROOTFS_IMG}" "${MOUNT_TARGET}"
    log "Rootfs mounted at ${MOUNT_TARGET}"

    # Create bind mounts for mutable directories
    mkdir -p "${MOUNT_TARGET}/var"
    mkdir -p "${MOUNT_TARGET}/tmp"
    mkdir -p "${MOUNT_TARGET}/run"
    mkdir -p "${MOUNT_TARGET}/etc/arasaka"

    # Persist slot info
    echo "${slot}" > "${MOUNT_TARGET}/etc/arasaka/active-slot"
}

mount_data_partition() {
    # Mount the data partition for /var, /home, etc.
    local data_dev="/dev/disk/by-label/arasaka-data"

    if [ -b "$data_dev" ]; then
        log "Mounting data partition..."
        mkdir -p /run/arasaka-data
        mount -t btrfs -o compress=zstd "$data_dev" /run/arasaka-data

        # Bind mount mutable data into the new root
        if [ -d "${MOUNT_TARGET}" ]; then
            mkdir -p "${MOUNT_TARGET}/var/lib/flatpak"
            mkdir -p "${MOUNT_TARGET}/var/lib/systemd"
            mkdir -p "${MOUNT_TARGET}/var/log"
            mkdir -p "${MOUNT_TARGET}/var/cache"
            mkdir -p "${MOUNT_TARGET}/home"

            mount --bind /run/arasaka-data/flatpak "${MOUNT_TARGET}/var/lib/flatpak"
            mount --bind /run/arasaka-data/systemd "${MOUNT_TARGET}/var/lib/systemd"
            mount --bind /run/arasaka-data/log "${MOUNT_TARGET}/var/log"
            mount --bind /run/arasaka-data/cache "${MOUNT_TARGET}/var/cache"
            mount --bind /run/arasaka-data/home "${MOUNT_TARGET}/home"
        fi

        log "Data partition mounted"
    else
        log "No data partition found, using tmpfs overlays"
        # Use tmpfs as fallback
        mount -t tmpfs tmpfs "${MOUNT_TARGET}/var/lib/flatpak"
        mount -t tmpfs tmpfs "${MOUNT_TARGET}/var/log"
        mount -t tmpfs tmpfs "${MOUNT_TARGET}/var/cache"
        mount -t tmpfs tmpfs "${MOUNT_TARGET}/home"
    fi
}

main() {
    log "=== Arasaka Slot Mount ==="
    if [ ! -f "$ROOTFS_IMG" ]; then
        log "No A/B rootfs image yet (raw-slot install); nothing to mount."
        return 0
    fi
    mount_root
    mount_data_partition
    log "=== Mount complete ==="
}

main "$@"
