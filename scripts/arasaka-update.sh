#!/usr/bin/env bash
# arasaka-update.sh
# Core update engine: creates a temp chroot, updates packages, then writes the
# updated rootfs into the INACTIVE raw ext4 slot partition and marks a
# rollback-protected swap. No repo needed - updates from live Arch mirrors.
#
# Slot model:
#   - slot-a / slot-b are two raw ext4 root partitions (by label).
#   - The kernel/initramfs boots whichever slot active-slot points at; the
#     arasaka-ab initramfs hook performs the selection.
#   - An update writes the new rootfs into the inactive slot, flips
#     active-slot to it, and records the previous slot in swap-pending.
#   - On the next boot the system boots the new slot with a swap-tried marker.
#     arasaka-boot-succeeded.service removes the markers once the system
#     reaches multi-user.target -> the swap is committed. If the new slot
#     never comes up, the markers survive and the initramfs hook rolls back
#     to the previous slot on the following boot.
set -euo pipefail

SLOT_FILE="/boot/ab/active-slot"
# The running rootfs is read-only (mount ro in the initramfs hook), so /var/tmp
# cannot hold the update chroot or the inactive-slot mount point. Both live on
# the writable btrfs data partition instead.
CHROOT_DIR="/data/update/chroot"
INACTIVE_SLOT_DIR="/data/update/inactive"
LOG_FILE="/var/log/arasaka-update.log"

log() { echo "[arasaka-update] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
die() { log "FATAL: $*"; exit 1; }

detect_active_slot() {
    if [ -f "$SLOT_FILE" ]; then
        cat "$SLOT_FILE"
    else
        echo "a"
    fi
}

get_inactive_slot() {
    local active
    active=$(detect_active_slot)
    if [ "$active" = "a" ]; then
        echo "b"
    else
        echo "a"
    fi
}

resolve_slot_partition() {
    # $1 = slot letter; prints the device node for that slot's partition.
    local slot="$1" dev
    dev=$(blkid -L "arasaka-slot-${slot}" 2>/dev/null || true)
    if [ -n "$dev" ] && [ -b "$dev" ]; then
        echo "$dev"
        return 0
    fi
    dev="/dev/disk/by-label/arasaka-slot-${slot}"
    if [ -b "$dev" ]; then
        echo "$dev"
        return 0
    fi
    return 1
}

check_boot_mounted() {
    if [ ! -d /boot/ab ]; then
        die "/boot/ab is not available (is /boot mounted?)"
    fi
    if [ ! -w /boot/ab ]; then
        die "/boot/ab is not writable"
    fi
}

cleanup() {
    log "Cleaning up temporary chroot..."
    for mp in proc sys dev run; do
        if mountpoint -q "${CHROOT_DIR}/${mp}" 2>/dev/null; then
            umount -lf "${CHROOT_DIR}/${mp}" 2>/dev/null || true
        fi
    done
    if mountpoint -q "${INACTIVE_SLOT_DIR}" 2>/dev/null; then
        umount -lf "${INACTIVE_SLOT_DIR}" 2>/dev/null || true
    fi
    rm -rf "${CHROOT_DIR}"
    rm -rf "${INACTIVE_SLOT_DIR}"
    rm -f /var/lock/arasaka-update.lock
}
trap cleanup EXIT

# The update scratch space lives on /data (the rootfs is read-only). Make sure
# /data is mounted and writable before anything else.
ensure_data_mounted() {
    if ! mountpoint -q /data; then
        local dev
        dev=$(blkid -L arasaka-data 2>/dev/null || true)
        if [ -z "$dev" ] || [ ! -b "$dev" ]; then
            dev="/dev/disk/by-label/arasaka-data"
        fi
        [ -b "$dev" ] || die "/data not mounted and no data partition found; cannot update"
        mkdir -p /data
        mount -t btrfs -o compress=zstd "$dev" /data 2>/dev/null || mount "$dev" /data
    fi
    [ -w /data ] || die "/data is not writable; cannot update"
}

create_update_chroot() {
    log "Creating temporary update chroot..."
    ensure_data_mounted
    rm -rf "${CHROOT_DIR}"
    mkdir -p "${CHROOT_DIR}"

    # Copy current rootfs into chroot (skip mutable/virtual dirs).
    # rsync is used because it supports --exclude reliably on any coreutils
    # implementation (uutils cp 0.9 does not implement --exclude).
    #
    # The running root is mounted ro with an overlayfs over /var and bind
    # mounts over /home and the /etc runtime state (all separate filesystems).
    # --one-file-system therefore skips them; each overlay/bind gets its own
    # rsync pass below so the update chroot carries the current configuration
    # (machine-id, hostname, resolv, fstab, wifi/printers) instead of empty or
    # stale state.
    log "Copying current rootfs to chroot..."
    rsync -aHAX --one-file-system \
        --exclude=/proc \
        --exclude=/sys \
        --exclude=/dev \
        --exclude=/run \
        --exclude=/tmp \
        --exclude=/var/tmp \
        --exclude=/var/cache/pacman \
        --exclude=/boot \
        --exclude=/data \
        --exclude=/var/lib/flatpak \
        --exclude=/var/snap \
        --exclude=/var/lib/snapd \
        --exclude=/var/lib/systemd \
        --exclude=/var/log \
        --exclude=/var/cache \
        --exclude=/home \
        / "${CHROOT_DIR}/" 2>/dev/null || \
    cp -a --one-file-system \
        --exclude=/proc \
        --exclude=/sys \
        --exclude=/dev \
        --exclude=/run \
        --exclude=/tmp \
        --exclude=/var/tmp \
        --exclude=/var/cache/pacman \
        --exclude=/boot \
        --exclude=/data \
        --exclude=/var/lib/flatpak \
        / "${CHROOT_DIR}/" 2>/dev/null || true

    # Re-attach the overlay state (they are distinct filesystems, so the
    # one-file-system pass above created empty mountpoint dirs for them).
    log "Copying /var overlay and /etc runtime state into chroot..."
    if [ -d /var ]; then
        rsync -aHAX --delete \
            --exclude=/var/lib/flatpak \
            --exclude=/var/snap \
            --exclude=/var/lib/snapd \
            --exclude=/var/lib/systemd \
            --exclude=/var/log \
            --exclude=/var/cache \
            --exclude=/var/tmp \
            /var/ "${CHROOT_DIR}/var/" 2>/dev/null || true
    fi

    # /etc is part of the ro slot image, so the main pass already copied it.
    # The only parts of /etc that change at runtime are bound from /data
    # (NetworkManager connections, CUPS printers) - carry that state into the
    # chroot so the new slot boots with the current wifi/printers.
    for d in NetworkManager cups; do
        if [ -d "/etc/${d}" ]; then
            mkdir -p "${CHROOT_DIR}/etc/${d}"
            rsync -aHAX "/etc/${d}/" "${CHROOT_DIR}/etc/${d}/" 2>/dev/null || true
        fi
    done

    # Mount virtual filesystems (mount points are excluded from the copy
    # above, so create them first).
    mkdir -p "${CHROOT_DIR}/proc" "${CHROOT_DIR}/sys" \
             "${CHROOT_DIR}/dev" "${CHROOT_DIR}/run"
    mount --bind /proc "${CHROOT_DIR}/proc"
    mount --bind /sys "${CHROOT_DIR}/sys"
    mount --bind /dev "${CHROOT_DIR}/dev"
    mount --bind /run "${CHROOT_DIR}/run"

    log "Chroot created at ${CHROOT_DIR}"
}

# Run a command inside the update chroot. arch-chroot is preferred when
# available (it also sets up /etc/resolv.conf for network access); plain
# chroot is fine because the script bind-mounts the virtual filesystems
# itself.
run_in_chroot() {
    if command -v arch-chroot >/dev/null 2>&1; then
        arch-chroot "${CHROOT_DIR}" "$@"
    else
        chroot "${CHROOT_DIR}" "$@"
    fi
}

update_packages_in_chroot() {
    log "Updating packages inside chroot..."

    # First update keyring
    run_in_chroot /bin/bash -c '
        pacman -Syy --noconfirm 2>&1 || true
        pacman -S --noconfirm archlinux-keyring 2>&1 || true
    ' 2>&1 | tee -a "$LOG_FILE"

    # Full system upgrade
    run_in_chroot /bin/bash -c '
        pacman -Syu --noconfirm 2>&1
    ' 2>&1 | tee -a "$LOG_FILE"

    # Update flatpak runtimes and apps (system-wide; user runtimes are on the
    # data partition and are shared, so they are updated on the live system).
    run_in_chroot /bin/bash -c '
        flatpak update --system --noninteractive 2>&1 || true
    ' 2>&1 | tee -a "$LOG_FILE"

    log "Package update complete"
}

write_inactive_slot() {
    log "Writing updated rootfs into inactive slot..."

    local inactive
    inactive=$(get_inactive_slot)
    local dev
    dev=$(resolve_slot_partition "$inactive") || die "Cannot resolve inactive slot '${inactive}' partition"

    # Clean mutable/cache data before imaging. openssh comes back on every
    # pacman -Syu (it is a dependency of gcr-4/gvfs), so strip it again here -
    # the shipped system stays ssh-free by default.
    run_in_chroot /bin/bash -c '
        pacman -Rdd --noconfirm openssh 2>&1 || true
        rm -rf /var/cache/pacman/pkg/*
        rm -rf /tmp/* /var/tmp/*
        truncate -s 0 /var/log/* 2>/dev/null || true
    '

    # Record the update so the running system can identify which slot+generation
    # it booted (used for verification and diagnostics).
    mkdir -p "${CHROOT_DIR}/etc/arasaka"
    printf 'slot=%s\ntime=%s\n' \
        "$inactive" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" \
        > "${CHROOT_DIR}/etc/arasaka/update-generation"

    # Unmount the chroot binds so rsync does not recurse into pseudo-filesystems.
    for mp in proc sys dev run; do
        umount -lf "${CHROOT_DIR}/${mp}" 2>/dev/null || true
    done

    rm -rf "${INACTIVE_SLOT_DIR}"
    mkdir -p "${INACTIVE_SLOT_DIR}"
    mount -o rw "$dev" "${INACTIVE_SLOT_DIR}"

    # Wipe stale content on the inactive slot, then rsync the fresh rootfs in.
    rsync -aHAX --delete \
        --exclude=/proc \
        --exclude=/sys \
        --exclude=/dev \
        --exclude=/run \
        --exclude=/tmp \
        --exclude=/var/tmp \
        --exclude=/var/cache/pacman \
        --exclude=/var/lib/flatpak \
        --exclude=/boot \
        --exclude=/data \
        --exclude=/mnt \
        --exclude=/media \
        "${CHROOT_DIR}/" "${INACTIVE_SLOT_DIR}/"

    # Ensure fstab mountpoints exist on the new root.
    mkdir -p "${INACTIVE_SLOT_DIR}/boot/efi" \
             "${INACTIVE_SLOT_DIR}/data" \
             "${INACTIVE_SLOT_DIR}/etc/arasaka"

    sync
    umount "${INACTIVE_SLOT_DIR}"
    rm -rf "${INACTIVE_SLOT_DIR}"

    log "Inactive slot '${inactive}' populated (${dev})"
}

mark_swap_pending() {
    log "Marking slot swap as pending (rollback-protected)..."

    local active inactive
    active=$(detect_active_slot)
    inactive=$(get_inactive_slot)

    # Record the current slot as the rollback target BEFORE flipping
    # active-slot, so an interrupted swap is never lost.
    echo "${active}" > /boot/ab/swap-pending
    echo "${inactive}" > /boot/ab/active-slot
    sync

    log "Swap pending: active-slot=${inactive}, rollback-slot=${active}"
    log "Update complete. Reboot to apply (new slot will be committed on success)."
}

main() {
    log "=========================================="
    log "Arasaka Update Engine"
    log "=========================================="

    # Update mode: "ota" (default, signed RAUC bundles from the B2 updates
    # bucket) or "mirror" (legacy in-place chroot + slot write from Arch
    # mirrors). OTA is the primary channel; mirror remains as a manual
    # fallback when no OTA config/keys are present.
    local mode="${MODE:-ota}"
    if [ "$mode" = "ota" ]; then
        if [ -x /usr/local/bin/arasaka-ota-update.sh ] \
           && [ -f /etc/arasaka/ota.conf ] \
           && command -v rauc >/dev/null 2>&1; then
            exec /usr/local/bin/arasaka-ota-update.sh
        fi
        log "OTA mode requested but rauc/OTA config unavailable - falling back to mirror mode"
        mode="mirror"
    fi
    if [ "$mode" != "mirror" ]; then
        die "Unknown update mode '${mode}' (expected ota|mirror)"
    fi

    if [ -f /var/lock/arasaka-update.lock ]; then
        local old_pid
        old_pid=$(cat /var/lock/arasaka-update.lock 2>/dev/null || echo "")
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            die "Another update is running (PID: ${old_pid})"
        fi
        log "Stale lock found, removing..."
        rm -f /var/lock/arasaka-update.lock
    fi

    echo $$ > /var/lock/arasaka-update.lock
    check_boot_mounted

    create_update_chroot

    if [ "${SKIP_PACKAGES:-0}" = "1" ]; then
        log "SKIP_PACKAGES=1 - skipping package updates (chroot snapshot only)"
    else
        update_packages_in_chroot
    fi

    write_inactive_slot
    mark_swap_pending

    log "=========================================="
    log "Update finished successfully!"
    log "=========================================="
}

main "$@"
