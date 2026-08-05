#!/usr/bin/env bash
# install-to-disk.sh
# Partitions a target disk and installs Arasaka with A/B immutable slots.
# Run from the live ISO or from the host.
set -euo pipefail

# Sudo password from $ARASAKA_SUDO_PASSWORD or local gitignored build.conf.
if [ -n "${ARASAKA_SUDO_PASSWORD:-}" ]; then
    PASSWORD="$ARASAKA_SUDO_PASSWORD"
elif [ -f "$(dirname "$0")/build.conf" ]; then
    # shellcheck disable=SC1091
    . "$(dirname "$0")/build.conf"
    PASSWORD="${ARASAKA_SUDO_PASSWORD:-}"
else
    PASSWORD=""
fi
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)/build"
ROOTFS="${BUILD_DIR}/rootfs"

log() { echo "[disk-installer] $*"; }
die() { log "FATAL: $*"; exit 1; }

[ -n "$PASSWORD" ] || die "Set ARASAKA_SUDO_PASSWORD or create build.conf (see build.conf.example)"

usage() {
    cat << 'EOF'
Arasaka Disk Installer

Usage: sudo ./install-to-disk.sh <target-disk>

Example:
  sudo ./install-to-disk.sh /dev/sda
  sudo ./install-to-disk.sh /dev/nvme0n1

This will DESTROY all data on the target disk!

Disk layout:
  Partition 1: EFI System Partition (512MB, FAT32)
  Partition 2: Boot (1GB, ext4)
  Partition 3: Slot A root (20GB, raw squashfs + dm-verity image)
  Partition 4: Slot B root (20GB, same)
  Partition 5: Data (remaining, btrfs - /home, /var/lib/flatpak, etc.)
EOF
    exit 1
}

check_target() {
    local target="$1"
    if [ ! -b "$target" ]; then
        die "Target ${target} is not a block device"
    fi

    # Check if mounted
    if mount | grep -q "^${target}"; then
        die "Target ${target} has mounted partitions. Unmount first."
    fi

    local size
    size=$(lsblk -bnd -o SIZE "$target")
    local size_gb=$(( size / 1024 / 1024 / 1024 ))
    if [ "$size_gb" -lt 30 ]; then
        die "Target disk too small (${size_gb}GB). Need at least 30GB."
    fi

    log "Target: ${target} (${size_gb}GB)"
}

partition_disk() {
    local target="$1"
    log "Partitioning ${target}..."

    # Wipe and create GPT
    echo "$PASSWORD" | sudo -S sgdisk --zap-all "$target"
    echo "$PASSWORD" | sudo -S sgdisk --clear "$target"

    # Partition 1: EFI (512MB)
    echo "$PASSWORD" | sudo -S sgdisk --new=1:0:+512M --typecode=1:ef00 --change-name=1:"EFI" "$target"

    # Partition 2: Boot (1GB). The sgdisk partition names double as GPT
    # partlabels (/dev/disk/by-partlabel/...) which the arasaka-ab hook and
    # boot handler prefer; label-based lookup is the fallback.
    echo "$PASSWORD" | sudo -S sgdisk --new=2:0:+1G --typecode=2:8300 --change-name=2:"arasaka-boot" "$target"

    # Partition 3: Slot A (20GB)
    echo "$PASSWORD" | sudo -S sgdisk --new=3:0:+20G --typecode=3:8300 --change-name=3:"arasaka-slot-a" "$target"

    # Partition 4: Slot B (20GB)
    echo "$PASSWORD" | sudo -S sgdisk --new=4:0:+20G --typecode=4:8300 --change-name=4:"arasaka-slot-b" "$target"

    # Partition 5: Data (remaining)
    echo "$PASSWORD" | sudo -S sgdisk --new=5:0:0 --typecode=5:8300 --change-name=5:"arasaka-data" "$target"

    # Get partition naming
    local p1 p2 p3 p4 p5
    if [[ "$target" == *"nvme"* ]] || [[ "$target" == *"loop"* ]] || [[ "$target" == *"mmcblk"* ]]; then
        p1="${target}p1"
        p2="${target}p2"
        p3="${target}p3"
        p4="${target}p4"
        p5="${target}p5"
    else
        p1="${target}1"
        p2="${target}2"
        p3="${target}3"
        p4="${target}4"
        p5="${target}5"
    fi

    # Format partitions. The slots are formatted ext4 purely as a writable
    # staging area for the rootfs (slot A); after the tree is finalized and its
    # initramfs regenerated, install_rootfs() packs it into a raw squashfs +
    # dm-verity image and writes that image to BOTH slots, so a fresh install
    # is block-verified from the very first boot.
    log "Formatting partitions..."
    echo "$PASSWORD" | sudo -S mkfs.fat -F32 -n EFI "$p1"
    echo "$PASSWORD" | sudo -S mkfs.ext2 -L arasaka-boot "$p2"
    echo "$PASSWORD" | sudo -S mkfs.ext4 -L arasaka-slot-a "$p3"
    echo "$PASSWORD" | sudo -S mkfs.ext4 -L arasaka-slot-b "$p4"
    echo "$PASSWORD" | sudo -S mkfs.btrfs -f -L arasaka-data "$p5"

    echo "$p1" "$p2" "$p3" "$p4" "$p5"
}

install_rootfs() {
    local p3="$1"
    local p4="$2"
    local p5="$3"

    log "Installing rootfs to Slot A..."

    # Create mount points
    local mnt="/var/tmp/arasaka-install-mnt"
    sudo rm -rf "$mnt"
    sudo mkdir -p "$mnt"

    # Mount slot A
    sudo mkdir -p "${mnt}/slot-a"
    sudo mount "$p3" "${mnt}/slot-a"

    # Mount data partition
    sudo mkdir -p "${mnt}/data"
    sudo mount "$p5" "${mnt}/data"

    # Initialize data partition subvolumes
    log "Creating data partition subvolumes..."
    sudo btrfs subvolume create "${mnt}/data/@flatpak" 2>/dev/null || true
    sudo btrfs subvolume create "${mnt}/data/@snap" 2>/dev/null || true
    sudo btrfs subvolume create "${mnt}/data/@snapd" 2>/dev/null || true
    sudo btrfs subvolume create "${mnt}/data/@systemd" 2>/dev/null || true
    sudo btrfs subvolume create "${mnt}/data/@log" 2>/dev/null || true
    sudo btrfs subvolume create "${mnt}/data/@cache" 2>/dev/null || true
    sudo btrfs subvolume create "${mnt}/data/@home" 2>/dev/null || true

    # RAUC persistent state directory on the data partition (survives slot
    # swaps). Both slots default to good; primary is slot A.
    sudo mkdir -p "${mnt}/data/rauc/boot"
    echo "A" | sudo tee "${mnt}/data/rauc/boot/primary" >/dev/null
    echo "good" | sudo tee "${mnt}/data/rauc/boot/A.state" >/dev/null
    echo "good" | sudo tee "${mnt}/data/rauc/boot/B.state" >/dev/null

    # Copy rootfs to slot A
    log "Copying rootfs to Slot A..."
    sudo cp -a "${ROOTFS}/." "${mnt}/slot-a/"

    # Detect latest kernel dynamically
    log "Detecting latest kernel..."
    local kname imgname
    kname=$(sudo find "${ROOTFS}/boot" -name 'vmlinuz*' -printf '%f\n' 2>/dev/null \
        | sort -V | tail -1 || echo "vmlinuz-linux")
    imgname="initramfs${kname#vmlinuz}.img"

    # Fallback
    [ -f "${ROOTFS}/boot/${kname}" ] || kname="vmlinuz-linux"
    [ -f "${ROOTFS}/boot/${imgname}" ] || imgname="initramfs-linux.img"

    log "Kernel: ${kname} | Initramfs: ${imgname}"

    # Install systemd-boot
    log "Installing systemd-boot..."
    sudo mkdir -p "${mnt}/slot-a/boot/ab"
    sudo mkdir -p "${mnt}/slot-a/boot/efi"

    # Mount boot and EFI
    local p2
    p2="$(dirname "$p3")/$(basename "$p3" | sed 's/[0-9]$/2/')"

    sudo mkdir -p "${mnt}/boot"
    sudo mount "$p2" "${mnt}/boot"

    local p1
    p1="$(dirname "$p3")/$(basename "$p3" | sed 's/[0-9]$/1/')"
    sudo mkdir -p "${mnt}/boot-efi"
    sudo mount "$p1" "${mnt}/boot-efi"

    sudo bootctl --esp-path="${mnt}/boot-efi" --boot-path="${mnt}/boot" install

    # Create loader config
    sudo tee "${mnt}/boot/loader/loader.conf" >/dev/null << LEOF
default arasaka-a.conf
timeout 3
console-mode auto
editor no
LEOF

    # Slot A boot entry (per-slot kernel). The slot root is mounted read-only
    # by the arasaka-ab initramfs hook; `ro` here is only the degraded fallback
    # cmdline. PARTLABEL works for both a fresh ext4 slot and a verity-protected
    # squashfs slot; rauc.slot tells RAUC which slot actually booted.
    sudo tee "${mnt}/boot/loader/entries/arasaka-a.conf" >/dev/null << AEOF
title   Arasaka (Slot A)
linux   /vmlinuz-arasaka-a
initrd  /initramfs-arasaka-a.img
options root=PARTLABEL=arasaka-slot-a ro rauc.slot=A
AEOF

    # Slot B boot entry (per-slot kernel)
    sudo tee "${mnt}/boot/loader/entries/arasaka-b.conf" >/dev/null << BEOF
title   Arasaka (Slot B)
linux   /vmlinuz-arasaka-b
initrd  /initramfs-arasaka-b.img
options root=PARTLABEL=arasaka-slot-b ro rauc.slot=B
BEOF

    # Kernel for the boot loader (per-slot names). The RAUC boot handler
    # re-extracts kernel+initramfs from a freshly-written slot on every
    # set-primary, keeping them in lockstep with the slot content.
    sudo cp "${ROOTFS}/boot/${kname}" "${mnt}/boot/vmlinuz-arasaka-a" 2>/dev/null || \
        sudo cp /boot/${kname} "${mnt}/boot/vmlinuz-arasaka-a" 2>/dev/null || \
        sudo cp /boot/vmlinuz-linux "${mnt}/boot/vmlinuz-arasaka-a"
    sudo cp "${mnt}/boot/vmlinuz-arasaka-a" "${mnt}/boot/vmlinuz-arasaka-b" 2>/dev/null || true

    # Set initial active slot (markers live on the writable /boot partition)
    sudo mkdir -p "${mnt}/boot/ab"
    echo "a" | sudo tee "${mnt}/boot/ab/active-slot" >/dev/null

    # Create fstab for the installed system. /boot stays writable (A/B swap
    # markers + kernel extraction); /var/tmp is tmpfs because the root slot is
    # mounted read-only. /etc is part of the ro image (its runtime state -
    # NetworkManager/cups - is bound from /data by persist-data), and /var
    # gets overlayfs from /data in the initramfs hook, so no fstab entry is
    # needed for them.
    sudo tee "${mnt}/slot-a/etc/fstab" >/dev/null << FSTABEOF
# Arasaka fstab - systemd manages mounts
/dev/disk/by-label/arasaka-boot    /boot           ext4    defaults,noatime 0 2
/dev/disk/by-label/arasaka-data    /data           btrfs   defaults,noatime,compress=zstd,subvol=/ 0 1
/dev/disk/by-label/EFI              /boot/efi       vfat    defaults,noatime 0 2
tmpfs                               /var/tmp        tmpfs   defaults,noatime,mode=1777 0 0
FSTABEOF

    # Copy install scripts to the installed system
    sudo cp "$(dirname "$0")/scripts/"*.sh "${mnt}/slot-a/usr/local/bin/" 2>/dev/null || true
    sudo chmod +x "${mnt}/slot-a/usr/local/bin/"*.sh 2>/dev/null || true

    # Harden the installed slot exactly like a Calamares install: no sudo/su,
    # no wheel, no installer, AppArmor guard armed, fresh machine-id (the raw
    # build rootfs is the live-style image and must be locked down before use).
    sudo "${mnt}/slot-a/usr/local/bin/arasaka-finalize-install.sh" "${mnt}/slot-a"

    # Regenerate the initramfs inside the installed slot so it carries the
    # arasaka-verity + arasaka-ab hooks (veritysetup + dm-verity/squashfs
    # modules) and boots the A/B root slot through dm-verity.
    log "Regenerating verity-capable initramfs in slot A..."
    sudo sed -i -E 's/^HOOKS=\(.*\)$/HOOKS=(base udev plymouth autodetect microcode modconf kms keyboard keymap consolefont block arasaka-verity filesystems fsck arasaka-ab)/' \
        "${mnt}/slot-a/etc/mkinitcpio.conf"
    if ! grep -q '^MODULES=' "${mnt}/slot-a/etc/mkinitcpio.conf"; then
        printf 'MODULES=(dm-mod dm-verity squashfs overlay btrfs)\n' | sudo tee -a "${mnt}/slot-a/etc/mkinitcpio.conf" >/dev/null
    fi
    for d in proc sys dev run; do
        sudo mount --bind "/${d}" "${mnt}/slot-a/${d}" 2>/dev/null || true
    done
    if sudo chroot "${mnt}/slot-a" /usr/bin/mkinitcpio -P; then
        log "initramfs regenerated"
        sudo cp "${mnt}/slot-a/boot/${imgname}" "${mnt}/boot/initramfs-arasaka-a.img" 2>/dev/null || \
            sudo cp "${mnt}/slot-a/boot/initramfs-linux.img" "${mnt}/boot/initramfs-arasaka-a.img" 2>/dev/null || true
        sudo cp "${mnt}/boot/initramfs-arasaka-a.img" "${mnt}/boot/initramfs-arasaka-b.img" 2>/dev/null || true
    else
        die "initramfs regeneration failed; aborting (a fresh install must ship the A/B + dm-verity initramfs)"
    fi

    # Per-device machine-id on /boot (the slots are read-only squashfs shared
    # across devices; the arasaka-ab hook binds this over /etc/machine-id).
    od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | sudo tee "${mnt}/boot/ab/machine-id" >/dev/null || true
    sudo chmod 444 "${mnt}/boot/ab/machine-id" 2>/dev/null || true

    # Drop the chroot bind mounts before packing so mksquashfs never recurses
    # into them.
    for d in proc sys dev run; do
        sudo umount -lf "${mnt}/slot-a/${d}" 2>/dev/null || true
    done

    # Pack the finalized tree into a raw squashfs + dm-verity slot image (the
    # same tool the OTA bundle builder uses) and write it to BOTH slot
    # partitions. A fresh install is therefore block-verified from the very
    # first boot - there is no unverified ext4 window before the first OTA.
    log "Building squashfs + dm-verity slot image..."
    local img="${BUILD_DIR}/rootfs.img"
    local conf="${BUILD_DIR}/verity.conf"
    sudo rm -f "${img}" "${conf}"
    echo "$PASSWORD" | sudo -S "$(dirname "$0")/scripts/make-verity-slot.sh" \
        "${mnt}/slot-a" "${img}" "${conf}" || die "verity slot image build failed"
    local img_bytes
    img_bytes=$(sudo stat -c %s "${img}")

    sudo umount "${mnt}/slot-a"

    log "Writing verified slot image to slots A and B..."
    local slot_dev slot_bytes
    for slot_dev in "$p3" "$p4"; do
        slot_bytes=$(sudo blockdev --getsize64 "$slot_dev")
        if [ "$img_bytes" -gt "$slot_bytes" ]; then
            die "slot image (${img_bytes} bytes) larger than partition ${slot_dev} (${slot_bytes} bytes)"
        fi
        echo "$PASSWORD" | sudo -S dd if="${img}" of="${slot_dev}" bs=1M conv=fsync status=none
    done
    sudo sync

    # Write the verity conf (root hash + hash offset) the initramfs hook reads
    # to open a slot through dm-verity. Both slots carry the same image, so the
    # conf is identical for A and B.
    sudo cp "${conf}" "${mnt}/boot/ab/verity-a.conf"
    sudo cp "${conf}" "${mnt}/boot/ab/verity-b.conf"
    sudo rm -f "${img}" "${conf}"

    # Record the kernel/initramfs baseline for slot A (RAUC state dir lives on
    # the data partition; arasaka-verify-boot compares these at boot).
    sha256sum "${mnt}/boot/vmlinuz-arasaka-a" | cut -d' ' -f1 | sudo tee "${mnt}/data/rauc/boot/A.kernel.sha256" >/dev/null
    sha256sum "${mnt}/boot/initramfs-arasaka-a.img" | cut -d' ' -f1 | sudo tee "${mnt}/data/rauc/boot/A.initrd.sha256" >/dev/null

    # Unmount everything
    log "Unmounting..."
    sudo umount -rf "${mnt}/boot-efi" 2>/dev/null || true
    sudo umount -rf "${mnt}/boot" 2>/dev/null || true
    sudo umount -rf "${mnt}/data" 2>/dev/null || true
    sudo rm -rf "$mnt"

    log "Installation complete!"
    log "Slot A is active. System will boot into COSMIC desktop."
    log "Updates are automatic via systemd timer."
}

main() {
    if [ $# -lt 1 ]; then
        usage
    fi

    local target="$1"

    if [ "$(id -u)" -ne 0 ]; then
        die "Must run as root (use sudo)"
    fi

    log "=== Arasaka Disk Installer ==="
    log "WARNING: This will DESTROY all data on ${target}!"
    read -rp "Type 'YES' to continue: " confirm
    if [ "$confirm" != "YES" ]; then
        die "Aborted by user"
    fi

    check_target "$target"

    read -ra parts <<< "$(partition_disk "$target")"
    install_rootfs "${parts[2]}" "${parts[3]}" "${parts[4]}"

    log "=== Installation complete! ==="
    log "Remove installation media and reboot."
}

main "$@"
