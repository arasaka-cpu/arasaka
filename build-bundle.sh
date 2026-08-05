#!/usr/bin/env bash
# build-bundle.sh - Arasaka signed OTA bundle builder
#
# Builds the RAUC update bundle from the rootfs produced by build.sh:
#   1. packs the rootfs into a raw ext4 slot image (label gets fixed per-slot
#      by an in-bundle post-install hook on the device),
#   2. regenerates the initramfs inside the image so it includes the Arasaka
#      A/B hook (mkinitcpio needs a working chroot, hence bind mounts),
#   3. writes a verity-format RAUC bundle signed with the OTA signing key,
#   4. verifies the bundle against the staged CA (the same keyring the device
#      trusts).
#
# Run AFTER ./build.sh on the same host/chroot. Signing material is supplied
# via the OTA_SIGNING_KEY / OTA_SIGNING_CERT environment variables pointing at
# PEM files (CI writes them from GitHub secrets; never committed).
set -euo pipefail

NAME="arasaka"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)/build"
ROOTFS="${BUILD_DIR}/rootfs"
IMG="${BUILD_DIR}/arasaka-rootfs.ext4"
BUNDLE_DIR="${BUILD_DIR}/bundle"
IMG_MNT="${BUILD_DIR}/bundle-img"

# Sudo password handling mirrors build.sh.
if [ -n "${ARASAKA_SUDO_PASSWORD:-}" ]; then
    PASSWORD="$ARASAKA_SUDO_PASSWORD"
elif [ -f "$(dirname "$0")/build.conf" ]; then
    # shellcheck disable=SC1091
    . "$(dirname "$0")/build.conf"
    PASSWORD="${ARASAKA_SUDO_PASSWORD:-}"
else
    PASSWORD=""
fi

log() { echo "[bundle] $(date '+%H:%M:%S') $*"; }
die() { log "FATAL: $*"; exit 1; }

[ -n "$PASSWORD" ] || die "Set ARASAKA_SUDO_PASSWORD or create build.conf (see build.conf.example)"

run() { echo "$PASSWORD" | sudo -S "$@" 2>/dev/null; }
run_quiet() { echo "$PASSWORD" | sudo -S "$@" >/dev/null 2>&1; }
# Like run() but keeps stderr (for rauc where we need failure output).
run_verbose() { echo "$PASSWORD" | sudo -S "$@"; }

SIGN_KEY="${OTA_SIGNING_KEY:-}"
SIGN_CERT="${OTA_SIGNING_CERT:-}"

check() {
    [ -d "${ROOTFS}" ] || die "rootfs not found at ${ROOTFS}; run ./build.sh first"
    [ -f "${ROOTFS}/boot/vmlinuz-linux" ] || die "no kernel in rootfs (/boot/vmlinuz-linux)"
    command -v rauc >/dev/null 2>&1 || die "rauc not installed on this host"
    command -v mksquashfs >/dev/null 2>&1 || die "mksquashfs not installed (squashfs-tools)"
    [ -n "$SIGN_KEY" ] && [ -f "$SIGN_KEY" ] || die "OTA_SIGNING_KEY must point at the signing private key PEM"
    [ -n "$SIGN_CERT" ] && [ -f "$SIGN_CERT" ] || die "OTA_SIGNING_CERT must point at the signing certificate PEM"
    [ -f "$(dirname "$0")/config/rauc/ca.crt" ] || die "staged CA missing: config/rauc/ca.crt"
}

version_of_rootfs() {
    local v
    v="$(cat "${ROOTFS}/etc/arasaka/version" 2>/dev/null || true)"
    [ -n "$v" ] || die "no version in rootfs (/etc/arasaka/version)"
    case "$v" in
        *.*) echo "$v" ;;
        *)   echo "${v}.1" ;;  # ensure date.run format for monotonic comparison
    esac
}

build_slot_image() {
    log "Building ext4 slot image..."
    local used_mb size_mb
    # du must read the whole rootfs, parts of which are root-only; run it as
    # root so the image is sized from the real, complete usage.
    used_mb=$(run du -smx "${ROOTFS}" | cut -f1)
    size_mb=$(( (used_mb * 14 / 10) + 1024 ))   # +40% headroom + 1 GiB floor
    rm -f "${IMG}"
    run_quiet truncate -s "${size_mb}M" "${IMG}"
    run_quiet mkfs.ext4 -q -F -L arasaka-slot-rootfs "${IMG}"
    run_quiet mkdir -p "${IMG_MNT}"
    run mount -o loop "${IMG}" "${IMG_MNT}"
    log "Copying rootfs into image (${size_mb} MB)..."
    run_quiet rsync -aHAX --one-file-system \
        --exclude '/dev/*' --exclude '/proc/*' --exclude '/sys/*' --exclude '/run/*' \
        --exclude '/tmp/*' --exclude '/mnt/*' \
        "${ROOTFS}/" "${IMG_MNT}/"
}

rebuild_initramfs() {
    # Regenerate the initramfs inside the image so it includes the Arasaka
    # A/B hook + drop-in (the strap-time initramfs predates that config).
    log "Regenerating initramfs inside image..."
    run_quiet mkdir -p "${IMG_MNT}"/{proc,sys,dev,run}
    run mount --bind /proc "${IMG_MNT}/proc"
    run mount --bind /sys  "${IMG_MNT}/sys"
    run mount --bind /dev  "${IMG_MNT}/dev"
    run mount --bind /run  "${IMG_MNT}/run"
    if run arch-chroot "${IMG_MNT}" /usr/bin/bash -c 'mkinitcpio -P' >/dev/null 2>&1; then
        log "initramfs regenerated"
    else
        if [ -f "${IMG_MNT}/boot/initramfs-linux.img" ]; then
            log "WARNING: mkinitcpio failed inside image; keeping existing initramfs (may lack A/B hook)"
        else
            die "mkinitcpio failed and no initramfs exists in the image"
        fi
    fi
    run umount -lf "${IMG_MNT}/run" 2>/dev/null || true
    run umount -lf "${IMG_MNT}/dev" 2>/dev/null || true
    run umount -lf "${IMG_MNT}/sys" 2>/dev/null || true
    run umount -lf "${IMG_MNT}/proc" 2>/dev/null || true
}

write_bundle() {
    log "Writing bundle directory + manifest..."
    # Recreate the bundle dir as the invoking user (a previous run may have
    # left it root-owned from a sudo'ed creation). Everything below writes to
    # it as the user; only rootfs.ext4 and the rauc bundle go through sudo.
    run_quiet rm -rf "${BUNDLE_DIR}"
    mkdir -p "${BUNDLE_DIR}"

    # Per-slot post-install hook: restore the slot partition label. The bundle
    # image is written to either slot, so the label must be fixed after install
    # for the by-label device paths in system.conf (and the boot backend) to
    # keep working.
    cat > "${BUNDLE_DIR}/hook.sh" << 'HOOKEOF'
#!/bin/sh
case "$1" in
    slot-post-install)
        case "$RAUC_SLOT_NAME" in
            rootfs.0) label=arasaka-slot-a ;;
            rootfs.1) label=arasaka-slot-b ;;
            *) echo "unknown slot: $RAUC_SLOT_NAME" >&2; exit 1 ;;
        esac
        echo "relabeling $RAUC_SLOT_DEVICE -> $label"
        e2label "$RAUC_SLOT_DEVICE" "$label"
        ;;
    *)
        exit 1
        ;;
esac
exit 0
HOOKEOF
    run_quiet chmod +x "${BUNDLE_DIR}/hook.sh"

    cat > "${BUNDLE_DIR}/manifest.raucm" << MANIFESTEOF
[update]
compatible=arasaka-x86_64
version=${VERSION}

[bundle]
format=verity

[hooks]
filename=hook.sh

[image.rootfs]
filename=rootfs.ext4
hooks=post-install
MANIFESTEOF

    # The image goes into the bundle directory for rauc bundle to pick up.
    run_quiet cp "${IMG}" "${BUNDLE_DIR}/rootfs.ext4"
}

build_and_verify_bundle() {
    local out
    out="${BUILD_DIR}/arasaka-${VERSION}.raucb"
    log "Creating signed RAUC bundle: ${out}"
    run_verbose rauc bundle \
        --cert="${SIGN_CERT}" \
        --key="${SIGN_KEY}" \
        --signing-keyring="$(dirname "$0")/config/rauc/ca.crt" \
        "${BUNDLE_DIR}" "${out}"
    log "Verifying bundle against staged CA..."
    run_verbose rauc info --keyring="$(dirname "$0")/config/rauc/ca.crt" "${out}"
    log "Bundle: ${out}"
    echo "${out}" > "${BUILD_DIR}/bundle-path"
}

main() {
    log "=== Arasaka OTA Bundle Builder ==="
    check
    VERSION="$(version_of_rootfs)"
    log "Version: ${VERSION}"

    build_slot_image
    rebuild_initramfs
    run_quiet umount -lf "${IMG_MNT}" 2>/dev/null || true
    run_quiet rm -rf "${IMG_MNT}"

    write_bundle
    build_and_verify_bundle

    log "=== Bundle build complete ==="
    log "Bundle: ${BUILD_DIR}/arasaka-${VERSION}.raucb"
    log "Next: upload to B2 updates bucket as update/stable/arasaka-${VERSION}.raucb"
    log "      and publish update/stable/latest.json (+ .sig) pointing at it"
}

main "$@"
