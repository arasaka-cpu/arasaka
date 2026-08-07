#!/usr/bin/env bash
# arasaka-ota-update.sh
# Signed, immutable OTA update engine.
#
# Fetches the stable update pointer, verifies its signature against the
# baked-in OTA public key, downloads the RAUC bundle, and installs it to the
# inactive A/B slot. The bundle itself is a RAUC `verity` bundle: RAUC verifies
# its CMS signature against the trusted keyring (/etc/rauc/keyring.pem) and
# checks the `compatible` string before writing anything. Devices never contact
# Arch mirrors at runtime.
#
# Sources (SOURCE_ORDER in /etc/arasaka/ota.conf, default "b2 gh"):
#   b2 - the Backblaze B2 updates bucket (public read path). Its free egress
#        cap (~1 GB/day) can make downloads fail or crawl near the limit.
#   gh - a rolling GitHub Release (the CI publishes the same bundle + pointer
#        there). No auth needed for public releases and served from GitHub's
#        fast CDN. Used when B2 is capped/unreachable.
# The same signed pointer is published to both, so fallback is transparent.
#
# Flow:
#   1. fetch <BASE>/update/<CHANNEL>/latest.json and latest.json.sig
#      (fall back to the GitHub rolling release asset)
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
    GH_OWNER_REPO="${GH_OWNER_REPO:-}"
    GH_RELEASE_TAG="${GH_RELEASE_TAG:-rolling}"
    # Sources tried in order; "b2" and/or "gh" may be listed (whitespace
    # separated). Defaults to B2 first, GitHub rolling release as fallback.
    SOURCE_ORDER="${SOURCE_ORDER:-b2 gh}"
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

gh_url() {
    # GitHub rolling-release asset URL (public, no auth required).
    echo "https://github.com/${GH_OWNER_REPO}/releases/download/${GH_RELEASE_TAG}/$1"
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
    log "Fetching update pointer (channel=${CHANNEL}, sources=[${SOURCE_ORDER}])..."
    mkdir -p "$CACHE_DIR"
    local src
    for src in ${SOURCE_ORDER}; do
        if fetch_pointer_src "$src"; then
            log "Pointer fetched from ${src}"
            return 0
        fi
        log "Pointer fetch from ${src} failed; trying next source"
        rm -f "${CACHE_DIR}/latest.json" "${CACHE_DIR}/latest.json.sig" 2>/dev/null || true
    done
    die "could not fetch update pointer from any source (${SOURCE_ORDER})"
}

fetch_pointer_src() {
    local src="$1"
    case "$src" in
        b2)
            curl_auth --retry 3 -o "${CACHE_DIR}/latest.json" \
                "${BASE_URL}/update/${CHANNEL}/latest.json" || return 1
            curl_auth --retry 3 -o "${CACHE_DIR}/latest.json.sig" \
                "${BASE_URL}/update/${CHANNEL}/latest.json.sig" || return 1
            ;;
        gh)
            [ -n "$GH_OWNER_REPO" ] || { log "gh source configured but GH_OWNER_REPO is empty"; return 1; }
            curl -fsSL --retry 3 -o "${CACHE_DIR}/latest.json" \
                "$(gh_url latest.json)" || return 1
            curl -fsSL --retry 3 -o "${CACHE_DIR}/latest.json.sig" \
                "$(gh_url latest.json.sig)" || return 1
            ;;
        *)
            log "unknown source '${src}' in SOURCE_ORDER"
            return 1
            ;;
    esac
    [ -s "${CACHE_DIR}/latest.json" ] || return 1
    [ -s "${CACHE_DIR}/latest.json.sig" ] || return 1
    return 0
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
    local bundle="$1" sha256="$2" size="$3" dest src
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
    for src in ${SOURCE_ORDER}; do
        if fetch_bundle_src "$src" "$bundle" "$dest"; then
            log "Bundle downloaded from ${src}"
            echo "$dest"
            return 0
        fi
        rm -f "${dest}.part" 2>/dev/null || true
        log "Bundle download from ${src} failed; trying next source"
    done
    die "could not download bundle ${bundle} from any source (${SOURCE_ORDER})"
}

fetch_bundle_src() {
    local src="$1" bundle="$2" dest="$3"
    case "$src" in
        b2)
            curl_auth --retry 3 --retry-delay 5 -o "${dest}.part" \
                "${BASE_URL}/update/${CHANNEL}/${bundle}" || return 1
            ;;
        gh)
            [ -n "$GH_OWNER_REPO" ] || return 1
            curl -fsSL --retry 3 --retry-delay 5 -o "${dest}.part" \
                "$(gh_url "$bundle")" || return 1
            ;;
        *)
            return 1
            ;;
    esac
    [ -s "${dest}.part" ] || return 1
    mv -f "${dest}.part" "$dest"
    return 0
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
