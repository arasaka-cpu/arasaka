#!/usr/bin/env bash
# rauc-boot-handler.sh
# Custom RAUC bootloader backend for systemd-boot.
#
# Installed to /usr/lib/rauc/rauc-boot-handler.sh and wired into
# /etc/rauc/system.conf via [handlers] bootloader-custom-backend=.
#
# RAUC invokes this script with one of:
#   get-primary                 -> print primary bootname (A or B)
#   set-primary <bootname>      -> switch primary slot
#   get-state <bootname>        -> print "good" or "bad"
#   set-state <bootname> <state>-> mark slot good/bad
#
# Slot switching:
#   - systemd-boot picks its boot entry from loader.conf `default`.
#   - Each slot has its OWN kernel/initramfs on the shared /boot partition
#     (vmlinuz-arasaka-a / initramfs-arasaka-a.img, ...). Switching primary
#     extracts the kernel+initramfs from the freshly-written rootfs slot and
#     copies them into /boot per-slot, atomically (.tmp + rename).
#   - Kernel cmdline carries rauc.slot=A/B so RAUC can detect the booted slot.
#
# Boot state is persisted on the data partition (/data/rauc/boot) so it
# survives the slot swap. On a fresh install every slot defaults to good.
#
# The legacy /boot/ab A/B markers (active-slot / swap-pending) are kept in
# sync so the arasaka-ab initramfs hook and arasaka-boot-succeeded.service
# continue to provide boot-attempt rollback during the RAUC transition.
set -euo pipefail

BOOT_LABEL="arasaka-boot"
BOOT_DIR="/boot"
LOADER_CONF="${BOOT_DIR}/loader/loader.conf"
ENTRIES_DIR="${BOOT_DIR}/loader/entries"
AB_DIR="${BOOT_DIR}/ab"
STATE_DIR="/data/rauc/boot"
# Scratch mount for kernel extraction. The rootfs is read-only, so /mnt cannot
# be written; /data is mounted before rauc.service runs (arasaka-persist-data
# orders itself Before=rauc.service) and is always writable.
MNT="/data/rauc/new-slot"

log() { echo "[rauc-boot] $*" >&2; }
die() { echo "[rauc-boot] FATAL: $*" >&2; exit 1; }

slot_to_bootname() { # slot letter (a|b) -> bootname (A|B)
    case "$1" in
        a) echo "A" ;;
        b) echo "B" ;;
        *) die "unknown slot '$1'" ;;
    esac
}

bootname_to_slot() { # bootname (A|B) -> slot letter (a|b)
    case "$1" in
        A) echo "a" ;;
        B) echo "b" ;;
        *) die "unknown bootname '$1'" ;;
    esac
}

ensure_state() {
    mkdir -p "${STATE_DIR}"
}

read_primary() {
    # Prefer the persisted RAUC primary; fall back to the legacy marker so
    # get-primary stays consistent even before the data partition is mounted.
    if [ -f "${STATE_DIR}/primary" ]; then
        cat "${STATE_DIR}/primary"
    elif [ -f "${AB_DIR}/active-slot" ]; then
        slot_to_bootname "$(cat "${AB_DIR}/active-slot")"
    else
        echo "A"
    fi
}

read_state() {
    local bootname="$1"
    if [ -f "${STATE_DIR}/${bootname}.state" ]; then
        cat "${STATE_DIR}/${bootname}.state"
    else
        echo "good"
    fi
}

write_state() {
    local bootname="$1" state="$2"
    ensure_state
    echo "${state}" > "${STATE_DIR}/${bootname}.state"
}

sync_legacy_markers() {
    # Mirror primary into the legacy A/B markers used by the initramfs hook.
    local primary
    primary=$(read_primary)
    local primary_slot prev
    primary_slot=$(bootname_to_slot "${primary}")
    prev=$(cat "${AB_DIR}/active-slot" 2>/dev/null || echo "${primary_slot}")

    if [ ! -d "${AB_DIR}" ]; then
        mkdir -p "${AB_DIR}"
    fi
    if [ "${primary_slot}" != "${prev}" ]; then
        echo "${prev}" > "${AB_DIR}/swap-pending"
    fi
    echo "${primary_slot}" > "${AB_DIR}/active-slot"
    sync
}

copy_kernel_from_slot() {
    # Extract the kernel+initramfs from the freshly-written rootfs slot into
    # /boot using per-slot names, written atomically.
    local slot="$1" bootname="$2" dev kname imgname tmpk tmpi
    dev="/dev/disk/by-label/arasaka-slot-${slot}"
    [ -b "${dev}" ] || die "slot device ${dev} not found"

    rm -rf "${MNT}"
    mkdir -p "${MNT}"
    # Mount rw briefly: this is the freshly-installed slot being prepared for
    # its first boot, and the machine-id must be regenerated per device (the
    # image's baked id is shared by every device running the same bundle,
    # which would collide on DHCP/network identities).
    mount -o rw "${dev}" "${MNT}" || die "cannot mount ${dev} for kernel extraction"

    # Pick the highest-versioned kernel inside the new rootfs (generic naming
    # from the Arch linux package or a custom A/B build).
    kname=$(ls "${MNT}/boot"/vmlinuz* 2>/dev/null | sort -V | tail -1 | xargs basename 2>/dev/null || true)
    imgname=$(ls "${MNT}/boot"/initramfs-*.img 2>/dev/null | sort -V | tail -1 | xargs basename 2>/dev/null || true)
    [ -n "${kname}" ] || die "no kernel found in new slot ${slot}"
    [ -n "${imgname}" ] || die "no initramfs found in new slot ${slot}"

    log "extracting ${kname} / ${imgname} from slot ${slot}"

    tmpk="${BOOT_DIR}/vmlinuz-arasaka-${slot}.tmp"
    tmpi="${BOOT_DIR}/initramfs-arasaka-${slot}.img.tmp"
    cp "${MNT}/boot/${kname}" "${tmpk}"
    cp "${MNT}/boot/${imgname}" "${tmpi}"
    mv -f "${tmpk}" "${BOOT_DIR}/vmlinuz-arasaka-${slot}"
    mv -f "${tmpi}" "${BOOT_DIR}/initramfs-arasaka-${slot}.img"

    # Per-device machine-id (see above). Use the tool if present, else a
    # random 32-hex value; systemd derives all further identity from this.
    if [ -x "${MNT}/usr/lib/systemd/systemd-machine-id-setup" ] || [ -x "${MNT}/usr/bin/systemd-machine-id-setup" ]; then
        rm -f "${MNT}/etc/machine-id"
        arch-chroot "${MNT}" /usr/bin/systemd-machine-id-setup 2>/dev/null || true
    fi
    if [ ! -s "${MNT}/etc/machine-id" ]; then
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n' > "${MNT}/etc/machine-id"
        chmod 444 "${MNT}/etc/machine-id"
    fi

    umount "${MNT}" 2>/dev/null || true
    rm -rf "${MNT}"
}

set_loader_default() {
    # Atomically switch loader.conf `default` to the given entry file.
    local entry="$1"
    local tmp="${LOADER_CONF}.tmp"
    sed "s/^default .*/default ${entry}/" "${LOADER_CONF}" > "${tmp}"
    mv -f "${tmp}" "${LOADER_CONF}"
    sync
}

cmd_get_primary() {
    read_primary
    exit 0
}

cmd_set_primary() {
    local bootname="$1" slot primary prev
    slot=$(bootname_to_slot "${bootname}")
    primary=$(read_primary)
    prev=$(bootname_to_slot "${primary}")

    if [ "${slot}" = "${prev}" ]; then
        log "slot ${bootname} is already primary; no-op"
        exit 0
    fi

    # 1. Extract the kernel from the new rootfs slot into /boot.
    copy_kernel_from_slot "${slot}" "${bootname}"

    # 2. Record the freshly-extracted kernel hashes so arasaka-verify-boot
    #    can prove the kernels that actually boot match what we installed.
    ensure_state
    sha256sum "${BOOT_DIR}/vmlinuz-arasaka-${slot}" | cut -d' ' -f1 \
        > "${STATE_DIR}/${bootname}.kernel.sha256"
    sha256sum "${BOOT_DIR}/initramfs-arasaka-${slot}.img" | cut -d' ' -f1 \
        > "${STATE_DIR}/${bootname}.initrd.sha256"

    # 3. Point systemd-boot at the new slot's entry.
    set_loader_default "arasaka-${slot}.conf"

    # 4. Persist the new primary.
    echo "${bootname}" > "${STATE_DIR}/primary"

    # 5. Keep the legacy initramfs markers in sync (rollback safety).
    sync_legacy_markers

    log "primary switched to ${bootname}"
    exit 0
}

cmd_get_state() {
    local bootname="$1"
    read_state "${bootname}"
    exit 0
}

cmd_set_state() {
    local bootname="$1" state="$2"
    case "${state}" in
        good|bad) ;;
        *) die "invalid state '${state}' (expected good|bad)" ;;
    esac
    write_state "${bootname}" "${state}"
    log "slot ${bootname} state -> ${state}"
    exit 0
}

main() {
    local cmd="$1"
    case "${cmd}" in
        get-primary)        cmd_get_primary "$@" ;;
        set-primary)        cmd_set_primary "${2:-}" ;;
        get-state)          cmd_get_state "${2:-}" ;;
        set-state)          cmd_set_state "${2:-}" "${3:-}" ;;
        *) die "unknown command '${cmd}'" ;;
    esac
}

main "$@"
