#!/usr/bin/env bash
# build-bundle.sh - Arasaka signed OTA bundle builder
#
# Builds the RAUC update bundle from the rootfs produced by build.sh:
#   1. makes a hardened copy of the rootfs (same locked-down shape a fresh
#      install gets: no sudo/su, no installer, AppArmor guard armed) and
#      regenerates its initramfs so it includes the Arasaka A/B + dm-verity
#      hooks,
#   2. packs that rootfs into a raw squashfs slot image and appends a dm-verity
#      hash tree to the same file (the hash offset / root hash are baked into
#      the in-bundle post-install hook),
#   3. writes a verity-format RAUC bundle signed with the OTA signing key,
#   4. verifies the bundle against the staged CA (the same keyring the device
#      trusts).
#
# On the device, the bundle's post-install hook writes /boot/ab/verity-<slot>.conf
# (root hash + hash offset) and a per-device /boot/ab/machine-id; the arasaka-ab
# initramfs hook opens the slot through dm-verity on every boot.
#
# Run AFTER ./build.sh on the same host/chroot. Signing material is supplied
# via the OTA_SIGNING_KEY / OTA_SIGNING_CERT environment variables pointing at
# PEM files (CI writes them from GitHub secrets; never committed).
set -euo pipefail
set -x

NAME="arasaka"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)/build"
ROOTFS="${BUILD_DIR}/rootfs"
HARDENED="${BUILD_DIR}/bundle-rootfs"
IMG="${BUILD_DIR}/rootfs.img"
BUNDLE_DIR="${BUILD_DIR}/bundle"
DEBUG_DIR="${BUILD_DIR}/debug"

mkdir -p "${DEBUG_DIR}" || true
# capture stderr to debug file as well
exec 2> >(tee -a "${DEBUG_DIR}/build-bundle.err" >&2)

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
# Like run() but keeps stderr + stdout (for rauc / veritysetup where we need
# the real output).
run_verbose() { echo "$PASSWORD" | sudo -S "$@"; }

SIGN_KEY="${OTA_SIGNING_KEY:-}"
SIGN_CERT="${OTA_SIGNING_CERT:-}"

dump_system_info() {
    log "--- system information ---"
    df -h /tmp / || df -h || true
    free -h || true
    ulimit -a || true
    for t in mksquashfs veritysetup rauc desync; do
        if command -v "$t" >/dev/null 2>&1; then
            printf '%s: ' "$t" >> "${DEBUG_DIR}/tool-versions.txt"
            "$t" --version >> "${DEBUG_DIR}/tool-versions.txt" 2>&1 || true
        fi
    done
    log "--- end system information ---"
}

check() {
    [ -d "${ROOTFS}" ] || die "rootfs not found at ${ROOTFS}; run ./build.sh first"
    [ -f "${ROOTFS}/boot/vmlinuz-linux" ] || die "no kernel in rootfs (/boot/vmlinuz-linux)"
    command -v rauc >/dev/null 2>&1 || die "rauc not installed on this host"
    command -v mksquashfs >/dev/null 2>&1 || die "mksquashfs not installed (squashfs-tools)"
    command -v veritysetup >/dev/null 2>&1 || die "veritysetup not installed (cryptsetup)"
    [ -n "$SIGN_KEY" ] && [ -f "$SIGN_KEY" ] || die "OTA_SIGNING_KEY must point at the signing private key PEM"
    [ -n "$SIGN_CERT" ] && [ -f "$SIGN_CERT" ] || die "OTA_SIGNING_CERT must point at the signing certificate PEM"
    [ -f "$(dirname "$0")/config/rauc/ca.crt" ] || die "staged CA missing: config/rauc/ca.crt"
    dump_system_info
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

write_canonical_fstab() {
    # The installed system mounts /boot and /boot/efi by stable filesystem
    # label (set by the partitioner), /data by label, and /var/tmp as tmpfs
    # (the root slot is read-only). UUIDs would break on OTA, since every
    # bundle replaces the rootfs that carries fstab.
    cat > "${HARDENED}/etc/fstab" << 'FSTABEOF'
# Arasaka fstab - systemd manages mounts
/dev/disk/by-label/arasaka-boot    /boot           ext4    defaults,noatime 0 2
/dev/disk/by-label/arasaka-data    /data           btrfs   defaults,noatime,compress=zstd,subvol=/ 0 1
/dev/disk/by-label/EFI              /boot/efi       vfat    defaults,noatime 0 2
tmpfs                               /var/tmp        tmpfs   defaults,noatime,mode=1777 0 0
FSTABEOF
    log "Wrote canonical fstab (label-based, OTA-stable)"
}

prepare_hardened_rootfs() {
    # The slot rootfs must be the installed-system shape (no sudo/installer/
    # live polkit rules), identical to a fresh install. build.sh's ROOTFS is
    # the live-style image and MUST keep sudo for the installer, so copy it and
    # harden the copy. Also regenerate the initramfs inside the copy so the
    # installed slot boots with the A/B + dm-verity hooks.
    log "Preparing hardened rootfs copy (installer/sudo stripped)..."
    rm -rf "${HARDENED}"
    run_quiet mkdir -p "${HARDENED}"
    run_quiet rsync -aHAX --one-file-system \
        --exclude '/dev/*' --exclude '/proc/*' --exclude '/sys/*' --exclude '/run/*' \
        --exclude '/tmp/*' --exclude '/mnt/*' \
        "${ROOTFS}/" "${HARDENED}/"

    write_canonical_fstab

    log "Hardening image (no sudo/wheel/installer)..."
    if ! run arch-chroot "${HARDENED}" /bin/bash \
        /usr/local/bin/arasaka-finalize-install.sh /; then
        die "finalize-install failed inside hardened rootfs"
    fi

    log "Regenerating initramfs inside hardened rootfs (A/B + dm-verity hooks)..."
    run_quiet mkdir -p "${HARDENED}"/{proc,sys,dev,run}
    run mount --bind /proc "${HARDENED}/proc"
    run mount --bind /sys  "${HARDENED}/sys"
    run mount --bind /dev  "${HARDENED}/dev"
    run mount --bind /run  "${HARDENED}/run"
    if run arch-chroot "${HARDENED}" /usr/bin/bash -c 'mkinitcpio -P' >/dev/null 2>&1; then
        log "initramfs regenerated"
    else
        die "mkinitcpio failed inside hardened rootfs"
    fi
    run umount -lf "${HARDENED}/run" 2>/dev/null || true
    run umount -lf "${HARDENED}/dev" 2>/dev/null || true
    run umount -lf "${HARDENED}/sys" 2>/dev/null || true
    run umount -lf "${HARDENED}/proc" 2>/dev/null || true
}

build_rootfs_img() {
    # Pack the hardened rootfs into a squashfs image and append a dm-verity
    # hash tree to the SAME file (--hash-offset). The slot is a raw container;
    # the hash tree rides inside it. The root hash + offset are baked into the
    # bundle hook below and written to /boot on the device. Delegated to
    # scripts/make-verity-slot.sh so shipped and freshly-installed slots are
    # produced identically.
    log "Building squashfs + dm-verity slot image..."
    # Drop the /proc /sys /dev /run bind mounts before squashing. mksquashfs
    # descending a LIVE /proc is pathologically slow and OOM-prone (thousands
    # of entries, vanishing files, pseudo-devices); make-verity-slot.sh also
    # hard-excludes them, but umount first keeps the hardened tree clean.
    for d in proc sys dev run; do
        run umount -lf "${HARDENED}/${d}" 2>/dev/null || true
    done
    rm -f "${IMG}"
    mkdir -p "${DEBUG_DIR}"
    local vout
    # capture output to both a variable and a debug file
    vout=$(run_verbose "$(dirname "$0")/scripts/make-verity-slot.sh" "${HARDENED}" "${IMG}" 2>&1) || true
    printf '%s
' "${vout}" > "${DEBUG_DIR}/make-verity-output.txt"

    ROOT_HASH=$(printf '%s
' "${vout}" | sed -n 's/^root_hash=\(.*\)/\1/p' | tr -d '\r' || true)
    HASH_OFFSET=$(printf '%s
' "${vout}" | sed -n 's/^hash_offset=\(.*\)/\1/p' | tr -d '\r' || true)
    # fallback: if make-verity printed on a single line like "root_hash=... hash_offset=..."
    if [ -z "$ROOT_HASH" ] || [ -z "$HASH_OFFSET" ]; then
        ROOT_HASH=$(printf '%s
' "${vout}" | sed -n 's/^root_hash=\([^ ]*\) .*/\1/p' || true)
        HASH_OFFSET=$(printf '%s
' "${vout}" | sed -n 's/.*hash_offset=\([^ ]*\)$/\1/p' || true)
    fi

    if [ -z "${ROOT_HASH}" ] || [ -z "${HASH_OFFSET}" ]; then
        log "make-verity-slot did not produce root hash/hash offset. Dumping debug output..."
        echo "---- make-verity output (first 400 lines) ----" >&2
        sed -n '1,400p' "${DEBUG_DIR}/make-verity-output.txt" >&2 || true
        echo "---- listing build dir ----" >&2
        ls -lh "${BUILD_DIR}" || true
        echo "---- file sizes ----" >&2
        du -sh "${BUILD_DIR}"/* || true
        df -h /tmp / || df -h || true
        die "make-verity-slot.sh failed (no root hash/offset captured)"
    fi

    log "Verity root hash: ${ROOT_HASH}"
    log "Hash offset:      ${HASH_OFFSET}"
}

write_bundle() {
    log "Writing bundle directory + manifest..."
    run_quiet rm -rf "${BUNDLE_DIR}"
    mkdir -p "${BUNDLE_DIR}"

    # Per-slot post-install hook: writes the slot's dm-verity conf (consumed by
    # the arasaka-ab initramfs hook) and a per-device machine-id to /boot. The
    # root hash / offset are baked in at build time - they match rootfs.img.
    cat > "${BUNDLE_DIR}/hook.sh" << HOOKEOF
#!/bin/sh
# Generated per-bundle: writes the slot's dm-verity conf + per-device
# machine-id on install. Values are baked at bundle build time.
ROOT_HASH="${ROOT_HASH}"
HASH_OFFSET="${HASH_OFFSET}"

case "\$1" in
    slot-post-install)
        case "\$RAUC_SLOT_NAME" in
            rootfs.0) slot=a ;;
            rootfs.1) slot=b ;;
            *) echo "unknown slot: \$RAUC_SLOT_NAME" >&2; exit 1 ;;
        esac
        echo "writing /boot/ab/verity-\${slot}.conf for slot \${slot}"
        # /boot is the shared writable partition; the arasaka-ab initramfs hook
        # reads this to open the slot via dm-verity on the next boot.
        mkdir -p /boot/ab
        printf 'root_hash=%s\nhash_offset=%s\n' "\$ROOT_HASH" "\$HASH_OFFSET" \
            > "/boot/ab/verity-\${slot}.conf"
        # Per-device machine-id: create once, never overwrite (systemd identity
        # must be stable across updates).
        if [ ! -s /boot/ab/machine-id ]; then
            od -An -N16 -tx1 /dev/urandom | tr -d ' \n' > /boot/ab/machine-id 2>/dev/null || true
            chmod 444 /boot/ab/machine-id 2>/dev/null || true
        fi
        sync
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
filename=rootfs.img
hooks=post-install
MANIFESTEOF

    # The image goes into the bundle directory for rauc bundle to pick up.
    run_quiet cp "${IMG}" "${BUNDLE_DIR}/rootfs.img"
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

    prepare_hardened_rootfs
    build_rootfs_img
    # keep the hardened rootfs around for debugging if something went wrong
    run_quiet rm -rf "${HARDENED}"

    write_bundle
    build_and_verify_bundle

    log "=== Bundle build complete ==="
    log "Bundle: ${BUILD_DIR}/arasaka-${VERSION}.raucb"
    log "Next: upload to B2 updates bucket as update/stable/arasaka-${VERSION}.raucb"
    log "      and publish update/stable/latest.json (+ .sig) pointing at it"
}

main "$@"
