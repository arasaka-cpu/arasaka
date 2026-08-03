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
  Partition 3: Slot A root (20GB, squashfs container)
  Partition 4: Slot B root (20GB, squashfs container)
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

    # Partition 2: Boot (1GB)
    echo "$PASSWORD" | sudo -S sgdisk --new=2:0:+1G --typecode=2:8300 --change-name=2:"boot" "$target"

    # Partition 3: Slot A (20GB)
    echo "$PASSWORD" | sudo -S sgdisk --new=3:0:+20G --typecode=3:8300 --change-name=3:"slot-a" "$target"

    # Partition 4: Slot B (20GB)
    echo "$PASSWORD" | sudo -S sgdisk --new=4:0:+20G --typecode=4:8300 --change-name=4:"slot-b" "$target"

    # Partition 5: Data (remaining)
    echo "$PASSWORD" | sudo -S sgdisk --new=5:0:0 --typecode=5:8300 --change-name=5:"data" "$target"

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

    # Format partitions
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
    sudo btrfs subvolume create "${mnt}/data/@systemd" 2>/dev/null || true
    sudo btrfs subvolume create "${mnt}/data/@log" 2>/dev/null || true
    sudo btrfs subvolume create "${mnt}/data/@cache" 2>/dev/null || true
    sudo btrfs subvolume create "${mnt}/data/@home" 2>/dev/null || true

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

    # Create the squashfs image
    log "Creating immutable squashfs image..."
    sudo mksquashfs "${mnt}/slot-a" "${mnt}/slot-a/arasaka-rootfs.sfs" \
        -comp zstd -Xcompression-level 19 -b 1M -no-xattrs -noappend

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

    # Slot A boot entry (dynamic kernel)
    sudo tee "${mnt}/boot/loader/entries/arasaka-a.conf" >/dev/null << AEOF
title   Arasaka (Slot A)
linux   /${kname}
initrd  /${imgname}
options root=/dev/disk/by-label/arasaka-slot-a rw
AEOF

    # Slot B boot entry (dynamic kernel)
    sudo tee "${mnt}/boot/loader/entries/arasaka-b.conf" >/dev/null << BEOF
title   Arasaka (Slot B)
linux   /${kname}
initrd  /${imgname}
options root=/dev/disk/by-label/arasaka-slot-b rw
BEOF

    # Copy kernel and initramfs to boot
    sudo cp "${ROOTFS}/boot/${kname}" "${mnt}/boot/" 2>/dev/null || \
        sudo cp /boot/${kname} "${mnt}/boot/" 2>/dev/null || \
        sudo cp /boot/vmlinuz-linux "${mnt}/boot/"
    sudo cp "${ROOTFS}/boot/${imgname}" "${mnt}/boot/" 2>/dev/null || \
        sudo cp /boot/${imgname} "${mnt}/boot/" 2>/dev/null || \
        sudo cp /boot/initramfs-linux.img "${mnt}/boot/"

    # Set initial active slot
    echo "a" | sudo tee "${mnt}/boot/ab/active-slot" >/dev/null

    # Copy squashfs to boot/ab
    sudo cp "${mnt}/slot-a/arasaka-rootfs.sfs" "${mnt}/boot/ab/arasaka-rootfs.sfs"

    # Create fstab for the installed system
    sudo tee "${mnt}/slot-a/etc/fstab" >/dev/null << FSTABEOF
# Arasaka fstab - systemd manages mounts
/dev/disk/by-label/arasaka-boot    /boot           ext4    defaults,noatime 0 2
/dev/disk/by-label/arasaka-data    /               btrfs   defaults,noatime,compress=zstd 0 1
/dev/disk/by-label/EFI              /boot/efi       vfat    defaults,noatime 0 2
FSTABEOF

    # Copy install scripts to the installed system
    sudo cp "$(dirname "$0")/scripts/"*.sh "${mnt}/slot-a/usr/local/bin/" 2>/dev/null || true
    sudo chmod +x "${mnt}/slot-a/usr/local/bin/"*.sh 2>/dev/null || true

    # Unmount everything
    log "Unmounting..."
    sudo umount -rf "${mnt}/boot-efi" 2>/dev/null || true
    sudo umount -rf "${mnt}/boot" 2>/dev/null || true
    sudo umount -rf "${mnt}/slot-a" 2>/dev/null || true
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
