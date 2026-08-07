#!/usr/bin/env bash
# arasaka-secureboot.sh
# Enrolls the Arasaka Secure Boot signing keys and keeps the ESP binaries
# signed. Runs on every boot (idempotent).
#
# Key model:
#   - A single db keypair is generated once at install time and persisted on
#     the encrypted /data partition (/data/secureboot/keys). persist-data binds
#     it over /etc/secureboot/keys and /usr/share/secureboot/keys so sbctl and
#     rauc-boot-handler always see the same keypair, across OTA slot swaps.
#   - Boot binaries (systemd-boot + every UKI in /EFI/arasaka/) are signed at
#     install time and re-signed by rauc-boot-handler on every set-primary.
#   - The db key is enrolled into the firmware when the machine first boots in
#     Setup Mode. From then on Secure Boot is enforced; this script is a no-op.
set -euo pipefail

SETUP_MODE_VAR="/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c"
EFI_DIR="/boot/efi"
[ -d "${EFI_DIR}/EFI" ] || EFI_DIR="/efi"
[ -d "${EFI_DIR}/EFI" ] || EFI_DIR="/boot"
UKI_DIR="${EFI_DIR}/EFI/arasaka"
SYSTEMD_BOOT="/usr/lib/systemd/boot/efi/systemd-bootx64.efi"

log() { echo "[arasaka-secureboot] $*"; }

keys_dir() {
    for d in /usr/share/secureboot/keys /etc/secureboot/keys; do
        if [ -f "$d/db/db.key" ]; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

setup_mode_enabled() {
    # efivarfs binary variable: 4-byte EFI attribute prefix (LE), then the
    # value bytes. Byte 5 = 0x01 means the firmware is in Setup Mode.
    [ -r "${SETUP_MODE_VAR}" ] || return 1
    local byte
    byte=$(od -An -t x1 -j 4 -N 1 "${SETUP_MODE_VAR}" 2>/dev/null | tr -d ' \n')
    [ "$byte" = "01" ]
}

sign_binary() {
    # Sign a single file in place (idempotent). Returns 0 if it ended up
    # signed, 1 otherwise.
    local f="$1" tmp
    [ -f "$f" ] || return 1
    tmp="${f}.tmp"
    sbctl sign --output "$tmp" "$f" 2>/dev/null || return 1
    mv -f "$tmp" "$f"
    return 0
}

sign_all() {
    # Sign systemd-boot and every Arasaka UKI on the ESP. Idempotent: sbctl
    # overwrites the signature, so re-runs are safe. Also re-stages a fresh
    # copy of the packaged systemd-boot so an unsigned auto-update can never
    # survive this unit.
    local dir=""
    dir="$(keys_dir)" || { log "WARNING: no signing keys (are they bound from /data?); skipping sign"; return 1; }
    local b=""
    for b in "${EFI_DIR}/EFI/systemd/systemd-bootx64.efi" "${EFI_DIR}/EFI/BOOT/BOOTX64.EFI"; do
        if [ -f "$b" ]; then
            [ -f "${SYSTEMD_BOOT}" ] && cp -f "${SYSTEMD_BOOT}" "$b" 2>/dev/null || true
            sign_binary "$b" && log "signed ${b}" || log "WARNING: could not sign ${b}"
        fi
    done
    if [ -d "${UKI_DIR}" ]; then
        local uki=""
        for uki in "${UKI_DIR}"/*.efi; do
            [ -f "$uki" ] || continue
            case "$uki" in
                *.signed|*.unsigned) continue ;;
            esac
            sign_binary "$uki" && log "signed ${uki}" || log "WARNING: could not sign ${uki}"
        done
    fi
}

enroll() {
    log "Firmware is in Setup Mode - enrolling Secure Boot keys"
    if ! keys_dir >/dev/null; then
        log "No keys found (bound from /data); generating a fresh keypair"
        sbctl create-keys 2>/dev/null || { log "ERROR: sbctl create-keys failed"; return 1; }
    fi
    sign_all
    if sbctl enroll-keys 2>/dev/null; then
        log "Secure Boot keys enrolled; Secure Boot enforced from the next boot"
    else
        log "ERROR: sbctl enroll-keys failed; retrying on next boot"
    fi
}

main() {
    [ -d /sys/firmware/efi ] || { log "not a UEFI system; nothing to do"; exit 0; }

    if sbctl is-verified 2>/dev/null; then
        log "Secure Boot verified (keys enrolled, binaries signed)"
        # Keep any UKI that somehow missed a signature in sync (idempotent).
        sign_all || true
        exit 0
    fi

    if setup_mode_enabled; then
        enroll
    else
        log "Secure Boot not verified and firmware not in Setup Mode; cannot enroll"
        log "If the firmware db was reset, reboot into Setup Mode to re-enroll"
    fi
    exit 0
}

main "$@"
