#!/usr/bin/env bash
# arasaka-persist-data.sh
# Ensures the btrfs data partition is mounted at /data and binds the mutable
# system state (flatpak, snap, snapd, systemd, log, cache, home) into the
# running root. The rootfs slots are immutable, so all writable user-facing
# state lives on /data and survives OTA slot swaps.
set -euo pipefail

DATA_DEV="/dev/disk/by-label/arasaka-data"
DATA_MNT="/data"
# btrfs subvolumes on the data partition (created by install-to-disk.sh) bound
# into the running root so user state survives OTA slot swaps.
SUBVOLS=(@flatpak @snap @snapd @systemd @log @cache @home)
BINDS=(/var/lib/flatpak /var/snap /var/lib/snapd /var/lib/systemd /var/log /var/cache /home)

log() { echo "[arasaka-persist] $*"; }

mount_data() {
    if mountpoint -q "${DATA_MNT}"; then
        return 0
    fi
    if [ ! -b "${DATA_DEV}" ]; then
        log "WARNING: data partition ${DATA_DEV} not found; using volatile state"
        return 1
    fi
    mkdir -p "${DATA_MNT}"
    mount -t btrfs -o compress=zstd "${DATA_DEV}" "${DATA_MNT}" 2>/dev/null \
        || mount "${DATA_DEV}" "${DATA_MNT}"
    log "Data partition mounted at ${DATA_MNT}"
}

ensure_subvols() {
    # Ensure the @ subvolumes exist (install-to-disk creates them, but be
    # defensive on systems that were installed before snap support).
    mkdir -p "${DATA_MNT}/@flatpak" "${DATA_MNT}/@snap" "${DATA_MNT}/@snapd" \
             "${DATA_MNT}/@systemd" "${DATA_MNT}/@log" "${DATA_MNT}/@cache" "${DATA_MNT}/@home"
}

bind_state() {
    local i
    for i in "${!SUBVOLS[@]}"; do
        local sv="${SUBVOLS[$i]}" target="${BINDS[$i]}"
        mkdir -p "${DATA_MNT}/${sv}" "${target}"
        if ! mountpoint -q "${target}"; then
            mount --bind "${DATA_MNT}/${sv}" "${target}"
            log "Bound ${DATA_MNT}/${sv} -> ${target}"
        fi
    done
}

main() {
    log "Ensuring persistent state on /data..."
    if mount_data; then
        ensure_subvols
        bind_state
    fi
    log "Persistent state ready"
}

main "$@"
