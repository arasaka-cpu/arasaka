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
#   - Each slot has its OWN Unified Kernel Image on the ESP
#     (/boot/efi/EFI/arasaka/arasaka-<slot>.efi). Switching primary extracts the
#     kernel+initramfs from the freshly-written rootfs slot, builds a UKI with
#     ukify, signs it with sbctl using the db key persisted on /data, and
#     installs it atomically (.tmp + rename).
#   - Kernel cmdline carries rauc.slot=A/B so RAUC can detect the booted slot.
#
# Slots are RAW squashfs+dm-verity images (no filesystem, no label), so they
# are addressed by GPT partition label and the kernel/initramfs are extracted
# with unsquashfs (a squashfs mount cannot be written and relabeling is
# meaningless on a raw container).
#
# Boot state is persisted on the data partition (/data/rauc/boot) so it
# survives the slot swap. On a fresh install every slot defaults to good.
#
# The machine-id is per-device and lives on /boot (/boot/ab/machine-id, bound
# into /etc/machine-id by the initramfs hook) - the squashfs slots are
# read-only, so it can never be regenerated inside a slot.
#
# The legacy /boot/ab A/B markers (active-slot / swap-pending) are kept in
# sync so the arasaka-ab initramfs hook and arasaka-boot-succeeded.service
# continue to provide boot-attempt rollback during the RAUC transition.
set -euo pipefail

BOOT_LABEL="arasaka-boot"
BOOT_DIR="/boot"
# The ESP holds the UKIs + loader entries. /boot/efi is the fstab mount for the
# ESP on the Arasaka layout; /efi and /boot (when /boot is itself the ESP) are
# fallbacks for hand-rolled layouts.
EFI_DIR="${BOOT_DIR}/efi"
[ -d "${EFI_DIR}/EFI" ] || EFI_DIR="/efi"
[ -d "${EFI_DIR}/EFI" ] || EFI_DIR="${BOOT_DIR}"
ESP_LOADER_DIR="${EFI_DIR}/loader"
UKI_DIR="${EFI_DIR}/EFI/arasaka"
LOADER_CONF="${BOOT_DIR}/loader/loader.conf"
ENTRIES_DIR="${ESP_LOADER_DIR}/entries"
AB_DIR="${BOOT_DIR}/ab"
STATE_DIR="/data/rauc/boot"
# Scratch dir for kernel extraction. /data is mounted before rauc.service runs
# (arasaka-persist-data orders itself Before=rauc.service) and is writable.
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

slot_device() { # slot letter (a|b) -> block device (partlabel first)
    local slot="$1"
    if [ -b "/dev/disk/by-partlabel/arasaka-slot-${slot}" ]; then
        echo "/dev/disk/by-partlabel/arasaka-slot-${slot}"
    elif [ -b "/dev/disk/by-label/arasaka-slot-${slot}" ]; then
        echo "/dev/disk/by-label/arasaka-slot-${slot}"
    else
        return 1
    fi
}

build_uki_from_slot() {
    # Extract the kernel+initramfs from the freshly-written rootfs slot, build
    # a UKI for it, and install it on the ESP at
    # /EFI/arasaka/arasaka-<slot>.efi (signed, atomically). The slot is a raw
    # squashfs image (no filesystem to mount), so it is read with unsquashfs.
    local slot="$1" bootname="$2" dev kname imgname tmpuki signed uki cmdline
    dev=$(slot_device "${slot}") || die "slot device for '${slot}' not found"
    [ -b "${dev}" ] || die "slot device ${dev} not found"

    rm -rf "${MNT}"
    mkdir -p "${MNT}"

    # Pick the highest-versioned kernel inside the new rootfs (generic naming
    # from the Arch linux package or a custom A/B build).
    kname=$(unsquashfs -ll "${dev}" 2>/dev/null \
        | awk '/\/boot\/vmlinuz/ { n=$NF; sub(/^squashfs-root\//, "", n); print n }' \
        | sort -V | tail -1 || true)
    imgname=$(unsquashfs -ll "${dev}" 2>/dev/null \
        | awk '/\/boot\/initramfs/ { n=$NF; sub(/^squashfs-root\//, "", n); print n }' \
        | sort -V | tail -1 || true)
    [ -n "${kname}" ] || die "no kernel found in new slot ${slot}"
    [ -n "${imgname}" ] || die "no initramfs found in new slot ${slot}"

    log "extracting ${kname} / ${imgname} from slot ${slot}"
    unsquashfs -quiet -no-progress -n -f -d "${MNT}" "${dev}" \
        "boot/${kname}" "boot/${imgname}" || die "cannot extract kernel from slot ${slot}"

    cmdline="root=PARTLABEL=arasaka-slot-${slot} ro rauc.slot=${bootname}"
    tmpuki="${UKI_DIR}/arasaka-${slot}.efi.tmp"
    uki="${UKI_DIR}/arasaka-${slot}.efi"
    mkdir -p "${UKI_DIR}"
    if command -v ukify >/dev/null 2>&1; then
        UKIFY=$(command -v ukify)
    elif [ -x /usr/lib/systemd/ukify ]; then
        UKIFY=/usr/lib/systemd/ukify
    else
        die "ukify not found (is systemd-ukify installed?)"
    fi
    "${UKIFY}" build \
        --linux="${MNT}/boot/${kname}" \
        --initrd="${MNT}/boot/${imgname}" \
        --cmdline="${cmdline}" \
        --os-release="${MNT}/etc/os-release" \
        --output="${tmpuki}" || die "ukify build failed for slot ${slot}"

    # Sign with the persisted db key if present (bound by persist-data); an
    # unsigned UKI is still functional, just not Secure Boot enforced.
    if [ -f /usr/share/secureboot/keys/db/db.key ] || [ -f /etc/secureboot/keys/db/db.key ]; then
        signed="${tmpuki}.signed"
        if sbctl sign --output "${signed}" "${tmpuki}" 2>/dev/null; then
            mv -f "${signed}" "${uki}"
            log "signed UKI installed for slot ${slot}"
        else
            log "WARNING: sbctl sign failed for slot ${slot}; installing unsigned UKI"
            mv -f "${tmpuki}" "${uki}"
        fi
    else
        mv -f "${tmpuki}" "${uki}"
    fi

    # Write the loader entry (UKI type) on the ESP.
    mkdir -p "${ENTRIES_DIR}"
    cat > "${ENTRIES_DIR}/arasaka-${slot}.conf" << EOEOF
title   Arasaka (Slot ${bootname})
efi     /EFI/arasaka/arasaka-${slot}.efi
EOEOF

    # Ensure a per-device machine-id exists on /boot (the initramfs binds it
    # over the slot's baked /etc/machine-id). The bundle's post-install hook
    # normally creates it; be defensive for systems installed before this
    # landed. Never overwrite an existing id (systemd identity must be stable).
    if [ ! -s "${AB_DIR}/machine-id" ]; then
        mkdir -p "${AB_DIR}"
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n' > "${AB_DIR}/machine-id" 2>/dev/null || true
        chmod 444 "${AB_DIR}/machine-id" 2>/dev/null || true
    fi

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

    # 1. Extract the kernel from the new rootfs slot and install a signed UKI
    #    for it on the ESP.
    build_uki_from_slot "${slot}" "${bootname}"

    # 2. Record the freshly-built UKI hash so arasaka-verify-boot can prove the
    #    UKI that actually boots matches what we installed.
    ensure_state
    sha256sum "${UKI_DIR}/arasaka-${slot}.efi" | cut -d' ' -f1 \
        > "${STATE_DIR}/${bootname}.uki.sha256"

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
