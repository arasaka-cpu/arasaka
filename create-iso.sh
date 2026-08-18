#!/usr/bin/env bash
# create-iso.sh
# Builds bootable live ISO with Calamares graphical installer.
# Dynamically detects latest kernel/initramfs.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)/build"
ROOTFS="${BUILD_DIR}/rootfs"
ISO_DIR="${BUILD_DIR}/iso"
OUTPUT="${BUILD_DIR}/arasaka-$(date '+%Y%m%d').iso"

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

log() { echo "[iso-builder] $*"; }
die() { log "FATAL: $*"; exit 1; }

[ -n "$PASSWORD" ] || die "Set ARASAKA_SUDO_PASSWORD or create build.conf (see build.conf.example)"

# Always pipe the password so sudo never prompts/locks mid-build.
run() { echo "$PASSWORD" | sudo -S "$@" 2>/dev/null; }
run_quiet() { echo "$PASSWORD" | sudo -S "$@" >/dev/null 2>&1; }
run_verbose() { echo "$PASSWORD" | sudo -S "$@"; }

# Write a heredoc to a file as root (works with << EOF).
# Usage: wtee /path/to/file << 'EOF' ... EOF
wtee() {
    local dest="$1"
    local tmp
    tmp=$(mktemp)
    cat > "$tmp"
    echo "$PASSWORD" | sudo -S cp "$tmp" "$dest" 2>/dev/null || true
    rm -f "$tmp"
}

# Lazily unmount every bind mount under a rootfs (proc/sys/dev/run plus the
# self-bind). Safe to run even when nothing is mounted. Needed before cp -a,
# mksquashfs and rm -rf so tools never recurse into a bind mount.
unmount_binds() {
    local root="$1"
    for mp in proc sys dev run; do
        echo "$PASSWORD" | sudo -S umount -lf "${root}/$mp" 2>/dev/null || true
    done
    echo "$PASSWORD" | sudo -S umount -lf "${root}" 2>/dev/null || true
}

# arch-chroot with proc/sys/dev/run bound and rootfs self-bind so pacman
# disk-space checks work. Usage: chroot_iso <root> <command...>
chroot_iso() {
    local root="$1"
    shift
    echo "$PASSWORD" | sudo -S mount --bind /proc "$root/proc" 2>/dev/null || true
    echo "$PASSWORD" | sudo -S mount --bind /sys "$root/sys" 2>/dev/null || true
    echo "$PASSWORD" | sudo -S mount --bind /dev "$root/dev" 2>/dev/null || true
    echo "$PASSWORD" | sudo -S mount --bind /run "$root/run" 2>/dev/null || true
    echo "$PASSWORD" | sudo -S mount --bind "$root" "$root" 2>/dev/null || true
    echo "$PASSWORD" | sudo -S arch-chroot "$root" "$@"
    local rc=$?
    echo "$PASSWORD" | sudo -S umount "$root" 2>/dev/null || true
    echo "$PASSWORD" | sudo -S umount "$root/run" 2>/dev/null || true
    echo "$PASSWORD" | sudo -S umount "$root/dev" 2>/dev/null || true
    echo "$PASSWORD" | sudo -S umount "$root/sys" 2>/dev/null || true
    echo "$PASSWORD" | sudo -S umount "$root/proc" 2>/dev/null || true
    return $rc
}

ensure_deps() {
    local deps=(archiso xorriso mtools dosfstools squashfs-tools)
    local missing=()
    for d in "${deps[@]}"; do
        command -v "$d" &>/dev/null || missing+=("$d")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log "Installing ISO build deps: ${missing[*]}"
        echo "$PASSWORD" | sudo -S pacman -S --needed --noconfirm "${missing[@]}"
    fi
}

detect_latest_kernel() {
    # All diagnostic output MUST go to stderr: the caller captures stdout
    # via $(detect_latest_kernel) and only the final "kname imgname" line
    # may appear on stdout. A stray log line here corrupts the boot entry.
    log_err() { echo "[iso-builder] $*" >&2; }

    log_err "Detecting latest kernel in rootfs..."

    local vmlinuz
    vmlinuz=$(run find "${ROOTFS}/boot" -maxdepth 1 -name 'vmlinuz*' -printf '%T@|%p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d'|' -f2- || true)

    if [ -z "$vmlinuz" ]; then
        for path in /boot/vmlinuz-linux /boot/vmlinuz-linux-lts /boot/vmlinuz-hardened; do
            if [ -f "${ROOTFS}${path}" ]; then
                vmlinuz="${ROOTFS}${path}"
                break
            fi
        done
    fi

    if [ -z "$vmlinuz" ] || [ ! -f "$vmlinuz" ]; then
        die "No kernel found in rootfs. Run build.sh first."
    fi

    local kname
    kname=$(basename "$vmlinuz")
    local imgname="initramfs${kname#vmlinuz}.img"

    log_err "Kernel: ${kname} | Initramfs: ${imgname}"
    echo "${kname}" "${imgname}"
}

prepare_iso_root() {
    log "Preparing ISO root filesystem with Calamares..."
    run_quiet rm -rf "${ISO_DIR}"
    mkdir -p "${ISO_DIR}"/{arch/x86_64,EFI/boot,loader/entries}

    # The source rootfs may carry leftover bind mounts (proc/sys/dev/run and a
    # self-bind) from interrupted arch-chroot runs. cp -a would recurse into
    # the self-bind mount forever and fill the disk, so unmount them first.
    # chroot_iso() re-mounts whatever it needs on the staging copy.
    log "Unmounting leftover binds on source rootfs..."
    unmount_binds "${ROOTFS}"

    # Copy rootfs
    log "Copying rootfs to ISO staging..."
    run_quiet cp -a "${ROOTFS}" "${ISO_DIR}/arch/x86_64/airootfs"

    # Calamares ships in the rootfs (built from the AUR by build.sh since it
    # left the official repos); nothing to install here. Just sanity-check.
    if [ ! -x "${ISO_DIR}/arch/x86_64/airootfs/usr/bin/calamares" ]; then
        die "calamares binary missing from rootfs - run build.sh first"
    fi
    log "Calamares installer present in rootfs."

    # Ship the Arasaka branding logo in the live environment
    log "Copying Arasaka branding into staging..."
    run_quiet mkdir -p "${ISO_DIR}/arch/x86_64/airootfs/usr/share/arasaka"
    if [ -f "$(dirname "$0")/branding/arasaka-logo.png" ]; then
        run_quiet cp "$(dirname "$0")/branding/arasaka-logo.png" \
            "${ISO_DIR}/arch/x86_64/airootfs/usr/share/arasaka/logo.png"
    fi

    # Create Calamares configuration for Arasaka
    log "Configuring Calamares for Arasaka A/B install..."
    run_quiet mkdir -p "${ISO_DIR}/arch/x86_64/airootfs/etc/calamares"
    run_quiet mkdir -p "${ISO_DIR}/arch/x86_64/airootfs/etc/calamares/modules"
    run_quiet mkdir -p "${ISO_DIR}/arch/x86_64/airootfs/etc/calamares/scripts"

    # Main Calamares config
    # NOTE: Calamares reads /etc/calamares/settings.conf, which build.sh
    # installs into the rootfs together with the module configs, branding and
    # the A/B postinstall script (config/calamares/ in this repo). Nothing
    # extra to stage here.

    # NOTE: unpackfs.conf, postinstall (shellprocess) and the A/B postinstall
    # script are all shipped by build.sh via the rootfs's /etc/calamares.
    # The installer auto-launches through the live user's COSMIC session
    # (home/user/.config/autostart), guarded by /run/archiso detection.

    # Create squashfs for live environment.
    # NOTE: this MUST run before the archiso initramfs is installed into
    # airootfs, so the squashfs ships the stock (non-archiso) initramfs and
    # the installed system boots normally from disk. The live boot uses the
    # archiso initramfs that lives in the ISO's top-level /boot, not the sfs.
    log "Creating squashfs for live env..."
    unmount_binds "${ISO_DIR}/arch/x86_64/airootfs"
    run mksquashfs "${ISO_DIR}/arch/x86_64/airootfs" \
        "${ISO_DIR}/arch/x86_64/airootfs.sfs" \
        -comp zstd -Xcompression-level 19 -b 1M -no-xattrs -noappend \
        -processors 6

    # pacman.conf for the live ISO
    wtee "${ISO_DIR}/arch/x86_64/pacman.conf" >/dev/null << 'PACEOF'
[options]
Architecture = x86_64
SigLevel = PackageRequired
LocalFileSigLevel = Optional
ParallelDownloads = 5
CacheDir = /var/cache/pacman/pkg

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist
PACEOF

    # Package list for live environment
    # Note: systemd-boot, systemd-resolved, systemd-networkd, systemd-oomd are
    # all bundled with the systemd package - do NOT list them separately.
    wtee "${ISO_DIR}/arch/x86_64/packages.x86_64" >/dev/null << 'PKGEOF'
base
linux
linux-firmware
systemd
cosmic
cosmic-applets
cosmic-launcher
cosmic-panel
cosmic-settings
cosmic-terminal
cosmic-text-editor
cosmic-randr
cosmic-greeter
cosmic-idle
xdg-desktop-portal-cosmic
uutils-coreutils
squashfs-tools
rsync
dosfstools
btrfs-progs
flatpak
calamares
bluez
bluez-utils
mesa
vulkan-intel
vulkan-radeon
libva-mesa-driver
xf86-video-intel
xf86-video-amdgpu
xf86-video-nouveau
apparmor
fuse3
cups
networkmanager
bash
sudo
git
base-devel
sbctl
systemd-ukify
sbsigntools
tpm2-tools
PKGEOF
}

build_bootloader() {
    log "Building systemd-boot loader..."

    local efi_dir="${ISO_DIR}/EFI/boot"
    run_quiet mkdir -p "${efi_dir}"

    local found=0
    for efi_path in \
        /usr/lib/systemd/boot/efi/systemd-bootx64.efi \
        /usr/lib/systemd/boot/efi/linuxx64.efi.stub \
        /boot/efi/EFI/systemd/systemd-bootx64.efi \
        /boot/EFI/systemd/systemd-bootx64.efi; do
        if [ -f "$efi_path" ]; then
            run_quiet cp "$efi_path" "${efi_dir}/BOOTX64.EFI"
            found=1
            break
        fi
    done

    if [ "$found" -eq 0 ]; then
        log "WARNING: systemd-boot EFI not found, installing..."
        echo "$PASSWORD" | sudo -S pacman -S --noconfirm systemd-boot
        run_quiet cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi "${efi_dir}/BOOTX64.EFI" 2>/dev/null || true
    fi

    read -r kname imgname <<< "$(detect_latest_kernel)"

    wtee "${ISO_DIR}/loader/loader.conf" >/dev/null << 'LOADEREOF'
default arasaka.conf
timeout 0
console-mode auto
editor no
LOADEREOF

    wtee "${ISO_DIR}/loader/entries/arasaka.conf" >/dev/null << ENTRYEOF
title   Arasaka Live (Calamares Installer)
linux   /boot/${kname}
initrd  /boot/${imgname}
options archisobasedir=arch archisolabel=ARASAKA console=ttyS0 console=tty0 quiet splash copytoram=n
ENTRYEOF

    wtee "${ISO_DIR}/loader/entries/arasaka-verbose.conf" >/dev/null << ENTRYEOF
title   Arasaka Live (Verbose Boot)
linux   /boot/${kname}
initrd  /boot/${imgname}
options archisobasedir=arch archisolabel=ARASAKA console=ttyS0 console=tty0 loglevel=7 drm.debug=0x02 copytoram=n
ENTRYEOF

    wtee "${ISO_DIR}/loader/entries/arasaka-safe.conf" >/dev/null << ENTRYEOF
title   Arasaka Live (Safe Graphics)
linux   /boot/${kname}
initrd  /boot/${imgname}
options archisobasedir=arch archisolabel=ARASAKA console=ttyS0 console=tty0 loglevel=7 nomodeset rd.systemd.unit=multi-user.target copytoram=n
ENTRYEOF
}

build_initramfs() {
    log "Building archiso live initramfs..."

    # The live system must mount rootfs.sfs from the ISO, which requires the
    # mkinitcpio-archiso hooks (archiso, archiso_loop_mnt, ...). The hooks
    # ship in the base rootfs (build.sh installs mkinitcpio-archiso); install
    # here only as a fallback in case they are missing.
    if [ ! -e "${ISO_DIR}/arch/x86_64/airootfs/usr/lib/initcpio/hooks/archiso" ]; then
        log "Installing mkinitcpio-archiso into ISO staging..."
        chroot_iso "${ISO_DIR}/arch/x86_64/airootfs" /bin/bash -c '
            pacman -S --noconfirm --needed mkinitcpio-archiso 2>&1 || true
        ' 2>&1 || true
    else
        log "archiso hooks already present in staging."
    fi

    # archiso hook set (mirrors the releng profile, minus memdisk which needs
    # the memdiskfind binary from syslinux that we do not ship)
    run_quiet mkdir -p "${ISO_DIR}/arch/x86_64/airootfs/etc/mkinitcpio.conf.d"
    wtee "${ISO_DIR}/arch/x86_64/airootfs/etc/mkinitcpio.conf.d/archiso.conf" >/dev/null << 'ARCHISOCONF'
MODULES=(loop squashfs nouveau i915 amdgpu virtio-gpu virtio-drm)
HOOKS=(base udev plymouth microcode modconf kms archiso archiso_loop_mnt archiso_pxe_common archiso_pxe_nbd archiso_pxe_http archiso_pxe_nfs block filesystems keyboard)
ARCHISOCONF

    # Preset that builds the archiso initramfs into /boot/initramfs-linux.img
    run_quiet mkdir -p "${ISO_DIR}/arch/x86_64/airootfs/etc/mkinitcpio.d"
    wtee "${ISO_DIR}/arch/x86_64/airootfs/etc/mkinitcpio.d/linux.preset" >/dev/null << 'ARCHISOPRESET'
# mkinitcpio preset file for the 'linux' package on archiso
PRESETS=('archiso')
ALL_kver='/boot/vmlinuz-linux'
archiso_config='/etc/mkinitcpio.conf.d/archiso.conf'
archiso_image="/boot/initramfs-linux.img"
ARCHISOPRESET

    chroot_iso "${ISO_DIR}/arch/x86_64/airootfs" /bin/bash -c '
        mkinitcpio -P 2>&1
    ' 2>&1 || log "mkinitcpio failed, using host initramfs"

    read -r kname imgname <<< "$(detect_latest_kernel)"

    local src_kernel="${ROOTFS}/boot/${kname}"
    local src_initrd="${ROOTFS}/boot/${imgname}"
    local dst_kernel="${ISO_DIR}/arch/x86_64/airootfs/boot/${kname}"
    local dst_initrd="${ISO_DIR}/arch/x86_64/airootfs/boot/${imgname}"

    if [ ! -f "$dst_kernel" ] && [ -f "$src_kernel" ]; then
        run_quiet cp "$src_kernel" "$dst_kernel"
    fi
    if [ ! -f "$dst_initrd" ] && [ -f "$src_initrd" ]; then
        run_quiet cp "$src_initrd" "$dst_initrd"
    fi

    if [ ! -f "$dst_kernel" ]; then
        run_quiet cp "/boot/${kname}" "$dst_kernel" 2>/dev/null || \
        run_quiet cp /boot/vmlinuz-linux "$dst_kernel" 2>/dev/null || true
    fi
    if [ ! -f "$dst_initrd" ]; then
        run_quiet cp "/boot/${imgname}" "$dst_initrd" 2>/dev/null || \
        run_quiet cp /boot/initramfs-linux.img "$dst_initrd" 2>/dev/null || true
    fi

    if [ ! -f "$dst_kernel" ]; then
        die "Could not find kernel ${kname} anywhere"
    fi
    log "Kernel: ${kname} | Initramfs: ${imgname}"
}

# Build the FAT efiboot.img that OVMF mounts via the El Torito EFI entry.
# systemd-boot treats this image as its ESP: it must contain /EFI/BOOT/
# BOOTX64.EFI, /loader/loader.conf, /loader/entries/*.conf AND the kernel +
# initramfs it loads. Runs after build_initramfs so the archiso initramfs and
# kernel are already present.
build_efiboot() {
    log "Building FAT efiboot.img (ESP)..."
    read -r kname imgname <<< "$(detect_latest_kernel)"

    local efi_dir="${ISO_DIR}/EFI/boot"
    local efi_img="${efi_dir}/efiboot.img"
    local ksrc="${ISO_DIR}/arch/x86_64/airootfs/boot/${kname}"
    local isrc="${ISO_DIR}/arch/x86_64/airootfs/boot/${imgname}"
    [ -f "$ksrc" ] || ksrc="${ROOTFS}/boot/${kname}"
    [ -f "$isrc" ] || isrc="${ROOTFS}/boot/${imgname}"

    local ksize isize
    ksize=$(stat -c %s "$ksrc" 2>/dev/null || echo 20)
    isize=$(stat -c %s "$isrc" 2>/dev/null || echo 10)
    # image = bootloader + kernel + initramfs + slack
    local img_size=$(( (ksize + isize + 32 * 1024 * 1024) / 1048576 ))
    [ "$img_size" -lt 64 ] && img_size=64

    run_quiet rm -f "$efi_img"
    run_quiet truncate -s "${img_size}M" "$efi_img"
    run_quiet mkfs.fat -F 32 -n ARASAKA "$efi_img"
    run_quiet mmd -i "$efi_img" ::/EFI
    run_quiet mmd -i "$efi_img" ::/EFI/BOOT
    run_quiet mcopy -i "$efi_img" "${efi_dir}/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI

    local tmpdir tmp
    tmpdir=$(mktemp -d)
    mkdir -p "${tmpdir}/loader/entries"
    wtee "${tmpdir}/loader/loader.conf" >/dev/null << 'LOADEREOF'
default arasaka.conf
timeout 0
console-mode auto
editor no
LOADEREOF
    wtee "${tmpdir}/loader/entries/arasaka.conf" >/dev/null << ENTRYEOF
title   Arasaka Live (Calamares Installer)
linux   /boot/${kname}
initrd  /boot/${imgname}
options archisobasedir=arch archisolabel=ARASAKA console=ttyS0 console=tty0 quiet splash copytoram=n
ENTRYEOF
    wtee "${tmpdir}/loader/entries/arasaka-verbose.conf" >/dev/null << ENTRYEOF
title   Arasaka Live (Verbose Boot)
linux   /boot/${kname}
initrd  /boot/${imgname}
options archisobasedir=arch archisolabel=ARASAKA console=ttyS0 console=tty0 loglevel=7 drm.debug=0x02 copytoram=n
ENTRYEOF
    wtee "${tmpdir}/loader/entries/arasaka-safe.conf" >/dev/null << ENTRYEOF
title   Arasaka Live (Safe Graphics)
linux   /boot/${kname}
initrd  /boot/${imgname}
options archisobasedir=arch archisolabel=ARASAKA console=ttyS0 console=tty0 loglevel=7 nomodeset rd.systemd.unit=multi-user.target copytoram=n
ENTRYEOF
    run_quiet mmd -i "$efi_img" ::/loader
    run_quiet mmd -i "$efi_img" ::/loader/entries
    run_quiet mcopy -i "$efi_img" "${tmpdir}/loader/loader.conf" ::/loader/loader.conf
    run_quiet mcopy -i "$efi_img" "${tmpdir}/loader/entries/arasaka.conf" ::/loader/entries/arasaka.conf
    run_quiet mcopy -i "$efi_img" "${tmpdir}/loader/entries/arasaka-verbose.conf" ::/loader/entries/arasaka-verbose.conf
    run_quiet mcopy -i "$efi_img" "${tmpdir}/loader/entries/arasaka-safe.conf" ::/loader/entries/arasaka-safe.conf
    run_quiet mmd -i "$efi_img" ::/boot
    run_quiet mcopy -i "$efi_img" "$ksrc" "::/boot/${kname}"
    run_quiet mcopy -i "$efi_img" "$isrc" "::/boot/${imgname}"
    rm -rf "$tmpdir"

    log "Created EFI boot image (${img_size}M): ${efi_img}"
}

build_iso() {
    log "Building ISO image..."

    # Move kernel + initramfs out of the raw airootfs to top-level /boot,
    # then delete the uncompressed rootfs so the ISO only ships the squashfs.
    read -r kname imgname <<< "$(detect_latest_kernel)"
    run_quiet mkdir -p "${ISO_DIR}/boot"
    run_quiet cp "${ISO_DIR}/arch/x86_64/airootfs/boot/${kname}" "${ISO_DIR}/boot/${kname}" 2>/dev/null || \
    run_quiet cp "${ROOTFS}/boot/${kname}" "${ISO_DIR}/boot/${kname}" 2>/dev/null || true
    run_quiet cp "${ISO_DIR}/arch/x86_64/airootfs/boot/${imgname}" "${ISO_DIR}/boot/${imgname}" 2>/dev/null || \
    run_quiet cp "${ROOTFS}/boot/${imgname}" "${ISO_DIR}/boot/${imgname}" 2>/dev/null || true

    log "Removing uncompressed airootfs from ISO staging..."
    unmount_binds "${ISO_DIR}/arch/x86_64/airootfs"
    run_quiet rm -rf "${ISO_DIR}/arch/x86_64/airootfs"

    local efi_load_size
    efi_load_size=$(( ($(stat -c %s "${ISO_DIR}/EFI/boot/efiboot.img") + 511) / 512 ))

    run_verbose xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "ARASAKA" \
        -output "${OUTPUT}" \
        -eltorito-boot EFI/boot/BOOTX64.EFI \
            -no-emul-boot \
            -boot-load-size 4096 \
            -boot-info-table \
            --eltorito-catalog EFI/boot/cat.txt \
        -eltorito-alt-boot \
            -e EFI/boot/efiboot.img \
            -no-emul-boot \
            -boot-load-size "${efi_load_size}" \
        "${ISO_DIR}"

    local iso_size_final
    iso_size_final=$(du -sb "${OUTPUT}" | cut -f1)
    log "ISO built: $(( iso_size_final / 1024 / 1024 )) MB - ${OUTPUT}"
}

main() {
    log "=== Arasaka ISO Builder ==="
    log "Live boot -> Calamares graphical installer -> Immutable A/B disk"
    ensure_deps
    prepare_iso_root
    build_bootloader
    build_initramfs
    build_efiboot
    build_iso
    log "=== ISO complete: ${OUTPUT} ==="
    log "Boot from this ISO. Calamares launches automatically."
    log "It will partition disk with A/B immutable layout and install."
}

main "$@"
