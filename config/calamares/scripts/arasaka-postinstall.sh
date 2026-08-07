#!/usr/bin/env bash
# arasaka-postinstall.sh
# Calamares post-install hook (shellprocess, dontChroot=true): records the
# active A/B slot on the freshly installed system, encrypts /data with LUKS2
# (TPM2 auto-unlock on first boot, recovery key on /boot/ab), moves flatpak
# apps onto the encrypted data partition so they survive A/B updates, generates
# + persists the Secure Boot keypair, builds + signs the per-slot UKIs on the
# ESP, and finalizes the installed system (installer stripped, sudo/su/pkexec
# disabled, AppArmor guard armed) via scripts/arasaka-finalize-install.sh. It
# then packs the installed rootfs into a raw squashfs + dm-verity slot image
# (the same tool the OTA bundle builder uses) and images the inactive slot B
# with it, making slot B the active slot so the very first boot of the
# installed system is already block-verified.
#
# $1 = ${ROOT} as expanded by Calamares (target root mount point).
set -euo pipefail

TARGET="${1:-}"
TARGET="${TARGET%/}"
if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
    echo "[arasaka-postinstall] ERROR: no valid target root: '${1}'" >&2
    exit 1
fi

echo "[arasaka-postinstall] Target root: ${TARGET}"

mkdir -p "${TARGET}/boot/ab"
echo "a" > "${TARGET}/boot/ab/active-slot"

# Per-device machine-id. The slots are read-only squashfs images (shared by
# every device), so the id must live on the writable /boot partition; the
# arasaka-ab initramfs hook binds it over /etc/machine-id at boot. Calamares
# already generated the target id - reuse it so the id is stable; fall back to
# generating one here if the target has none yet.
if [ -s "${TARGET}/etc/machine-id" ]; then
    cp -a "${TARGET}/etc/machine-id" "${TARGET}/boot/ab/machine-id" 2>/dev/null || true
else
    od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' > "${TARGET}/boot/ab/machine-id" 2>/dev/null || true
fi
chmod 444 "${TARGET}/boot/ab/machine-id" 2>/dev/null || true
echo "[arasaka-postinstall] Per-device machine-id on /boot/ab/machine-id"

# The root mount is handled by the arasaka-ab initramfs hook (by slot label);
# fstab must NOT reference a specific slot's root device or systemd would try
# to remount it over whatever slot is actually active. Strip the "/" entry.
if [ -f "${TARGET}/etc/fstab" ]; then
    grep -Ev '^[^#[:space:]][^[:space:]]+[[:space:]]+/[[:space:]]' \
        "${TARGET}/etc/fstab" > "${TARGET}/etc/fstab.arasaka"
    mv "${TARGET}/etc/fstab.arasaka" "${TARGET}/etc/fstab"
    echo "[arasaka-postinstall] Removed root mount entry from fstab"
fi

# --- Encrypt /data (LUKS2, TPM2 auto-unlock on the installed system) ---
# Calamares formats /data as plain btrfs. Encrypt it NOW while the installer
# still has the target mounted, so the installed system's /data is encrypted
# from first boot. The TPM2 key cannot be sealed here (the live ISO's PCRs
# differ from the installed system's), so arasaka-cryptdata.sh seals on first
# boot; a recovery key is stored on /boot/ab for fallback.
DATA_ENCRYPTED=0
DATA_SRC=$(findmnt -n -o SOURCE "${TARGET}/data" 2>/dev/null || true)
if [ -n "$DATA_SRC" ] && [ -b "$DATA_SRC" ]; then
    echo "[arasaka-postinstall] Encrypting /data with LUKS2..."
    RECOVERY_PASS=$(openssl rand -hex 16)
    keyfile=$(mktemp)
    printf '%s' "$RECOVERY_PASS" > "$keyfile"
    chmod 400 "$keyfile"
    umount "${TARGET}/data"
    if cryptsetup luksFormat --type luks2 -q "$DATA_SRC" "$keyfile" \
        && cryptsetup open "$DATA_SRC" arasaka-data -d "$keyfile" \
        && mkfs.btrfs -f -L arasaka-data /dev/mapper/arasaka-data; then
        mount /dev/mapper/arasaka-data "${TARGET}/data"
        printf '%s' "$RECOVERY_PASS" > "${TARGET}/boot/ab/data-recovery.key"
        chmod 400 "${TARGET}/boot/ab/data-recovery.key"
        echo "[arasaka-postinstall] /data encrypted; recovery key on /boot/ab/data-recovery.key"
        DATA_ENCRYPTED=1
    else
        echo "[arasaka-postinstall] ERROR: LUKS setup for /data failed; leaving it unencrypted (LEGACY fallback)" >&2
        mount -t btrfs "$DATA_SRC" "${TARGET}/data" 2>/dev/null || true
    fi
    rm -f "$keyfile"
else
    echo "[arasaka-postinstall] No mounted /data found; skipping LUKS (legacy layout)"
fi

# /data is LUKS: drop the Calamares btrfs mount line from fstab (a locked
# volume must never block boot) and unlock it via crypttab + arasaka-cryptdata.
# cryptsetup/crypttab options mirror install-to-disk.sh.
if [ "$DATA_ENCRYPTED" -eq 1 ]; then
    if [ -f "${TARGET}/etc/fstab" ]; then
        awk '$2 != "/data"' "${TARGET}/etc/fstab" > "${TARGET}/etc/fstab.arasaka"
        mv "${TARGET}/etc/fstab.arasaka" "${TARGET}/etc/fstab"
        echo "[arasaka-postinstall] Removed /data mount from fstab (LUKS)"
    fi
    if ! grep -q 'arasaka-data' "${TARGET}/etc/crypttab" 2>/dev/null; then
        printf 'arasaka-data\tPARTLABEL=arasaka-data\tnone\tnoauto,tpm2-device=auto,keyfile-timeout=0\n' \
            >> "${TARGET}/etc/crypttab"
        echo "[arasaka-postinstall] crypttab: arasaka-data (LUKS2, TPM2 auto)"
    fi
    # btrfs subvolumes + RAUC persistent state live on the mapper now.
    for sv in @flatpak @snap @snapd @systemd @log @cache @home; do
        btrfs subvolume create "${TARGET}/data/${sv}" 2>/dev/null || mkdir -p "${TARGET}/data/${sv}"
    done
    mkdir -p "${TARGET}/data/rauc/boot"
    printf 'A\n' > "${TARGET}/data/rauc/boot/primary"
    printf 'good\n' > "${TARGET}/data/rauc/boot/A.state"
    printf 'good\n' > "${TARGET}/data/rauc/boot/B.state"
fi

# Move the system-wide flatpak store onto the shared btrfs data partition and
# bind-mount it back at runtime (persist-data binds @flatpak -> /var/lib/flatpak).
# A/B slot updates do NOT copy /var/lib/flatpak (it is ~6G and the update
# engine rsyncs the running root to the inactive slot), so apps installed into
# the ISO would be lost on the first update otherwise.
if [ -d "${TARGET}/data" ]; then
    echo "[arasaka-postinstall] Moving flatpak store to data partition..."
    mkdir -p "${TARGET}/data/@flatpak"
    if [ -d "${TARGET}/var/lib/flatpak" ] && [ -z "$(ls -A "${TARGET}/data/@flatpak" 2>/dev/null)" ]; then
        cp -a "${TARGET}/var/lib/flatpak"/. "${TARGET}/data/@flatpak/" 2>/dev/null || true
    fi

    # Replace the per-slot flatpak dir with a mountpoint for the runtime bind.
    rm -rf "${TARGET}/var/lib/flatpak"
    mkdir -p "${TARGET}/var/lib/flatpak"
    echo "[arasaka-postinstall] flatpak store moved to /data/@flatpak (bound at runtime)"
else
    echo "[arasaka-postinstall] WARNING: no /data in target; flatpak store stays on the slot (will be lost on A/B update)"
fi

# Generate the Secure Boot signing keys once and persist them on the encrypted
# /data partition so they survive OTA slot swaps. arasaka-secureboot.service
# enrolls them into the firmware on the first boot in Setup Mode.
if command -v sbctl >/dev/null 2>&1 && [ "$DATA_ENCRYPTED" -eq 1 ]; then
    echo "[arasaka-postinstall] Generating Secure Boot signing keys..."
    sbctl create-keys 2>/dev/null || true
    for d in /usr/share/secureboot/keys /etc/secureboot/keys; do
        if [ -f "${d}/db/db.key" ]; then
            mkdir -p "${TARGET}/data/secureboot"
            rm -rf "${TARGET}/data/secureboot/keys"
            cp -a "$d" "${TARGET}/data/secureboot/keys"
            echo "[arasaka-postinstall] SB keys persisted on /data/secureboot/keys"
            break
        fi
    done
fi

# Finalize the installed system: strip the installer, disable privilege
# escalation (no wheel/sudo members, no sudoers.d, locked root, no setuid
# pkexec/sudo/su), arm the AppArmor escalation guard and add tmpfs /var/tmp.
# Shared with build-bundle.sh so OTA bundles ship the same locked-down shape.
if [ -x "${TARGET}/usr/local/bin/arasaka-finalize-install.sh" ]; then
    echo "[arasaka-postinstall] Running finalize-install hardening..."
    "${TARGET}/usr/local/bin/arasaka-finalize-install.sh" "${TARGET}"
else
    echo "[arasaka-postinstall] WARNING: finalize-install script missing in target" >&2
fi

# COSMIC Initial Setup is a first-login wizard that looks like an installer and
# can hang if it can't reach its daemon. The autostart entry is what pops it on
# login, so removing it stops the wizard on the installed system.
rm -f "${TARGET}/etc/xdg/autostart/com.system76.CosmicInitialSetup.desktop" \
      "${TARGET}/usr/share/applications/com.system76.CosmicInitialSetup.desktop" \
      "${TARGET}/usr/share/polkit-1/rules.d/20-cosmic-initial-setup.rules" \
      2>/dev/null || true

mkdir -p "${TARGET}/etc/arasaka"
echo "a" > "${TARGET}/etc/arasaka/active-slot"

echo "[arasaka-postinstall] Active slot recorded as 'a'"

# The unpacked rootfs carries the archiso-built initramfs (with archiso
# hooks). Switch it to the busybox-style initramfs so the arasaka-ab hook can
# override the root mount handler (the systemd initramfs hook cannot run
# run_hook() mount_handler overrides), then regenerate it for a plain disk
# install so the installed system boots from the active A/B slot. The A/B
# root slots are squashfs images opened through dm-verity, so veritysetup and
# the dm-verity/squashfs modules must be in the initramfs (arasaka-verity
# hook + MODULES).
echo "[arasaka-postinstall] Forcing busybox initramfs (arasaka-ab + arasaka-verity + plymouth)..."
if [ -f "${TARGET}/etc/mkinitcpio.conf" ]; then
    sed -i -E 's/^HOOKS=\(.*\)$/HOOKS=(base udev plymouth autodetect microcode modconf kms keyboard keymap consolefont block arasaka-verity filesystems fsck arasaka-ab)/' \
        "${TARGET}/etc/mkinitcpio.conf"
    if ! grep -q '^MODULES=' "${TARGET}/etc/mkinitcpio.conf"; then
        printf 'MODULES=(dm-mod dm-verity squashfs overlay btrfs)\n' >> "${TARGET}/etc/mkinitcpio.conf"
    fi
fi
echo "[arasaka-postinstall] Regenerating initramfs in target..."
INITRAMFS_OK=1
if chroot "${TARGET}" /usr/bin/mkinitcpio -P; then
    echo "[arasaka-postinstall] initramfs regenerated"
else
    INITRAMFS_OK=0
    echo "[arasaka-postinstall] WARNING: mkinitcpio regeneration failed" >&2
fi

# A/B Unified Kernel Images + loader entries for systemd-boot.
#
# Each slot gets a signed UKI on the ESP (/boot/efi/EFI/arasaka/arasaka-<slot>.efi)
# embedding kernel + initramfs + cmdline (rauc.slot) + os-release. The loader
# entries reference the UKIs by `efi` path. The UKIs are signed with the
# keypair persisted on /data; arasaka-secureboot.service enrolls that keypair
# into the firmware on the first boot in Setup Mode. rauc-boot-handler rebuilds
# both UKIs on every set-primary.
#
# The ESP is the loader dir whose parent is a mounted vfat partition (Calamares
# mounts it at /boot/efi; /boot is the ext4 arasaka-boot partition).
ESP_DIR=""
for LD in "${TARGET}/boot/efi/loader" "${TARGET}/boot/loader"; do
    [ -d "$LD" ] || continue
    parent="${LD%/loader}"
    if mountpoint -q "$parent" 2>/dev/null; then
        ESP_DIR="$parent"
        break
    fi
done
[ -n "$ESP_DIR" ] && [ -d "${ESP_DIR}/EFI" ] || ESP_DIR="${TARGET}/boot/efi"
[ -d "${ESP_DIR}/EFI" ] || ESP_DIR="${TARGET}/boot"
mkdir -p "${ESP_DIR}/EFI/arasaka" "${ESP_DIR}/loader/entries"
echo "[arasaka-postinstall] ESP at ${ESP_DIR}"

KNAME=$(find "${TARGET}/boot" -maxdepth 1 -name 'vmlinuz*' -printf '%f\n' 2>/dev/null | sort -V | tail -1 || echo vmlinuz-linux)
IMGNAME="initramfs${KNAME#vmlinuz}.img"
[ -f "${TARGET}/boot/${IMGNAME}" ] || IMGNAME="initramfs-linux.img"

KEYS_DIR=""
for d in /usr/share/secureboot/keys /etc/secureboot/keys; do
    if [ -f "${d}/db/db.key" ]; then
        KEYS_DIR="$d"
        break
    fi
done

UKIFY="$(command -v ukify || echo /usr/lib/systemd/ukify)"
for s in a b; do
    boot="${s^^}"
    uki="${ESP_DIR}/EFI/arasaka/arasaka-${s}.efi"
    tmp="${uki}.unsigned"
    if ! "${UKIFY}" build \
        --linux="${TARGET}/boot/${KNAME}" \
        --initrd="${TARGET}/boot/${IMGNAME}" \
        --cmdline="root=PARTLABEL=arasaka-slot-${s} ro rauc.slot=${boot}" \
        --os-release="${TARGET}/etc/os-release" \
        --output="$tmp" 2>/dev/null; then
        echo "[arasaka-postinstall] ERROR: ukify build failed for slot ${s}" >&2
        continue
    fi
    if [ -n "$KEYS_DIR" ]; then
        sbctl sign --output "$uki" "$tmp" 2>/dev/null || mv -f "$tmp" "$uki"
    else
        mv -f "$tmp" "$uki"
    fi
    rm -f "$tmp"
    cat > "${ESP_DIR}/loader/entries/arasaka-${s}.conf" << ENTRYEOF
title   Arasaka (Slot ${boot})
efi     /EFI/arasaka/arasaka-${s}.efi
ENTRYEOF
    echo "[arasaka-postinstall] Built ${uki} + entry arasaka-${s}.conf"
done

# Point systemd-boot at the A/B default (both loader dirs if present).
for LD in "${TARGET}/boot/loader" "${TARGET}/boot/efi/loader"; do
    if [ -f "${LD}/loader.conf" ]; then
        sed -i 's/^default .*/default arasaka-a.conf/' "${LD}/loader.conf"
        echo "[arasaka-postinstall] ${LD}/loader.conf default -> arasaka-a.conf"
    fi
done

# UKI baseline hashes for arasaka-verify-boot (RAUC state lives on /data).
if [ -d "${TARGET}/data/rauc/boot" ]; then
    for s in a b; do
        boot="${s^^}"
        uki="${ESP_DIR}/EFI/arasaka/arasaka-${s}.efi"
        if [ -f "$uki" ]; then
            sha256sum "$uki" | cut -d' ' -f1 > "${TARGET}/data/rauc/boot/${boot}.uki.sha256"
        fi
    done
    echo "[arasaka-postinstall] Recorded UKI baseline hashes"
fi

# --- Verified first boot: image the installed rootfs as a verity slot ---
# Instead of leaving the fresh install as an unverified ext4 root until the
# first OTA, pack the finalized target into a raw squashfs + dm-verity slot
# image (the same make-verity-slot.sh the OTA bundle builder uses) and image
# the inactive slot B with it. Slot B becomes the active slot, so the very
# first boot of the installed system is block-verified. Slot A is the Calamares
# root target and is still mounted here, so it stays ext4 until the first OTA
# replaces it; it serves as the rollback fallback. The /data, /boot/efi,
# /boot/loader and /boot/ab trees are mounted partitions / device state, not
# part of the slot image.
STAGING="${TARGET}/data/.arasaka-staging"
VERITY_IMG="${STAGING}/rootfs.img"
VERITY_CONF="${STAGING}/verity.conf"

make_verity_slot() {
    local maker
    maker="$(command -v make-verity-slot.sh 2>/dev/null || true)"
    [ -n "$maker" ] && [ -x "$maker" ] || maker="${TARGET}/usr/local/bin/make-verity-slot.sh"
    "$maker" --exclude=/data --exclude=/boot/efi --exclude=/boot/loader --exclude=/boot/ab \
        "${TARGET}" "${VERITY_IMG}" "${VERITY_CONF}"
}

promote_slot_b() {
    # Flip the A/B markers and the loader default to slot B only after the
    # verified image is in place, so a failure never leaves the primary slot
    # unverified (or worse, non-bootable).
    cp -a "${VERITY_CONF}" "${TARGET}/boot/ab/verity-b.conf" || return 1
    printf 'b\n' > "${TARGET}/boot/ab/active-slot" || return 1
    printf 'b\n' > "${TARGET}/etc/arasaka/active-slot" || return 1
    printf 'B\n' > "${TARGET}/data/rauc/boot/primary" || return 1
    local LD
    for LD in "${TARGET}/boot/loader" "${TARGET}/boot/efi/loader"; do
        [ -f "${LD}/loader.conf" ] || continue
        sed -i 's/^default .*/default arasaka-b.conf/' "${LD}/loader.conf" || return 1
    done
    return 0
}

echo "[arasaka-postinstall] Building verified slot image from installed rootfs..."
if [ "${INITRAMFS_OK}" -ne 1 ]; then
    echo "[arasaka-postinstall] Skipping verity imaging (initramfs regeneration failed); slot A (ext4) stays active" >&2
elif mkdir -p "${STAGING}" && make_verity_slot; then
    slotb="/dev/disk/by-partlabel/arasaka-slot-b"
    if [ -b "$slotb" ] && dd if="${VERITY_IMG}" of="$slotb" bs=1M conv=fsync status=none 2>/dev/null; then
        sync
        if promote_slot_b; then
            echo "[arasaka-postinstall] Slot B active: verified squashfs + dm-verity from first boot"
        else
            echo "[arasaka-postinstall] ERROR: could not promote slot B; slot A (ext4) stays active" >&2
        fi
    else
        echo "[arasaka-postinstall] ERROR: writing slot B failed; slot A (ext4) stays active" >&2
    fi
else
    echo "[arasaka-postinstall] ERROR: verity slot image build failed; slot A (ext4) stays active" >&2
fi
rm -rf "${STAGING}" 2>/dev/null || true
