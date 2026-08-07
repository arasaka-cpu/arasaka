#!/usr/bin/env bash
# arasaka-cryptdata.sh
# Brings up the encrypted /data partition (LUKS2) with TPM2 auto-unlock.
#
# /data holds ALL writable user state (home, flatpak, snap, var state), so it
# is the only storage worth encrypting: the A/B root slots are raw
# squashfs+dm-verity images that RAUC dd-writes verbatim, so LUKS on a slot is
# impossible. LUKS2 therefore lives on the btrfs /data partition alone.
#
# Boot flow:
#   - The crypttab entry for /data is marked `noauto`, so systemd-cryptsetup
#     never auto-starts it and a broken/missing TPM key can never wedge boot
#     in an unattended passphrase prompt. This unit starts the attach instead.
#   - First boot of a fresh install: no TPM key is enrolled yet (the installer
#     cannot seal - the live ISO's PCRs differ from the installed system's), so
#     we unlock with the recovery keyfile and enroll a TPM2 key sealed to
#     PCR 7 + 11 (Secure Boot policy + measured boot of the current UKI).
#   - Later boots: the TPM key unlocks automatically. If the policy is stale
#     (firmware/Secure Boot toggled, UKI rotated by an OTA), the TPM attach
#     fails, we fall back to the recovery keyfile, and re-seal so the NEXT boot
#     unlocks with the TPM again.
#   - No LUKS on /data (legacy unencrypted install): do nothing; persist-data
#     mounts /data by label as before.
set -euo pipefail

DATA_PART="/dev/disk/by-partlabel/arasaka-data"
DATA_MAPPER="arasaka-data"
RECOVERY_KEY="/boot/ab/data-recovery.key"
TPM_PCRS="7+11"

log() { echo "[arasaka-cryptdata] $*"; }

is_luks() {
    cryptsetup isLuks "${DATA_PART}" 2>/dev/null
}

tpm_key_enrolled() {
    cryptsetup luksDump "${DATA_PART}" 2>/dev/null | grep -q '"tpm2"'
}

seal_tpm() {
    # Enroll (or re-enroll) a TPM2 key sealed to the CURRENT PCRs, unlocking
    # the header with the recovery key. Idempotent: wipes any previous TPM
    # slot first, so repeated runs never leak keyslots.
    log "Sealing TPM2 key to PCR ${TPM_PCRS}..."
    systemd-cryptenroll --wipe-slot=tpm2 \
        --unlock-key-file="${RECOVERY_KEY}" "${DATA_PART}" 2>/dev/null || true
    if systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs="${TPM_PCRS}" \
        --unlock-key-file="${RECOVERY_KEY}" "${DATA_PART}" 2>/dev/null; then
        log "TPM2 key sealed (PCR ${TPM_PCRS})"
    else
        log "WARNING: could not seal TPM2 key (no TPM?); /data will unlock via recovery key"
        return 1
    fi
}

attach_data() {
    # Three-step: TPM-only attach first so we can tell whether the TPM policy
    # is valid, then the recovery keyfile, re-sealing whenever the TPM lost.
    if systemd-cryptsetup attach "${DATA_MAPPER}" "${DATA_PART}" /dev/null 2>/dev/null; then
        log "Unlocked /data with TPM2"
        return 0
    fi
    if systemd-cryptsetup attach "${DATA_MAPPER}" "${DATA_PART}" "${RECOVERY_KEY}" 2>/dev/null; then
        log "Unlocked /data with recovery key (TPM policy missing or stale)"
        seal_tpm || true
        return 0
    fi
    log "ERROR: could not unlock /data with TPM2 or recovery key; booting with volatile state"
    return 1
}

main() {
    [ -b "${DATA_PART}" ] || { log "no /data partition (${DATA_PART}); nothing to do"; exit 0; }
    [ -e "/dev/mapper/${DATA_MAPPER}" ] && { log "/data already attached"; exit 0; }
    if ! is_luks; then
        log "${DATA_PART} is not LUKS (legacy unencrypted /data); nothing to do"
        exit 0
    fi
    if [ ! -s "${RECOVERY_KEY}" ]; then
        log "WARNING: recovery key ${RECOVERY_KEY} missing; TPM-only attach"
        systemd-cryptsetup attach "${DATA_MAPPER}" "${DATA_PART}" /dev/null 2>/dev/null \
            || log "ERROR: /data unlock failed; booting with volatile state"
        exit 0
    fi
    attach_data
    exit 0
}

main "$@"
