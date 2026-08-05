#!/usr/bin/env bash
# arasaka-finalize-install.sh
# Installed-system finalization / hardening. Applied to a target root
# directory ($1) so that BOTH fresh installs (Calamares post-install hook)
# and OTA bundles (build-bundle.sh) ship the exact same locked-down system:
#
#   - no privilege escalation: sudo/su/pkexec setuid bits stripped, no wheel
#     or sudo group members, /etc/sudoers.d removed, root password locked
#   - the Calamares installer and its polkit/autostart wiring removed
#   - the AppArmor "no system writes even for root" guard armed
#   - tmpfs /var/tmp (the slot rootfs is mounted read-only)
#
# All edits are direct file operations on $1 - no chroot required - so it runs
# on a mounted target root and inside the bundle image alike.
set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
    echo "[arasaka-finalize] ERROR: no valid target root: '${1:-}'" >&2
    exit 1
fi
TARGET="${TARGET%/}"

echo "[arasaka-finalize] Hardening installed system at ${TARGET}"

# --- No privilege escalation -----------------------------------------------
# Strip every account from wheel / sudo in /etc/group (incl. the leftover live
# ISO "user"), regardless of whether a group line is empty or has members.
if [ -f "${TARGET}/etc/group" ]; then
    sed -i 's/^\(wheel:[^:]*:[0-9]*\):.*/\1:/; s/^\(sudo:[^:]*:[0-9]*\):.*/\1:/' \
        "${TARGET}/etc/group"
fi

# Lock root: replace the password hash in /etc/shadow with a locked marker so
# no password, su or login can ever reach a root shell.
if [ -f "${TARGET}/etc/shadow" ]; then
    sed -i 's/^root:\([^:]*\):/root:!:/' "${TARGET}/etc/shadow"
fi

# The live ISO's "user" account has a well-known password ("live"). If a real
# account exists alongside it (the normal Calamares install), lock it out; if
# it is the ONLY real account, it is the account Calamares set up (or the only
# account a bundle lands on), so leave it alone.
if [ -f "${TARGET}/etc/passwd" ] && [ -f "${TARGET}/etc/shadow" ]; then
    other_accounts=$(grep -Ev '^#|^$' "${TARGET}/etc/passwd" | while IFS=: read -r name _ uid _; do
        [ "$uid" -ge 1000 ] 2>/dev/null && [ "$name" != "user" ] && echo "$name"
    done)
    if [ -n "$other_accounts" ]; then
        sed -i 's/^user:\([^:]*\):/user:!:/' "${TARGET}/etc/shadow"
        echo "[arasaka-finalize] Live 'user' account locked (other real accounts exist)"
    fi
fi

# Remove the sudoers stack entirely. With sudo/su unusable there is nothing to
# configure; leaving files around would only invite a sudoers misconfig.
rm -rf "${TARGET}/etc/sudoers.d" 2>/dev/null || true
chmod 0440 "${TARGET}/etc/sudoers" 2>/dev/null || true

# Strip setuid/setgid from the escalation helpers. passwd/unix_chkpwd keep
# their setuid bits so users can still change their own password.
chmod u-s "${TARGET}/usr/bin/pkexec" \
          "${TARGET}/usr/bin/sudo" \
          "${TARGET}/usr/bin/su" 2>/dev/null || true
chmod g-s "${TARGET}/usr/bin/pkexec" \
          "${TARGET}/usr/bin/sudo" \
          "${TARGET}/usr/bin/su" 2>/dev/null || true
rm -f "${TARGET}/usr/bin/sudoedit" 2>/dev/null || true

# --- Installer removal ------------------------------------------------------
# Packages stay installed (removing calamares from the package DB would pull
# its Qt deps, which COSMIC shares); only binaries/entries are removed.
rm -f "${TARGET}/usr/bin/calamares" \
      "${TARGET}/usr/share/applications/calamares.desktop" \
      "${TARGET}/usr/local/bin/arasaka-calamares.sh" \
      "${TARGET}/usr/local/bin/arasaka-calamares-root.sh" \
      "${TARGET}/etc/polkit-1/rules.d/10-arasaka-live.rules" \
      "${TARGET}/usr/share/polkit-1/actions/org.arasaka.installer.policy" \
      "${TARGET}/usr/share/polkit-1/actions/io.calamares.calamares.policy" \
      "${TARGET}/home/user/.config/autostart/arasaka-calamares.desktop" \
      2>/dev/null || true

# --- AppArmor escalation guard ---------------------------------------------
# Even root cannot write /usr,/etc,/lib,/boot through pkexec/sudo/su. The
# profile is staged outside /etc/apparmor.d (inert on the live ISO, where the
# installer needs privileged writes) and is armed here.
if [ -f "${TARGET}/usr/share/arasaka/apparmor/arasaka-escalation" ]; then
    mkdir -p "${TARGET}/etc/apparmor.d"
    cp -a "${TARGET}/usr/share/arasaka/apparmor/arasaka-escalation" \
          "${TARGET}/etc/apparmor.d/arasaka-escalation"
    chmod 644 "${TARGET}/etc/apparmor.d/arasaka-escalation"
    echo "[arasaka-finalize] AppArmor escalation guard armed"
fi

# --- tmpfs scratch on the immutable root ------------------------------------
# The slot root is mounted read-only; /tmp is already tmpfs (systemd), give
# tools a writable /var/tmp as well.
if [ -f "${TARGET}/etc/fstab" ] && ! grep -q " /var/tmp " "${TARGET}/etc/fstab"; then
    printf 'tmpfs  /var/tmp  tmpfs  defaults,noatime,mode=1777  0 0\n' >> "${TARGET}/etc/fstab"
fi

echo "[arasaka-finalize] Installed system hardened"
