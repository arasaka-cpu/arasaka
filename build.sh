#!/usr/bin/env bash
# build.sh - Arasaka Rootfs Builder
# Immutable A/B COSMIC | uutils ONLY (GNU coreutils purged) | flatpak+bazaar
# systemd-everything | bluetooth | mesa | apparmor+snap | cups | weekly update
set -euo pipefail

NAME="arasaka"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)/build"
ROOTFS="${BUILD_DIR}/rootfs"

# Sudo password is NEVER hardcoded in this repo. Provide it via the
# $ARASAKA_SUDO_PASSWORD environment variable or a local build.conf file
# (gitignored; see build.conf.example).
if [ -n "${ARASAKA_SUDO_PASSWORD:-}" ]; then
    PASSWORD="$ARASAKA_SUDO_PASSWORD"
elif [ -f "$(dirname "$0")/build.conf" ]; then
    # shellcheck disable=SC1091
    . "$(dirname "$0")/build.conf"
    PASSWORD="${ARASAKA_SUDO_PASSWORD:-}"
else
    PASSWORD=""
fi

log() { echo "[arasaka] $(date '+%H:%M:%S') $*"; }
die() { log "FATAL: $*"; exit 1; }

[ -n "$PASSWORD" ] || die "Set ARASAKA_SUDO_PASSWORD or create build.conf (see build.conf.example)"

# Always pipe the password so sudo never prompts/locks mid-build.
# Usage: run sudo cmd arg1 arg2 ...
run() {
    echo "$PASSWORD" | sudo -S "$@" 2>/dev/null
}

# Like run() but keeps stderr (for long builds where we need failure output).
run_verbose() {
    echo "$PASSWORD" | sudo -S "$@"
}

run_quiet() {
    echo "$PASSWORD" | sudo -S "$@" >/dev/null 2>&1
}

check_host() {
    if [ "$(id -u)" -eq 0 ]; then
        die "Do not run as root. Uses sudo internally."
    fi
    if ! command -v pacman &>/dev/null; then
        die "This script must run on Arch Linux (pacman not found)"
    fi
    log "Host: Arch Linux confirmed"
}

ensure_deps() {
    local deps=(pacman arch-install-scripts squashfs-tools dosfstools parted
                efibootmgr btrfs-progs e2fsprogs)
    local missing=()
    for d in "${deps[@]}"; do
        command -v "$d" &>/dev/null || missing+=("$d")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log "Installing host deps: ${missing[*]}"
        echo "$PASSWORD" | sudo -S pacman -S --needed --noconfirm "${missing[@]}"
    fi
}

clean() {
    log "Cleaning previous build..."
    run_quiet rm -rf "${BUILD_DIR}"
    mkdir -p "${ROOTFS}"
}

strap() {
    log "Strapping Arch rootfs..."

    run pacstrap -K "${ROOTFS}" \
        base \
        linux \
        linux-firmware \
        systemd \
        udev \
        iana-etc \
        networkmanager \
        flatpak \
        dconf \
        xdg-desktop-portal-cosmic \
        cosmic \
        cosmic-applets \
        cosmic-launcher \
        cosmic-panel \
        cosmic-settings \
        cosmic-terminal \
        cosmic-text-editor \
        cosmic-randr \
        cosmic-greeter \
        cosmic-idle \
        cage \
        uutils-coreutils \
        mkinitcpio-archiso \
        nbd \
        mkinitcpio-nfs-utils \
        squashfs-tools \
        rsync \
        zram-generator \
        dosfstools \
        btrfs-progs \
        xcb-util-cursor \
        bluez \
        bluez-utils \
        mesa \
        vulkan-intel \
        vulkan-radeon \
        vulkan-nouveau \
        opencl-mesa \
        ocl-icd \
        libva-mesa-driver \
        xf86-video-intel \
        xf86-video-amdgpu \
        xf86-video-nouveau \
        plymouth \
        apparmor \
        fuse3 \
        rauc \
        desync \
        cups \
        foomatic-db \
        ghostscript \
        gutenprint \
        bash \
        sudo \
        terminus-font \
        ttf-dejavu \
        noto-fonts \
        noto-fonts-emoji \
        git \
        base-devel

    # The rootfs's own pacman.conf (shipped by the base package) has
    # CheckSpace enabled. Inside a chroot pacman cannot resolve the
    # cachedir's mount point, so its space check always fails. Disable it
    # for all later arch-chroot pacman calls (build-time only - the rootfs
    # is squashfs'd into the ISO, never booted directly).
    run_quiet sed -i 's/^CheckSpace/#CheckSpace/' "${ROOTFS}/etc/pacman.conf"

    # NOTE: purge_gnu_coreutils is called from main() LAST, after the AUR
    # builds. On a fresh build the chroot still has GNU coreutils for makepkg;
    # on a resume build the plain-named uutils hard links satisfy makepkg, so
    # GNU coreutils is never restored.
}

purge_gnu_coreutils() {
    log "PURGING GNU coreutils - uutils takes over forever..."

    run arch-chroot "${ROOTFS}" /bin/bash -c '
        # Create uutils symlinks FIRST (while GNU rm/ln still exist),
        # then purge GNU coreutils so pacman removes the old binaries.
        # Any symlink we created is not owned by pacman, so it survives.

        for cmd in base64 basename cat chcon chmod chown chroot cksum comm cp csplit \
                   cut date dd df dir dircolors dirname du echo env expand expr factor \
                   false fmt fold groups head hostid id install join link ln logname \
                   ls md5sum mkdir mkfifo mknod mktemp mv nice nl nohup nproc numfmt od \
                   paste pathchk pinky pr printenv printf ptx pwd readlink realpath \
                   rm rmdir runcon seq sha1sum sha224sum sha256sum sha384sum sha512sum \
                   shred shuf sleep sort split stat stdbuf stty sum sync tac tail \
                   tee test timeout touch tr true truncate tsort tty uname unexpand \
                   uniq unlink uptime users vdir wc who whoami yes; do
            if [ -f "/usr/bin/uu-${cmd}" ]; then
                /usr/bin/uu-rm -f "/usr/bin/${cmd}" 2>/dev/null || true
                /usr/bin/uu-ln -sf "uu-${cmd}" "/usr/bin/${cmd}" 2>/dev/null || true
            fi
        done

        # Verify every symlink got created
        missing=0
        for cmd in ls cat cp rm mv mkdir df du echo sleep head tail date; do
            if [ ! -e "/usr/bin/${cmd}" ]; then
                echo "WARNING: /usr/bin/${cmd} missing after symlink phase"
                missing=1
            fi
        done

        # Now purge GNU coreutils (old binaries removed, our symlinks remain)
        pacman -Rdd --noconfirm coreutils 2>/dev/null || true

        # findutils: uutils-findutils (built from AUR by build_aur_findutils)
        # is the drop-in replacement. Link the uu- prefixed binaries into place
        # BEFORE removing GNU findutils so nothing breaks mid-purge, then purge.
        # uutils-findutils ships uu-find, uu-xargs, uu-locate, uu-updatedb.
        for cmd in find xargs locate updatedb; do
            if [ -f "/usr/bin/uu-${cmd}" ]; then
                /usr/bin/uu-rm -f "/usr/bin/${cmd}" 2>/dev/null || true
                /usr/bin/uu-ln -sf "uu-${cmd}" "/usr/bin/${cmd}" 2>/dev/null || true
            fi
        done
        pacman -Rdd --noconfirm findutils 2>/dev/null || true

        # Phase 3: turn the uu-* symlinks into plain hard links. A hard link is
        # a REAL file named exactly like the GNU tool (/usr/bin/find, /usr/bin/ls),
        # so `readlink -f` and /proc/self/exe resolve to the GNU name - apps that
        # sniff the executable name detect GNU coreutils/findutils, not a "uu-*"
        # file. The uu-* originals must stay (pacman owns them); the hard links
        # are unowned and live on the same filesystem.
        for cmd in base64 basename cat chcon chmod chown chroot cksum comm cp csplit \
                   cut date dd df dir dircolors dirname du echo env expand expr factor \
                   false fmt fold groups head hostid id install join link ln logname \
                   ls md5sum mkdir mkfifo mknod mktemp mv nice nl nohup nproc numfmt od \
                   paste pathchk pinky pr printenv printf ptx pwd readlink realpath \
                   rm rmdir runcon seq sha1sum sha224sum sha256sum sha384sum sha512sum \
                   shred shuf sleep sort split stat stdbuf stty sum sync tac tail \
                   tee test timeout touch tr true truncate tsort tty uname unexpand \
                   uniq unlink uptime users vdir wc who whoami yes coreutils; do
            if [ -f "/usr/bin/uu-${cmd}" ]; then
                /usr/bin/uu-rm -f "/usr/bin/${cmd}" 2>/dev/null || true
                /usr/bin/uu-ln "/usr/bin/uu-${cmd}" "/usr/bin/${cmd}" 2>/dev/null || true
            fi
        done
        for cmd in find xargs locate updatedb; do
            if [ -f "/usr/bin/uu-${cmd}" ]; then
                /usr/bin/uu-rm -f "/usr/bin/${cmd}" 2>/dev/null || true
                /usr/bin/uu-ln "/usr/bin/uu-${cmd}" "/usr/bin/${cmd}" 2>/dev/null || true
            fi
        done

        # NOTE: grep/sed/gawk/diffutils are KEPT - uutils has no
        # replacements for them (grep/sed are separate uutils projects
        # not in official Arch repos). Removing them would break systemd.

        # Make sure bash still works (it has its own builtins)
        # bash is needed as the shell, but it uses its own builtins not GNU

        echo "GNU coreutils purge complete. uutils is the law now."
    '

    log "GNU coreutils + findutils eliminated. All hail uutils."
}

build_aur_calamares() {
    if [ -x "${ROOTFS}/usr/bin/calamares" ]; then
        log "Calamares already installed - skipping AUR build"
        return
    fi
    log "Building Calamares (AUR-only since it left the official repos)..."

    # The chroot may already be purged on a resume run; the plain-named uutils
    # hard links (ls, cat, rm, ...) satisfy makepkg, so never restore GNU
    # coreutils.
    run arch-chroot "${ROOTFS}" pacman -S --needed --noconfirm \
        kcoreaddons kpmcore libpwquality qt6-declarative qt6-svg yaml-cpp \
        extra-cmake-modules libglvnd ninja qt6-tools qt6-translations

    run arch-chroot "${ROOTFS}" /bin/bash -c 'id builder &>/dev/null || useradd -s /bin/bash builder; mkdir -p /home/builder && chown builder:builder /home/builder'

    local srcdir
    srcdir="$(realpath "$(dirname "$0")")/aur/calamares"
    run_quiet mkdir -p "${ROOTFS}/home/builder/calamares"
    run_quiet cp "${srcdir}"/PKGBUILD "${srcdir}"/0001-*.patch "${ROOTFS}/home/builder/calamares/" 2>/dev/null
    run arch-chroot "${ROOTFS}" chown -R builder:builder /home/builder

    run arch-chroot "${ROOTFS}" sudo -u builder bash -c \
        'cd /home/builder/calamares && makepkg --noconfirm --force'
    run arch-chroot "${ROOTFS}" bash -c \
        'cd /home/builder/calamares && pacman -U --noconfirm calamares-*.pkg.tar.zst'

    # Compile the UI translations (the AUR package ships only the branding
    # translations, so the installer language selector would otherwise be
    # English-only) and copy them into place.
    run arch-chroot "${ROOTFS}" /bin/bash -c '
        mkdir -p /usr/share/calamares/translations
        cd /home/builder/calamares/src/calamares-*/lang
        for f in calamares_*.ts; do
            /usr/lib/qt6/bin/lrelease "$f" \
                -qm "/usr/share/calamares/translations/${f%.ts}.qm" >/dev/null 2>&1
        done
    '

    # Drop build scaffolding
    run arch-chroot "${ROOTFS}" bash -c 'rm -rf /home/builder'
    log "Calamares installed."
}

build_aur_snapd() {
    if [ -x "${ROOTFS}/usr/bin/snap" ]; then
        log "snapd already installed - skipping AUR build"
        return
    fi
    log "Building snapd (AUR-only since it left the official repos)..."

    # The chroot may already be purged on a resume run; the plain-named uutils
    # hard links (ls, cat, rm, ...) satisfy makepkg, so never restore GNU
    # coreutils.
    run arch-chroot "${ROOTFS}" pacman -S --needed --noconfirm \
        git go go-tools libseccomp libcap systemd xfsprogs \
        python-docutils apparmor autoconf-archive m4 squashfs-tools

    run arch-chroot "${ROOTFS}" /bin/bash -c 'id builder &>/dev/null || useradd -s /bin/bash builder; mkdir -p /home/builder && chown builder:builder /home/builder'

    local srcdir
    srcdir="$(realpath "$(dirname "$0")")/aur/snapd"
    run_quiet mkdir -p "${ROOTFS}/home/builder/snapd"
    run_quiet cp "${srcdir}"/PKGBUILD "${srcdir}"/snapd.install "${ROOTFS}/home/builder/snapd/" 2>/dev/null
    run arch-chroot "${ROOTFS}" chown -R builder:builder /home/builder

    run arch-chroot "${ROOTFS}" sudo -u builder bash -c \
        'cd /home/builder/snapd && makepkg --noconfirm --force'
    run arch-chroot "${ROOTFS}" bash -c \
        'cd /home/builder/snapd && pacman -U --noconfirm snapd-*.pkg.tar.zst'

    # snapd's runtime deps (squashfs-tools, libseccomp, libcap, apparmor,
    # libsystemd) stay; the Go toolchain and the build-only makedeps are
    # several hundred MB and are not needed at runtime.
    run arch-chroot "${ROOTFS}" pacman -Rdd --noconfirm \
        go go-tools xfsprogs python-docutils autoconf-archive m4 2>/dev/null || true

    # Drop build scaffolding (keeps go/compiler out of the final image).
    run arch-chroot "${ROOTFS}" bash -c 'rm -rf /home/builder'
    log "snapd installed."
}

build_aur_findutils() {
    if [ -x "${ROOTFS}/usr/bin/uu-find" ]; then
        log "uutils-findutils already installed - skipping AUR build"
        return
    fi
    log "Building uutils-findutils (AUR-only, replaces GNU findutils)..."

    # The chroot may already be purged on a resume run; the plain-named uutils
    # hard links (ls, cat, rm, ...) satisfy makepkg, so never restore GNU
    # coreutils.
    run arch-chroot "${ROOTFS}" pacman -S --needed --noconfirm \
        rust oniguruma

    run arch-chroot "${ROOTFS}" /bin/bash -c 'id builder &>/dev/null || useradd -s /bin/bash builder; mkdir -p /home/builder && chown builder:builder /home/builder'
    log "builder user ready - running makepkg (uutils-findutils)..."

    local srcdir
    srcdir="$(realpath "$(dirname "$0")")/aur/findutils"
    run_quiet mkdir -p "${ROOTFS}/home/builder/findutils"
    run_quiet cp "${srcdir}"/PKGBUILD "${ROOTFS}/home/builder/findutils/"
    run arch-chroot "${ROOTFS}" chown -R builder:builder /home/builder

    run_verbose arch-chroot "${ROOTFS}" sudo -u builder bash -c \
        'cd /home/builder/findutils && makepkg --noconfirm --force'
    run arch-chroot "${ROOTFS}" bash -c \
        'cd /home/builder/findutils && pacman -U --noconfirm uutils-findutils-*.pkg.tar.zst'

    # The Rust toolchain is build-only and several hundred MB - drop it.
    # oniguruma stays (uutils-findutils links it dynamically).
    run arch-chroot "${ROOTFS}" pacman -Rdd --noconfirm \
        rust 2>/dev/null || true

    # Drop build scaffolding (keeps compiler out of the final image).
    run arch-chroot "${ROOTFS}" bash -c 'rm -rf /home/builder'
    log "uutils-findutils installed."
}

build_aur_system76power() {
    if [ -x "${ROOTFS}/usr/bin/system76-power" ]; then
        log "system76-power already installed - skipping AUR build"
        return
    fi
    log "Building system76-power (AUR-only, power profiles + graphics switching)..."

    # The chroot may already be purged on a resume run; the plain-named uutils
    # hard links (ls, cat, rm, ...) satisfy makepkg, so never restore GNU
    # coreutils.
    run arch-chroot "${ROOTFS}" pacman -S --needed --noconfirm \
        dbus libusb polkit rust

    run arch-chroot "${ROOTFS}" /bin/bash -c 'id builder &>/dev/null || useradd -s /bin/bash builder; mkdir -p /home/builder && chown builder:builder /home/builder'
    log "builder user ready - running makepkg (system76-power)..."

    local srcdir
    srcdir="$(realpath "$(dirname "$0")")/aur/system76-power"
    run_quiet mkdir -p "${ROOTFS}/home/builder/system76-power"
    run_quiet cp "${srcdir}"/PKGBUILD "${srcdir}"/system76-power.install \
       "${srcdir}"/use-mkinitcpio.patch "${ROOTFS}/home/builder/system76-power/"
    run arch-chroot "${ROOTFS}" chown -R builder:builder /home/builder

    run_verbose arch-chroot "${ROOTFS}" sudo -u builder bash -c \
        'cd /home/builder/system76-power && makepkg --noconfirm --force'
    run arch-chroot "${ROOTFS}" bash -c \
        'cd /home/builder/system76-power && pacman -U --noconfirm system76-power-*.pkg.tar.zst'

    # Rust toolchain is build-only - drop it.
    run arch-chroot "${ROOTFS}" pacman -Rdd --noconfirm \
        rust 2>/dev/null || true

    # Drop build scaffolding (keeps compiler out of the final image).
    run arch-chroot "${ROOTFS}" bash -c 'rm -rf /home/builder'
    log "system76-power installed."
}

configure_bluetooth() {
    log "Configuring Bluetooth..."
    run arch-chroot "${ROOTFS}" /bin/bash -c '
        systemctl enable bluetooth
    '
}

configure_mesa() {
    log "Configuring Mesa GPU drivers..."
    run arch-chroot "${ROOTFS}" /bin/bash -c '
        # RESUME builds reuse a rootfs whose pacman DB may predate the current
        # mirror state (e.g. opencl-mesa pulls spirv-llvm-translator, and a
        # stale DB can pin a version the mirrors have already dropped). Refresh
        # the package lists once up front so every install below resolves.
        pacman -Syy --noconfirm >/dev/null 2>&1 || true

        # NVK (NVIDIA Vulkan) ships as a separate package on Arch. Install it if
        # missing - RESUME builds skip pacstrap, so the package list entry alone
        # would never get installed.
        if [ ! -e /usr/share/vulkan/icd.d/nouveau_icd.json ]; then
            echo "vulkan-nouveau (NVK) missing - installing..."
            pacman -S --needed --noconfirm vulkan-nouveau 2>&1 || true
        fi

        # OpenCL for Mesa (RustiCL). opencl-mesa ships the RustiCL driver,
        # ocl-icd is the ICD loader that exposes it to clinfo/hashcat/etc.
        # RUSTICL_ENABLE is a comma-separated driver list with NO wildcard
        # (Mesa parses it literally, so "*" would match nothing and OpenCL
        # would stay disabled); list every Gallium driver we ship that
        # RustiCL supports. nouveau = this machine (GTX 1660 SUPER),
        # radeonsi/r600/iris cover AMD/Intel, llvmpipe = software fallback.
        if [ ! -e /usr/lib/libclc.so ] || ! pacman -Q opencl-mesa >/dev/null 2>&1; then
            echo "opencl-mesa (RustiCL) missing - installing..."
            pacman -S --needed --noconfirm opencl-mesa ocl-icd 2>&1 || true
        fi

        # zink is Mesa'\''s GL-on-Vulkan driver and ships inside mesa itself.
        # Since Mesa 25.1, nouveau on Turing+ GPUs auto-selects Zink-on-NVK
        # for OpenGL when the NVK ICD is present (which we now install above),
        # so a Zink drirc/env override is neither needed nor desired - the
        # loader picks zink_dri.so automatically once NVK is available.
        if [ -f /usr/lib/dri/zink_dri.so ]; then
            echo "zink_dri.so present - Zink-on-NVK is automatic for Turing+"
        else
            echo "WARNING: zink_dri.so missing from mesa"
        fi

        cat > /etc/udev/rules.d/99-gpu.rules << "GPUEOF"
KERNEL=="card*", SUBSYSTEM=="drm", GROUP="video", MODE="0660", TAG+="uaccess"
KERNEL=="renderD*", SUBSYSTEM=="drm", GROUP="render", MODE="0660", TAG+="uaccess"
GPUEOF
        groupadd -f render
        groupadd -f video
        # Greeter users also render (greeter wallpaper/animations); grant them
        # render access too. The live/installed desktop user gets it via
        # usermod in configure_live_autologin / Calamares defaultGroups.
        usermod -aG render greeter 2>/dev/null || true
        usermod -aG render cosmic-greeter 2>/dev/null || true

        # Let RustiCL see every GPU by default (overridable per-user).
        mkdir -p /etc/environment.d
        cat > /etc/environment.d/90-mesa.conf << "MESAENV"
RUSTICL_ENABLE=nouveau,radeonsi,r600,iris,llvmpipe
MESAENV
    '
}

configure_plymouth() {
    log "Configuring Plymouth boot splash..."
    run arch-chroot "${ROOTFS}" /bin/bash -c '
        if ! pacman -Q plymouth >/dev/null 2>&1; then
            echo "plymouth missing - installing..."
            pacman -S --needed --noconfirm plymouth 2>&1 || true
        fi

        # Custom Arasaka theme (files are staged by build.sh into the rootfs
        # before this runs, via the themes/ dir next to this script).
        if [ -d /usr/share/plymouth/themes/arasaka ]; then
            mkdir -p /etc/plymouth
            plymouth-set-default-theme arasaka 2>/dev/null || true
            cat > /etc/plymouth/plymouthd.conf << PLYEOF
[Daemon]
Theme=arasaka
ShowDelay=0
DeviceTimeout=5
PLYEOF
        fi

        # The busybox initramfs HOOKS live in /etc/mkinitcpio.conf.d/arasaka-ab.conf
        # (staged by copy_services) - that file already carries the plymouth hook.
    '
}

configure_system76_power() {
    log "Configuring system76-power..."
    run arch-chroot "${ROOTFS}" /bin/bash -c '
        # Self-heal: RESUME builds skip the AUR build if the binary is present,
        # but the daemon may not be enabled yet (the AUR package install script
        # does NOT auto-enable it, only prints a hint).
        if [ -x /usr/bin/system76-power ]; then
            systemctl enable com.system76.PowerDaemon.service 2>/dev/null || true
            systemctl start com.system76.PowerDaemon.service 2>/dev/null || true
            echo "system76-power daemon enabled."
        else
            echo "WARNING: system76-power not installed - skipping"
        fi

        # Block power-profiles-daemon so the two power managers never fight.
        # cosmic lists it only as an optional dep, so nothing breaks.
        if pacman -Q power-profiles-daemon >/dev/null 2>&1; then
            systemctl disable --now power-profiles-daemon.service 2>/dev/null || true
            systemctl mask power-profiles-daemon.service 2>/dev/null || true
        fi
        if [ -f /usr/lib/systemd/system/power-profiles-daemon.service ]; then
            systemctl mask power-profiles-daemon.service 2>/dev/null || true
        fi
    '
}

configure_cups() {
    log "Configuring CUPS printing..."
    run arch-chroot "${ROOTFS}" /bin/bash -c '
        systemctl enable cups
        systemctl enable cups.socket
        systemctl enable cups.path

        # Configure CUPS for network printing
        mkdir -p /etc/cups/
        cat > /etc/cups/cupsd.conf << "CUPSEOF"
LogLevel warn
MaxLogSize 0
Port 631
Listen /run/cups/cups.sock
Browsing On
BrowseLocalProtocols dnssd
DefaultAuthType Basic
WebInterface Yes
CUPSEOF
    '
}

configure_apparmor() {
    log "Configuring AppArmor..."
    run arch-chroot "${ROOTFS}" /bin/bash -c '
        systemctl enable apparmor

        mkdir -p /etc/kernel/cmdline.d/
        cat > /etc/kernel/cmdline.d/apparmor.conf << "AAEOF"
apparmor=1 security=apparmor
AAEOF

        mkdir -p /etc/apparmor.d/
        apparmor_parser -r /etc/apparmor.d/ 2>/dev/null || true
    '
}

configure_snap() {
    log "Configuring Snap (snapd + core)..."

    run arch-chroot "${ROOTFS}" /bin/bash -c '
        # In RESUME mode the pacstrap step is skipped, so snapd may not be
        # installed yet even though it was added to the package list.
        if [ ! -x /usr/bin/snap ]; then
            echo "snapd missing - installing..."
            pacman -S --noconfirm snapd 2>&1 || true
        fi

        systemctl enable snapd.socket
        systemctl enable snapd.service
        systemctl enable snapd.apparmor.service 2>/dev/null || true
        systemctl enable snapd.seeded.service 2>/dev/null || true
    '
}

configure_systemd() {
    log "Configuring systemd-everything..."

    run arch-chroot "${ROOTFS}" /bin/bash -c '
        systemctl set-default graphical.target

        systemctl enable systemd-resolved
        systemctl enable systemd-networkd
        systemctl enable systemd-timesyncd
        systemctl enable systemd-boot-update
        systemctl enable systemd-oomd
        systemctl enable NetworkManager
        systemctl enable cosmic-greeter
        systemctl enable flatpak-system-update
        systemctl enable systemd-zram-setup@zram0.service

        # NOTE: arasaka-* units are enabled in copy_services() AFTER they are
        # copied, because these unit files do not exist yet at this point.

        systemctl mask getty@tty1 2>/dev/null || true
        rm -f /etc/profile.d/*.sh 2>/dev/null || true

        mkdir -p /etc/systemd/system.conf.d/
        cat > /etc/systemd/system.conf.d/00-arasaka-env.conf << ENVEOF
[Manager]
DefaultEnvironment=PATH=/usr/bin:/usr/sbin:/usr/local/bin
DefaultEnvironment=XDG_CURRENT_DESKTOP=cosmic
DefaultEnvironment=COSMIC_SESSION=1
DefaultEnvironment=GTK_USE_PORTAL=1
ENVEOF

        mkdir -p /etc/systemd/user.conf.d/
        cat > /etc/systemd/user.conf.d/00-cosmic.conf << ENVEOF
[Manager]
DefaultEnvironment=XDG_CURRENT_DESKTOP=cosmic
DefaultEnvironment=XDG_SESSION_TYPE=wayland
DefaultEnvironment=GTK_USE_PORTAL=1
ENVEOF
    '
}

configure_locales() {
    log "Generating locales for COSMIC + Calamares language selection..."

    cat > "${ROOTFS}/etc/locale.gen" << 'EOF'
en_US.UTF-8 UTF-8
de_DE.UTF-8 UTF-8
fr_FR.UTF-8 UTF-8
es_ES.UTF-8 UTF-8
it_IT.UTF-8 UTF-8
pt_BR.UTF-8 UTF-8
nl_NL.UTF-8 UTF-8
ru_RU.UTF-8 UTF-8
ja_JP.UTF-8 UTF-8
ko_KR.UTF-8 UTF-8
zh_CN.UTF-8 UTF-8
pl_PL.UTF-8 UTF-8
sv_SE.UTF-8 UTF-8
tr_TR.UTF-8 UTF-8
ar_EG.UTF-8 UTF-8
fi_FI.UTF-8 UTF-8
da_DK.UTF-8 UTF-8
nb_NO.UTF-8 UTF-8
cs_CZ.UTF-8 UTF-8
hu_HU.UTF-8 UTF-8
EOF

    run arch-chroot "${ROOTFS}" /bin/bash -c 'locale-gen'

    cat > "${ROOTFS}/etc/locale.conf" << 'EOF'
LANG=en_US.UTF-8
EOF
}

configure_calamares() {
    log "Installing Calamares configuration + live autostart..."

    local cfg
    cfg="$(realpath "$(dirname "$0")")/config/calamares"

    # Install /etc/calamares (settings + module configs + scripts + branding)
    mkdir -p "${ROOTFS}/etc/calamares"
    cp -a "${cfg}/settings.conf" "${ROOTFS}/etc/calamares/"
    cp -a "${cfg}/modules" "${ROOTFS}/etc/calamares/"
    cp -a "${cfg}/branding" "${ROOTFS}/etc/calamares/"
    if [ -d "${cfg}/scripts" ]; then
        cp -a "${cfg}/scripts" "${ROOTFS}/etc/calamares/"
    fi

    # Branding must also be visible to Calamares from its shared search path.
    mkdir -p "${ROOTFS}/usr/share/calamares/branding"
    cp -a "${cfg}/branding/." "${ROOTFS}/usr/share/calamares/branding/"

    # Allow the live 'user' to run the installer without a polkit password
    # prompt (the desktop file launches "pkexec arasaka-calamares-root.sh").
    mkdir -p "${ROOTFS}/etc/polkit-1/rules.d"
    cat > "${ROOTFS}/etc/polkit-1/rules.d/10-arasaka-live.rules" << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id === "io.calamares.calamares.pkexec.run" && subject.user === "user") {
        return polkit.Result.YES;
    }
    if (action.id === "org.arasaka.installer.pkexec.run" && subject.user === "user") {
        return polkit.Result.YES;
    }
});
EOF

    # Dedicated pkexec action for the installer wrapper. pkexec strips
    # WAYLAND_DISPLAY/QT_QPA_PLATFORM from the child environment, which made
    # Calamares fall back to the (nonexistent) X11 display and abort. The
    # wrapper re-sets the display variables before exec'ing Calamares as root.
    mkdir -p "${ROOTFS}/usr/share/polkit-1/actions"
    cat > "${ROOTFS}/usr/share/polkit-1/actions/org.arasaka.installer.policy" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
 "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1.0/policyconfig.dtd">
<policyconfig>
  <vendor>Arasaka</vendor>
  <action id="org.arasaka.installer.pkexec.run">
    <description>Run the Arasaka system installer</description>
    <message>Authentication is required to run the Arasaka system installer</message>
    <defaults>
      <allow_active>yes</allow_active>
      <allow_inactive>yes</allow_inactive>
      <allow_any>auth_admin_keep</allow_any>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/bin/arasaka-calamares-root.sh</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_active_socket">true</annotate>
  </action>
</policyconfig>
EOF

    # Root-side wrapper: fix the display environment that pkexec strips.
    cat > "${ROOTFS}/usr/local/bin/arasaka-calamares-root.sh" << 'EOF'
#!/bin/bash
# Run as root via pkexec (action org.arasaka.installer.pkexec.run).
# pkexec strips WAYLAND_DISPLAY/QT_QPA_PLATFORM/XDG_RUNTIME_DIR, so they are
# passed as arguments by the user-side launcher and re-applied here.
set -euo pipefail

export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
export WAYLAND_DISPLAY="${1:-wayland-1}"
export XDG_RUNTIME_DIR="${2:-/run/user/1000}"
export DISPLAY="${3:-:0}"

shift 3 2>/dev/null || true
exec /usr/bin/calamares "$@"
EOF
    run chmod 755 "${ROOTFS}/usr/local/bin/arasaka-calamares-root.sh"

    # Live autostart wrapper: only does anything on an archiso live boot.
    cat > "${ROOTFS}/usr/local/bin/arasaka-calamares.sh" << 'EOF'
#!/bin/bash
# Launch the Calamares installer, but only when running from the live ISO.
set -euo pipefail

if [ ! -d /run/archiso ] && [ ! -d /run/archiso/cowspace ]; then
    exit 0
fi

# Detect the Wayland socket from the live session.
wl="wayland-1"
rt="/run/user/1000"
for s in /run/user/*/wayland-*; do
    if [ -S "$s" ]; then
        wl="$(basename "$s")"
        rt="$(dirname "$s")"
        break
    fi
done

# Let the desktop settle before popping the installer.
sleep 4
exec pkexec /usr/local/bin/arasaka-calamares-root.sh "${wl}" "${rt}" "${DISPLAY:-:0}"
EOF
    run chmod 755 "${ROOTFS}/usr/local/bin/arasaka-calamares.sh"

    # COSMIC autostart entry for the live user.
    mkdir -p "${ROOTFS}/home/user/.config/autostart"
    cat > "${ROOTFS}/home/user/.config/autostart/arasaka-calamares.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=Install Arasaka
GenericName=System Installer
Comment=Launch the Arasaka system installer
Exec=/usr/local/bin/arasaka-calamares.sh
Terminal=false
StartupNotify=true
Categories=System;
EOF
    run arch-chroot "${ROOTFS}" bash -c 'chown -R user:users /home/user/.config 2>/dev/null || true'
}

configure_flatpak_apps() {
    log "Configuring Flatpak + Bazaar + default apps..."

    run arch-chroot "${ROOTFS}" /bin/bash -c '
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        flatpak remote-add --if-not-exists bazaar https://bz-frontend.litterbox.kde.org/repo/bz.flatpakrepo 2>/dev/null || true

        # Install apps one at a time - failure of one should not stop the rest.
        # Firefox kept (best native Wayland browser for COSMIC); Resources was
        # removed per user request (COSMIC has its own system monitor).
        for app in org.mozilla.firefox com.visualstudio.code org.gnome.DiskUtility com.github.tchx84.Flatseal org.thonny.Thonny com.vscodium.codium it.mijorus.gearlever; do
            echo "Installing ${app}..."
            timeout 300 flatpak install -y --system flathub "${app}" 2>&1 || \
                echo "WARNING: ${app} install failed or timed out - will be available on first boot update"
        done

        mkdir -p /etc/systemd/system/flatpak-system-update.service.d/
        cat > /etc/systemd/system/flatpak-system-update.service.d/override.conf << FLATEOF
[Unit]
Description=Flatpak System Update (Arasaka)

[Service]
ExecStart=
ExecStart=/usr/bin/flatpak update --system --noninteractive
FLATEOF

        # Flatpak apps are installed system-wide, so their .desktop files live
        # in /var/lib/flatpak/exports/share. XDG_DATA_DIRS does not include it
        # by default -> apps never show up in the launcher. Ship a profile.d
        # (interactive shells) and an environment.d (systemd user session,
        # covers the greeter/COSMIC session) that add it.
        #
        # The append is idempotent: environment.d already lists the dir once,
        # and profile.d runs on top of it in a login shell. Without the guard
        # the dir ends up TWICE in XDG_DATA_DIRS and every flatpak app shows
        # as a duplicate entry in the launcher (this was the duplicate-shortcut
        # bug the user reported).
        cat > /etc/profile.d/flatpak.sh << 'FPSH'
if [ -z "${XDG_DATA_DIRS}" ]; then
    XDG_DATA_DIRS="/usr/local/share:/usr/share"
fi
case ":${XDG_DATA_DIRS}:" in
    *":/var/lib/flatpak/exports/share:"*) : ;;
    *) XDG_DATA_DIRS="${XDG_DATA_DIRS}:/var/lib/flatpak/exports/share" ;;
esac
export XDG_DATA_DIRS
FPSH
        chmod 755 /etc/profile.d/flatpak.sh
        cat > /etc/environment.d/90-flatpak.conf << 'FPENV'
XDG_DATA_DIRS=/usr/local/share:/usr/share:/var/lib/flatpak/exports/share
FPENV

        # --- COSMIC-themed flatpaks ---------------------------------------
        # COSMIC-native apps use libcosmic (iced), not GTK, so they are themed
        # through COSMIC Settings - a GTK theme cannot touch them. GTK apps
        # (most flatpaks) DO follow the GNOME GTK settings. adw-gtk3 (the
        # libadwaita GTK3 port) is AUR-only on Arch, so the plan is:
        #   host GTK3 apps -> bundled Adwaita dark via color-scheme=prefer-dark
        #   flatpak GTK3 apps -> adw-gtk3 dark via Flathub runtime extensions
        #   libadwaita/GTK4 apps -> color-scheme via xdg-desktop-portal-cosmic
        flatpak install -y --system flathub \
            org.gtk.Gtk3theme.adw-gtk3 \
            org.gtk.Gtk3theme.adw-gtk3-dark \
            org.gtk.Gtk3theme.Adwaita-dark 2>&1 || true

        # System-wide defaults (gsettings reads /etc/dconf): dark scheme for
        # every current and future user. GTK3 Adwaita renders its dark variant
        # from color-scheme automatically; libadwaita apps follow it through
        # the cosmic portal.
        mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
        cat > /etc/dconf/profile/user << 'DPROF'
user-db:user
system-db:local
DPROF
        cat > /etc/dconf/db/local.d/00-arasaka-theme << 'DDB'
[org/gnome/desktop/interface]
gtk-theme='Adwaita'
color-scheme='prefer-dark'
DDB
        dconf update

        # Flatpak overrides (system-wide, all users): expose GTK config,
        # ~/.themes and ~/.icons read-only, and force the dark libadwaita
        # theme so every flatpak matches COSMIC.
        # NOTE: /var/lib/flatpak/overrides is NOT created by flatpak install -
        # the dir must exist or both the cat and the chmod below fail.
        mkdir -p /var/lib/flatpak/overrides
        cat > /var/lib/flatpak/overrides/global << 'FOVR'
[Environment]
GTK_THEME=adw-gtk3-dark

[Context]
filesystems=~/.themes;~/.icons;xdg-config/gtk-3.0;
FOVR
        chmod 644 /var/lib/flatpak/overrides/global
    '
}

configure_proton() {
    log "Installing GE-Proton (with DXVK) + .exe launch integration..."

    local GE_VER="GE-Proton11-3"
    local GE_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${GE_VER}/${GE_VER}.tar.gz"

    # GE-Proton is a self-contained Wine fork that bundles DXVK + VKD3D-Proton,
    # so "Proton + DXVK preinstalled" is one artifact. It runs standalone with
    # zero Steam: STEAM_COMPAT_CLIENT_INSTALL_PATH + STEAM_COMPAT_DATA_PATH +
    # "proton run". DXVK/vkd3d-proton are AUR-only as pacman packages, so GE's
    # bundled copies are the reliable preinstalled option.
    # GE-VER/GE_URL are passed as positional args ($1/$2) so the inner script
    # never relies on host-side ${...} expansion mid-string (a quote-break bug
    # here expanded ${TMPD} on the host to "", writing the tarball to / and
    # making sha512sum -c look for the sidecar in the wrong dir -> FAILED).
    # Runs via run() (root): the extract+mv writes into the ROOT-OWNED
    # ${ROOTFS}/opt, which the builder user cannot do. The download itself
    # never happens in practice (CI pre-stages the verified mirror copy), so
    # losing curl's stderr to run()'s 2>/dev/null is an acceptable trade-off.
    run bash -c '
        set -e
        GE_VER="$1"
        GE_URL="$2"
        B2_APPLICATION_KEY_ID="$3"
        B2_APPLICATION_KEY="$4"
        B2_BUCKET="$5"
        TMPD=$(mktemp -d)
        SRC=""
        # CI pre-stages a verified copy at /tmp/GE-Proton (GitHub Actions cache,
        # see build-iso.yml) so the build never depends on flaky external CDNs.
        # The runner egress IP is intermittently blocked by the GitHub release
        # CDN AND the B2 download endpoint, so the cache is the reliable path.
        if [ -s "/tmp/GE-Proton/${GE_VER}.tar.gz" ] \
            && [ -s "/tmp/GE-Proton/${GE_VER}.sha512sum" ] \
            && ( cd /tmp/GE-Proton && sha512sum -c "${GE_VER}.sha512sum" ); then
            echo "Using pre-staged GE-Proton from /tmp/GE-Proton"
            SRC=/tmp/GE-Proton
        else
            echo "No usable staged GE-Proton - downloading..."
            # GitHub release CDN intermittently 403s/404s and --retry alone does
            # NOT retry HTTP errors, so loop: download -> verify, nuking
            # partials between attempts. A corrupt download is caught by the
            # checksum and triggers a fresh attempt.
            for attempt in 1 2 3; do
                echo "Downloading ${GE_VER} (~700 MB)... attempt ${attempt}/3"
                rm -f "${TMPD}/${GE_VER}.tar.gz" "${TMPD}/${GE_VER}.sha512sum"
                if curl -fL --retry-all-errors --retry 5 --retry-delay 3 2>&1 \
                        -o "${TMPD}/${GE_VER}.tar.gz" "${GE_URL}" \
                    && curl -fsSL --retry-all-errors --retry 5 --retry-delay 3 2>&1 \
                        -o "${TMPD}/${GE_VER}.sha512sum" "${GE_URL}.sha512sum" \
                    && ( cd "${TMPD}" && sha512sum -c "${GE_VER}.sha512sum" ); then
                    SRC="${TMPD}"
                    break
                fi
            done
            # GitHub release CDN intermittently blocks runner IPs. If B2 creds
            # are provided (CI), fall back to the Backblaze B2 mirror.
            if [ "${SRC}" = "" ] && [ -n "${B2_APPLICATION_KEY_ID:-}" ] \
                && [ -n "${B2_APPLICATION_KEY:-}" ] && [ -n "${B2_BUCKET:-}" ]; then
                echo "GitHub CDN unreachable - falling back to Backblaze B2 mirror..."
                for attempt in 1 2 3; do
                    rm -f "${TMPD}/${GE_VER}.tar.gz" "${TMPD}/${GE_VER}.sha512sum"
                    AUTH=$(curl -fsS -u "${B2_APPLICATION_KEY_ID}:${B2_APPLICATION_KEY}" \
                        "https://api.backblazeb2.com/b2api/v3/b2_authorize_account" 2>&1) \
                        || { echo "  B2 authorize failed"; continue; }
                    B2_TOKEN=$(echo "${AUTH}" | sed -n "s/.*\"authorizationToken\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")
                    B2_DLURL=$(echo "${AUTH}" | sed -n "s/.*\"downloadUrl\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")
                    echo "  B2 authorized: token ${#B2_TOKEN} chars, dlurl ${B2_DLURL}, bucket ${B2_BUCKET}"
                    [ -n "${B2_TOKEN}" ] && [ -n "${B2_DLURL}" ] || continue
                    if curl -fsSL --retry-all-errors --retry 5 --retry-delay 3 2>&1 \
                            -H "Authorization: ${B2_TOKEN}" \
                            -o "${TMPD}/${GE_VER}.sha512sum" \
                            "${B2_DLURL}/file/${B2_BUCKET}/proton-ge/${GE_VER}.sha512sum" \
                        && curl -fsSL --retry-all-errors --retry 5 --retry-delay 3 2>&1 \
                            -H "Authorization: ${B2_TOKEN}" \
                            -o "${TMPD}/${GE_VER}.tar.gz" \
                            "${B2_DLURL}/file/${B2_BUCKET}/proton-ge/${GE_VER}.tar.gz" \
                        && ( cd "${TMPD}" && sha512sum -c "${GE_VER}.sha512sum" ); then
                        SRC="${TMPD}"
                        break
                    fi
                done
            fi
        fi
        [ "${SRC}" != "" ] || { echo "GE-Proton download/checksum FAILED (GitHub + B2)"; exit 1; }
        # Extract into the builder-owned TMPD, not into SRC: the staged
        # /tmp/GE-Proton (or a download dir) may be root-owned in CI (copied in
        # via sudo), and tar cannot mkdir there as the builder user.
        cd "${TMPD}"
        tar -xzf "${SRC}/${GE_VER}.tar.gz"
        rm -rf '${ROOTFS}'/opt/GE-Proton
        mv "${GE_VER}" '${ROOTFS}'/opt/GE-Proton
        rm -rf "${TMPD}"
    ' _ "$GE_VER" "$GE_URL" "${B2_APPLICATION_KEY_ID:-}" "${B2_APPLICATION_KEY:-}" "${B2_BUCKET:-}"

    run arch-chroot "${ROOTFS}" /bin/bash -c '
        chmod -R a+rX /opt/GE-Proton

        # Wrapper: run any .exe through GE-Proton (no Steam, no launcher).
        # Bundled DXVK handles D3D9-11 -> Vulkan automatically.
        cat > /usr/local/bin/arasaka-run-exe << "REXE"
#!/bin/bash
# Launch a Windows .exe via standalone GE-Proton (DXVK bundled). No Steam.
set -e
[ $# -lt 1 ] && { echo "usage: arasaka-run-exe <file.exe> [args...]"; exit 1; }
EXE="$1"; shift || true
PROTON="${ARASAKA_PROTON:-/opt/GE-Proton}"
PREFIX_DIR="${GE_PROTON_PREFIX_DIR:-$HOME/.local/share/ge-proton}"
mkdir -p "$PREFIX_DIR"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$PROTON"
export STEAM_COMPAT_DATA_PATH="$PREFIX_DIR"
exec "$PROTON/proton" run "$EXE" "$@"
REXE
        chmod 755 /usr/local/bin/arasaka-run-exe

        # MIME handler so double-clicking an .exe in cosmic-files launches it.
        cat > /usr/share/applications/arasaka-exe.desktop << 'DEXE'
[Desktop Entry]
Type=Application
Name=Windows Executable
GenericName=Run Windows Program
Comment=Launch .exe through GE-Proton (DXVK)
Exec=/usr/local/bin/arasaka-run-exe %f
Terminal=false
NoDisplay=true
MimeType=application/x-ms-dos-executable;application/x-wine-extension-exe;
DEXE
        # Default handler system-wide (xdg-mime default writes only ~/.config)
        mkdir -p /usr/share/applications
        touch /usr/share/applications/mimeapps.list
        cat > /usr/share/applications/mimeapps.list << 'MML'
[Default Applications]
application/x-ms-dos-executable=arasaka-exe.desktop
application/x-wine-extension-exe=arasaka-exe.desktop
MML
        update-desktop-database /usr/share/applications 2>/dev/null || true
    '
}

configure_live_autologin() {
    log "Creating live user + COSMIC autologin (live only)..."

    # SHA-512 hash of the live password "live". usermod -p (not chpasswd):
    # chpasswd uses PAM which aborts with "Critical error" inside a nested
    # chroot (CI builds the rootfs while itself running in a chroot).
    # usermod writes /etc/shadow directly.
    local LIVE_PW_HASH='$6$/Elg9RotmGAgGlOg$tcr.df/fx/i8lrHpsVC0g43F9ervTfY6.Uo75a0tFsFV2mpyIlkO6Spjff72gigUE1ov8k.qxvNztKLZ6Uxbq1'

    run arch-chroot "${ROOTFS}" /bin/bash -c '
        useradd -m -u 1000 -g users -G wheel,video,render,audio,input,storage,power -s /usr/bin/zsh user 2>/dev/null || true
        # RESUME builds skip useradd (user exists) - grant render access anyway,
        # otherwise /dev/dri/renderD* (group render, 0660) is unusable and every
        # app falls back to software rendering.
        usermod -aG render user 2>/dev/null || true
        # Live user password = "live" so sudo works interactively on the live
        # system. Keep autologin (no password needed to reach the desktop).
        usermod -p "'"$LIVE_PW_HASH"'" user 2>/dev/null || true
    '

    # Live + installed systems: let wheel members use sudo with their password.
    # (Main /etc/sudoers has no %wheel line, so nothing could sudo otherwise.)
    run arch-chroot "${ROOTFS}" /bin/bash -c '
        mkdir -p /etc/sudoers.d
        printf "%%wheel ALL=(ALL:ALL) ALL\n" > /etc/sudoers.d/10-arasaka
        chown root:root /etc/sudoers.d/10-arasaka
        chmod 0440 /etc/sudoers.d/10-arasaka
    '

    cat > "${ROOTFS}/usr/local/bin/arasaka-autologin.sh" << 'EOF'
#!/bin/bash
# Arasaka autologin wrapper. greetd runs this as [initial_session]. If this is
# a live (archiso) boot we exec the installer inside a minimal kiosk Wayland
# compositor (cage) - a Windows-style installer environment instead of a full
# desktop session. On the installed system /run/archiso is absent, so we exit
# and greetd falls back to showing the greeter.
set -euo pipefail

if [ -d /run/archiso/cowspace ] || [ -d /run/archiso ]; then
    if command -v cage >/dev/null 2>&1; then
        # cage: kiosk compositor - hosts the Calamares installer fullscreen.
        # arasaka-calamares.sh pkexec's calamares as root (polkit rule
        # org.arasaka.installer.pkexec.run allows the live user).
        exec /usr/bin/dbus-run-session -- \
            env XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=arasaka-installer \
            XDG_DATA_DIRS=/usr/local/share:/usr/share:/var/lib/flatpak/exports/share \
            /usr/bin/cage /usr/local/bin/arasaka-calamares.sh
    fi
    # Fallback: full COSMIC desktop session (cage missing).
    exec /usr/bin/dbus-run-session -- \
        env XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=COSMIC \
        XDG_DATA_DIRS=/usr/local/share:/usr/share:/var/lib/flatpak/exports/share \
        /usr/bin/start-cosmic
fi

exit 0
EOF
    run chmod 755 "${ROOTFS}/usr/local/bin/arasaka-autologin.sh"

    cat > "${ROOTFS}/etc/greetd/cosmic-greeter.toml" << 'EOF'
[terminal]
vt = "1"

[general]
service = "login"

[default_session]
command = "cosmic-greeter-start"
user = "cosmic-greeter"

[initial_session]
command = "/usr/local/bin/arasaka-autologin.sh"
user = "user"
EOF
}

configure_firewall() {
    log "Configuring firewalld (secure-by-default) + kernel hardening..."

    run arch-chroot "${ROOTFS}" /bin/bash -c '
        pacman -S --needed --noconfirm firewalld
        systemctl enable firewalld

        # Secure-by-default: default zone is "public" -> inbound denied except
        # established/related + dhcpv6-client, outbound open. No sshd exists,
        # nothing else is exposed. Make the zone explicit so a future firewalld
        # package upgrade cannot silently loosen it.
        mkdir -p /etc/firewalld/zones
        cat > /etc/firewalld/zones/public.xml << FDEOL
<?xml version="1.0" encoding="utf-8"?>
<zone>
  <short>Public</short>
  <description>Arasaka secure default: drop all inbound traffic (established/related + DHCPv6 only).</description>
  <service name="dhcpv6-client"/>
</zone>
FDEOL

        # Sensible kernel hardening (desktop-safe).
        cat > /etc/sysctl.d/99-arasaka-hardening.conf << SYSEOL
kernel.kptr_restrict=1
kernel.dmesg_restrict=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.tcp_syncookies=1
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
SYSEOL
    '
}

configure_debloat() {
    log "Removing software that users can self-install (lean default desktop)..."

    # openssh: client + server, not enabled, and a desktop user who needs SSH
    # can install it themselves. Force-remove (-dd) so gcr-4 / gvfs / libnma
    # stay put (they pull openssh back in on the next pacman transaction, so
    # arasaka-update.sh strips it again after every update).
    run arch-chroot "${ROOTFS}" /bin/bash -c '
        pacman -Rdd --noconfirm openssh 2>&1 || true
        rm -f /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null || true

        # avahi (mDNS/Bonjour): the package cannot be removed - its libraries
        # are a hard runtime dependency of pipewire-pulse (audio), ostree
        # (flatpak) and cups (printing). But the avahi daemon is a network
        # service this desktop never uses; guarantee it can never run.
        systemctl mask avahi-daemon.service avahi-daemon.socket avahi-dnsconfd.service 2>&1 || true
    '
}

configure_zsh() {
    log "Making zsh the user shell (bash stays as a hidden engine for Arch internals)..."

    # "Only shell" here means: every user-facing login shell is zsh and /bin/sh
    # is zsh. Bash cannot be deleted outright because core Arch machinery hardcodes
    # a bash shebang (start-cosmic, alpm hook scripts, pacman-key, makepkg,
    # mkinitcpio) and running pacman -Syu (the update engine) would break. It is
    # simply never presented to the user.
    run arch-chroot "${ROOTFS}" /bin/bash -c '
        pacman -S --needed --noconfirm zsh zsh-completions

        # root + live user login shells, and the default for any user created
        # later (Calamares install users, useradd) -> zsh.
        usermod -s /usr/bin/zsh root
        usermod -s /usr/bin/zsh user 2>/dev/null || true
        sed -i "s|^SHELL=.*|SHELL=/usr/bin/zsh|" /etc/default/useradd

        # /bin/sh -> zsh (auto POSIX-sh emulation when invoked as "sh"). Bash
        # stays installed for the hardcoded-bash scripts, so this cannot break
        # anything that already required bash.
        ln -sfn zsh /bin/sh
        ln -sfn zsh /usr/bin/sh

        mkdir -p /etc/zsh /root /home/user /etc/skel
        cat > /etc/zsh/zprofile << ZPEOF
# zprofile: source the system profile (sets XDG_DATA_DIRS for flatpak, etc.).
if [ -f /etc/profile ]; then
    source /etc/profile
fi
ZPEOF

        cat > /etc/skel/.zshrc << ZSEOF
# Arasaka zsh config - clean, fast, desktop-friendly.
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select

setopt AUTO_CD
setopt EXTENDED_GLOB
setopt HIST_IGNORE_ALL_DUPS
setopt SHARE_HISTORY
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000

# sudo forwards aliases/plugins into the elevated session.
alias sudo="sudo "

alias ls="ls --color=auto"
alias ll="ls -lah"
alias la="ls -A"
alias l="ls -lF"
alias update="sudo /usr/local/bin/arasaka-update.sh"
alias up="sudo /usr/local/bin/arasaka-update.sh"
alias reboot="systemctl reboot"
alias poweroff="systemctl poweroff"

PROMPT="%F{cyan}%n@%m%f:%F{green}%~%f %# "
export EDITOR=nano
ZSEOF

        cp /etc/skel/.zshrc /root/.zshrc
        cp /etc/skel/.zshrc /home/user/.zshrc 2>/dev/null || true
        chown -R user:users /home/user/.zshrc 2>/dev/null || true
        chsh -s /usr/bin/zsh root
    '
}

configure_rauc() {
    log "Configuring RAUC (signed OTA)..."

    local rauc_dir="${ROOTFS}/etc/rauc"
    local lib_rauc="${ROOTFS}/usr/lib/rauc"
    run_quiet mkdir -p "${rauc_dir}" "${lib_rauc}" "${ROOTFS}/etc/arasaka"

    # RAUC system configuration (A/B ext4 slots + custom systemd-boot backend).
    run_quiet cp "$(dirname "$0")/config/rauc/system.conf" "${rauc_dir}/system.conf"

    # Trusted keyring: the Arasaka OTA CA cert (public). Bundles must chain up
    # to this certificate; the private CA/signing keys never leave CI.
    run_quiet cp "$(dirname "$0")/config/rauc/ca.crt" "${rauc_dir}/keyring.pem"

    # Custom bootloader backend + system-info handler.
    run_quiet cp "$(dirname "$0")/scripts/rauc-boot-handler.sh" "${lib_rauc}/rauc-boot-handler.sh"
    run_quiet chmod +x "${lib_rauc}/rauc-boot-handler.sh"
    run_quiet cp "$(dirname "$0")/scripts/rauc-system-info.sh" "${lib_rauc}/system-info.sh"
    run_quiet chmod +x "${lib_rauc}/system-info.sh"

    # Public key used to verify the latest.json update pointer at runtime.
    # Extracted from the staged signing certificate so `openssl dgst -verify`
    # (which needs a public key PEM, not a cert) can use it directly.
    openssl x509 -in "$(dirname "$0")/config/rauc/signing.crt" -pubkey -noout \
        > "${ROOTFS}/etc/arasaka/ota-pub.pem"

    # OTA channel config: which bucket/channel the update client polls. The
    # BASE_URL is the public read path for the arasaka-updates B2 bucket.
    cat > "${ROOTFS}/etc/arasaka/ota.conf" << OTAEOF
# Arasaka OTA channel configuration
CHANNEL=stable
BASE_URL=${OTA_BASE_URL:-https://f005.backblazeb2.com/file/arasaka-updates}
B2_KEY_ID=${OTA_B2_KEY_ID:-}
B2_KEY=${OTA_B2_KEY:-}
OTAEOF

    # Baked-in system version (bundle version comparisons / diagnostics).
    echo "${ARASAKA_VERSION:-$(date -u '+%Y%m%d')}" > "${ROOTFS}/etc/arasaka/version"

    # The packaged rauc.service sandboxes heavily. The custom boot backend and
    # the installer need to write /boot (loader.conf + per-slot kernels), write
    # /data/rauc (slot state), mount slots/bundles under /mnt/rauc and, on
    # install, call the backend which mounts the freshly-written slot to extract
    # its kernel. Relax the packaged sandbox so those operations succeed.
    run_quiet mkdir -p "${ROOTFS}/etc/systemd/system/rauc.service.d"
    cat > "${ROOTFS}/etc/systemd/system/rauc.service.d/arasaka.conf" << 'RAUCDROPIN'
[Service]
ProtectSystem=off
ProtectHome=off
NoNewPrivileges=false
CapabilityBoundingSet=
RAUCDROPIN

    run arch-chroot "${ROOTFS}" /bin/bash -c '
        systemctl enable rauc.service 2>/dev/null || true
    '
}

setup_immutable_layout() {
    log "Setting up immutable A/B layout..."

    run arch-chroot "${ROOTFS}" /bin/bash -c '
        mkdir -p /sysroot /boot/ab /var/lib/flatpak /var/lib/systemd
        mkdir -p /var/tmp /var/log /var/cache /tmp /run /etc/arasaka /home        # Compressed RAM swap (zram). No disk swap partition: zram is faster,
        # avoids wearing flash and avoids any swap-on-inactive-slot confusion.
        cat > /etc/systemd/zram-generator.conf << ZRAMEOF
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
ZRAMEOF

        cat > /etc/tmpfiles.d/00-arasaka.conf << IMMEOF
d /var 0755 root root - -
d /var/tmp 1777 root root - -
d /var/lib 0755 root root - -
d /var/lib/flatpak 0755 root root - -
d /var/lib/systemd 0755 root root - -
d /var/log 0755 root root - -
d /var/cache 0755 root root - -
d /tmp 1777 root root - -
d /run 0755 root root - -
d /home 0755 root root - -
d /etc/arasaka 0755 root root - -
d /boot/ab 0755 root root - -
IMMEOF
    '
}

copy_services() {
    log "Installing systemd services and scripts..."

    local svc_dir="${ROOTFS}/etc/systemd/system"
    local bin_dir="${ROOTFS}/usr/local/bin"
    local gen_dir="${ROOTFS}/etc/systemd/system-generators"
    run_quiet mkdir -p "${svc_dir}" "${bin_dir}" "${gen_dir}"
    for f in "$(dirname "$0")/systemd/"*.service "$(dirname "$0")/systemd/"*.timer; do
        [ -f "$f" ] || continue
        run_quiet cp "$f" "${svc_dir}/"
    done

    for f in "$(dirname "$0")/systemd/"*.dropin; do
        [ -f "$f" ] || continue
        local bn
        bn=$(basename "$f")
        local svc_name="${bn%%.*}"
        local dropin_name="${bn#*.}"
        run_quiet mkdir -p "${svc_dir}/${svc_name}.d"
        run_quiet cp "$f" "${svc_dir}/${svc_name}.d/${dropin_name}"
    done

    for f in "$(dirname "$0")/scripts/"*.sh; do
        [ -f "$f" ] || continue
        run_quiet cp "$f" "${bin_dir}/"
        run_quiet chmod +x "${bin_dir}/$(basename "$f")"
    done

    if [ -f "$(dirname "$0")/systemd/arasaka-mount-generator" ]; then
        run_quiet cp "$(dirname "$0")/systemd/arasaka-mount-generator" "${gen_dir}/"
        run_quiet chmod +x "${gen_dir}/arasaka-mount-generator"
    fi

    # Install the Arasaka A/B initramfs hook (mount_handler override with
    # slot rollback) + the drop-in that selects the busybox-style initramfs.
    if [ -d "$(dirname "$0")/initcpio" ]; then
        run_quiet mkdir -p "${ROOTFS}/etc/initcpio/hooks" \
                         "${ROOTFS}/etc/initcpio/install" \
                         "${ROOTFS}/etc/mkinitcpio.conf.d"
        for f in "$(dirname "$0")/initcpio/hooks/"*; do
            [ -f "$f" ] || continue
            run_quiet cp "$f" "${ROOTFS}/etc/initcpio/hooks/"
            run_quiet chmod +x "${ROOTFS}/etc/initcpio/hooks/$(basename "$f")"
        done
        for f in "$(dirname "$0")/initcpio/install/"*; do
            [ -f "$f" ] || continue
            run_quiet cp "$f" "${ROOTFS}/etc/initcpio/install/"
            run_quiet chmod +x "${ROOTFS}/etc/initcpio/install/$(basename "$f")"
        done
        for f in "$(dirname "$0")/initcpio/conf.d/"*; do
            [ -f "$f" ] || continue
            run_quiet cp "$f" "${ROOTFS}/etc/mkinitcpio.conf.d/"
        done
    fi

    # Stage the custom Plymouth Arasaka theme into the rootfs.
    if [ -d "$(dirname "$0")/plymouth/arasaka" ]; then
        run_quiet mkdir -p "${ROOTFS}/usr/share/plymouth/themes/arasaka"
        run_quiet cp "$(dirname "$0")/plymouth/arasaka/"* \
                   "${ROOTFS}/usr/share/plymouth/themes/arasaka/"
    fi

    # Enable the A/B units now that they exist (configure_systemd runs before
    # copy_services, so enabling there would fail - units not present yet).
    # The update/reboot services are intentionally NOT enabled directly: their
    # timers pull them in when they fire.
    run arch-chroot "${ROOTFS}" /bin/bash -c '
        systemctl enable arasaka-update.timer 2>/dev/null || true
        systemctl enable arasaka-reboot-after-update.timer 2>/dev/null || true
        systemctl enable arasaka-slot-mount 2>/dev/null || true
        systemctl enable arasaka-boot-succeeded.service 2>/dev/null || true
        systemctl enable arasaka-persist-data.service 2>/dev/null || true
        systemctl enable arasaka-verify-boot.service 2>/dev/null || true
        systemctl enable arasaka-rauc-mark-good.service 2>/dev/null || true
    ' || true
}

cleanup() {
    log "Cleaning rootfs..."
    # Drop any leftover bind mounts (proc/sys/dev/run) so chown -R and
    # mksquashfs never recurse into pseudo filesystems.
    for mp in proc sys dev run; do
        run umount -lf "${ROOTFS}/${mp}" 2>/dev/null || true
    done
    run umount -lf "${ROOTFS}" 2>/dev/null || true

    run arch-chroot "${ROOTFS}" /bin/bash -c '
        pacman -Scc --noconfirm 2>/dev/null || true
        rm -rf /var/cache/pacman/pkg/* /tmp/* /var/tmp/*
        truncate -s 0 /var/log/* 2>/dev/null || true

        # Normalize ownership: files written into the rootfs by this build
        # script run as the host user, so force everything back to root and
        # restore the live user home. chown STRIPS setuid/setgid bits, so
        # snapshot them first and re-apply afterwards (pkexec, sudo, su,
        # passwd, fusermount3, unix_chkpwd, ...).
        find / -xdev -perm /6000 -printf "%m %p\n" > /tmp/arasaka-setuid.txt 2>/dev/null || true

        chown -R 0:0 / 2>/dev/null || true
        chown -R 1000:1000 /home/user 2>/dev/null || true

        while read -r mode path; do
            chmod "$mode" "$path" 2>/dev/null || true
        done < /tmp/arasaka-setuid.txt
        rm -f /tmp/arasaka-setuid.txt

        # Safety net: restore the setuid/setgid bits for every such binary in
        # this build (from the pacman package mtrees). chown -R / strips these
        # bits and the in-chroot uutils find cannot always re-snapshot them.
        chmod 4755 /usr/bin/pkexec /usr/bin/sudo /usr/bin/su /usr/bin/passwd \
            /usr/bin/mount /usr/bin/umount /usr/bin/fusermount3 \
            /usr/bin/ksu /usr/bin/chfn /usr/bin/chsh /usr/bin/newgrp \
            /usr/bin/chage /usr/bin/expiry /usr/bin/gpasswd /usr/bin/sg \
            2>/dev/null || true
        chmod 6755 /usr/bin/unix_chkpwd 2>/dev/null || true
        chmod 2755 /usr/bin/wall /usr/bin/write 2>/dev/null || true
        chmod 4711 /usr/lib/ssh/ssh-keysign 2>/dev/null || true
        chmod 4110 /usr/lib/dbus-daemon-launch-helper 2>/dev/null || true
    '
}

build_image() {
    log "Building rootfs squashfs image..."
    for mp in proc sys dev run; do
        run umount -lf "${ROOTFS}/${mp}" 2>/dev/null || true
    done
    run umount -lf "${ROOTFS}" 2>/dev/null || true

    local img="${BUILD_DIR}/arasaka-rootfs.sfs"
    run mksquashfs "${ROOTFS}" "${img}" \
        -comp zstd -Xcompression-level 19 \
        -b 1M -no-xattrs -noappend

    local size
    size=$(run du -sb "${img}" | cut -f1)
    log "Image built: $(( size / 1024 / 1024 )) MB - ${img}"
}

main() {
    log "=== Arasaka Builder ==="
    log "COSMIC | uutils ONLY (GNU purged) | flatpak+bazaar | bluetooth | mesa"
    log "apparmor+snap | CUPS | weekly auto-update"
    log "========================================================================="
    check_host
    ensure_deps

    # Resume support: if pacstrap already completed, skip clean+strap so a
    # mid-build failure (e.g. expired sudo token) doesn't redo 8 hours of work.
    if [ -d "${ROOTFS}/var/lib/pacman/local" ] && [ -f "${ROOTFS}/usr/bin/pacman" ]; then
        log "Existing rootfs detected - RESUME mode (skipping clean + strap)"
    else
        clean
        strap
    fi

    # AUR builds run BEFORE the purge: on a fresh build GNU coreutils is still
    # present for makepkg; on a resume build the plain-named uutils hard links
    # are in place, so makepkg sees /usr/bin/ls, /usr/bin/rm, etc. and works.
    # GNU coreutils is NEVER restored.
    #
    # Order matters: uutils-findutils must be installed BEFORE purge_gnu_coreutils
    # (its hard-link phase rewires /usr/bin/find, /usr/bin/xargs, ...). The
    # purge runs last so the final rootfs has only the plain-named uutils.
    build_aur_calamares
    build_aur_snapd
    build_aur_findutils
    build_aur_system76power
    purge_gnu_coreutils

    # Make the directories the configure_* functions write into (as the host
    # user, via plain `cat >`/`mkdir`) writable again; a fresh pacstrap leaves
    # them root-owned. cleanup() normalizes ownership back to root at the end.
    run chown -R "$(id -u):$(id -g)" \
        "${ROOTFS}/etc" "${ROOTFS}/usr/local/bin" "${ROOTFS}/home" \
        "${ROOTFS}/usr/share/calamares" "${ROOTFS}/usr/share/polkit-1" \
        2>/dev/null || true

    configure_bluetooth
    configure_mesa
    configure_cups
    configure_apparmor
    configure_snap
    configure_systemd
    configure_locales
    configure_calamares
    configure_live_autologin
    configure_zsh
    configure_firewall
    configure_debloat
    configure_flatpak_apps
    configure_proton
    configure_rauc
    setup_immutable_layout
    copy_services
    configure_plymouth
    configure_system76_power
    cleanup
    build_image
    log "=== Build complete ==="
    log "Rootfs: ${ROOTFS}"
    log "Image: ${BUILD_DIR}/arasaka-rootfs.sfs"
    log ""
    log "Next steps:"
    log "  ./create-iso.sh        - Build live ISO with Calamares installer"
    log "  ./install-to-disk.sh   - Direct install (A/B immutable)"
}

main "$@"
