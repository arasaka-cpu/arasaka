#!/usr/bin/env bash
# arasaka-ota-update.sh
# Signed, immutable OTA update engine.
#
# Fetches the stable update pointer from the Arasaka B2 updates bucket,
# verifies its signature against the baked-in OTA public key, downloads the
# RAUC bundle, and installs it to the inactive A/B slot. The bundle itself is
# a RAUC `verity` bundle: RAUC verifies its CMS signature against the trusted
# keyring (/etc/rauc/keyring.pem) and checks the `compatible` string before
# writing anything. Devices never contact Arch mirrors at runtime.
#
# Flow:
#   1. fetch <BASE>/update/<CHANNEL>/latest.json and latest.json.sig
#   2. verify the signature with /etc/arasaka/ota-pub.pem
#   3. skip if the bundle version <= installed version
#   4. fetch the referenced .raucb bundle and check its sha256
#   5. rauc install (verifies the bundle signature + compatible string)
#   6. mark a reboot (handled by arasaka-reboot-after-update)
#
# Requires rauc (Arch extra), curl, openssl, jq or python3.
set -euo pipefail

LOG_FILE="/var/log/arasaka-ota.log"
CACHE_DIR="/var/cache/arasaka-ota"
OTA_CONF="/etc/arasaka/ota.conf"
PUB_KEY="/etc/arasaka/ota-pub.pem"
INSTALLED_VER_FILE="/etc/arasaka/version"

log() { echo "[arasaka-ota] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
die() { log "FATAL: $*"; exit 1; }

cleanup() {
    rm -f "${CACHE_DIR}/latest.json" "${CACHE_DIR}/latest.json.sig" 2>/dev/null || true
}
trap cleanup EXIT

require_tools() {
    for t in rauc curl openssl; do
        command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
    done
    command -v python3 >/dev/null 2>&1 || die "missing required tool: python3"
}

load_config() {
    [ -f "$OTA_CONF" ] || die "no OTA config at $OTA_CONF"
    # shellcheck disable=SC1090
    . "$OTA_CONF"

    CHANNEL="${CHANNEL:-stable}"
    BASE_URL="${BASE_URL:-}"
    B2_KEY_ID="${B2_KEY_ID:-}"
    B2_KEY="${B2_KEY:-}"
    [ -n "$BASE_URL" ] || die "OTA_BASE_URL not set in $OTA_CONF"
    # Strip a trailing slash so URL joins below are clean.
    BASE_URL="${BASE_URL%/}"
}

curl_auth() {
    # Pass B2 app-key auth if a key is configured (private updates bucket).
    if [ -n "$B2_KEY_ID" ] && [ -n "$B2_KEY" ]; then
        curl -fsSL --user "${B2_KEY_ID}:${B2_KEY}" "$@"
    else
        curl -fsSL "$@"
    fi
}

installed_version() {
    [ -f "$INSTALLED_VER_FILE" ] || return 0
    cat "$INSTALLED_VER_FILE"
}

version_newer() {
    # $1 = candidate, $2 = installed. Returns 0 if candidate > installed.
    # Versions are free-form but in practice date/run strings like
    # 20260804.1. This uses a simple lexical compare which matches the
    # CI-generated monotonically increasing format.
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

fetch_pointer() {
    log "Fetching update pointer (channel=${CHANNEL})..."
    mkdir -p "$CACHE_DIR"
    curl_auth --retry 3 -o "${CACHE_DIR}/latest.json" \
        "${BASE_URL}/update/${CHANNEL}/latest.json"
    curl_auth --retry 3 -o "${CACHE_DIR}/latest.json.sig" \
        "${BASE_URL}/update/${CHANNEL}/latest.json.sig"
    [ -s "${CACHE_DIR}/latest.json" ] || die "empty latest.json"
    [ -s "${CACHE_DIR}/latest.json.sig" ] || die "empty latest.json.sig"
}

verify_pointer() {
    log "Verifying update pointer signature..."
    [ -f "$PUB_KEY" ] || die "OTA public key missing at $PUB_KEY"
    openssl dgst -sha256 -verify "$PUB_KEY" \
        -signature "${CACHE_DIR}/latest.json.sig" \
        "${CACHE_DIR}/latest.json" >/dev/null 2>&1 \
        || die "INVALID signature on latest.json (possible tampering)"
    log "Pointer signature OK"
}

parse_pointer() {
    # Extract version / bundle / sha256 / size from latest.json via python3.
    python3 - "${CACHE_DIR}/latest.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("version", "bundle", "sha256", "size"):
    print(f"{k}={d.get(k, '')}")
PY
}

fetch_bundle() {
    local bundle="$1" sha256="$2" size="$3" dest
    dest="${CACHE_DIR}/$(basename "$bundle")"
    if [ -s "$dest" ]; then
        local cur
        cur=$(sha256sum "$dest" | cut -d' ' -f1)
        if [ "$cur" = "$sha256" ]; then
            log "Bundle already cached and valid: $dest"
            echo "$dest"
            return 0
        fi
    fi
    log "Downloading bundle ${bundle}..."
    curl_auth --retry 3 --retry-delay 5 -o "${dest}.part" \
        "${BASE_URL}/update/${CHANNEL}/${bundle}"
    mv -f "${dest}.part" "$dest"
    echo "$dest"
}

verify_bundle() {
    local file="$1" sha256="$2"
    log "Verifying bundle sha256..."
    local actual
    actual=$(sha256sum "$file" | cut -d' ' -f1)
    [ "$actual" = "$sha256" ] || die "sha256 mismatch on bundle (got ${actual}, expected ${sha256})"
    log "Bundle sha256 OK"
}

install_bundle() {
    local file="$1"
    log "Installing bundle with RAUC (signature + compatible verified by RAUC)..."
    # RAUC's verity bundle install mounts the payload through dm-verity/loop
    # and talks to the rauc D-Bus service; make sure both are available.
    modprobe dm-verity 2>/dev/null || true
    modprobe loop 2>/dev/null || true
    systemctl start rauc.service 2>/dev/null || true
    rauc install "$file" 2>&1 | tee -a "$LOG_FILE"
    local rc=${PIPESTATUS[0]}
    [ "$rc" -eq 0 ] || die "RAUC install failed (rc=$rc)"
    log "RAUC install succeeded. New bundle is now primary."
}

main() {
    log "=========================================="
    log "Arasaka OTA Update"
    log "=========================================="

    require_tools
    load_config

    fetch_pointer
    verify_pointer

    local version bundle sha256 size
    version=$(parse_pointer | sed -n 's/^version=//p')
    bundle=$(parse_pointer | sed -n 's/^bundle=//p')
    sha256=$(parse_pointer | sed -n 's/^sha256=//p')
    size=$(parse_pointer | sed -n 's/^size=//p')

    [ -n "$version" ] || die "pointer has no version"
    [ -n "$bundle" ] || die "pointer has no bundle"

    local installed
    installed=$(installed_version)
    log "Installed version: ${installed:-none} | available: ${version}"

    if [ -n "$installed" ] && ! version_newer "$version" "$installed"; then
        log "Already up to date (installed ${installed}); nothing to do."
        exit 0
    fi

    local bfile
    bfile=$(fetch_bundle "$bundle" "$sha256" "$size")
    verify_bundle "$bfile" "$sha256"
    install_bundle "$bfile"

    log "=========================================="
    log "OTA update complete. Reboot to switch slots."
    log "=========================================="
    exit 0
}

main "$@"
