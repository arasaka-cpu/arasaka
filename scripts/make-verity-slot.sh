#!/usr/bin/env bash
# make-verity-slot.sh - pack a rootfs tree into a raw squashfs slot image with
# an appended dm-verity hash tree.
#
# This is the single producer of slot images, shared by:
#   - build-bundle.sh (OTA bundles)                       -> the .raucb payload
#   - install-to-disk.sh (fresh install)                  -> both A/B slots
#   - config/calamares/scripts/arasaka-postinstall.sh     -> the active slot
# so every slot - shipped or installed - is built identically: a raw squashfs
# filesystem followed by the verity hash tree in the same file, described by a
# root hash + hash offset that the initramfs hook (arasaka-ab) reads from
# /boot/ab/verity-<slot>.conf.
#
# Usage: make-verity-slot.sh [--exclude=PATH ...] <src-tree> <out-img> [<conf-out>]
#   --exclude=PATH  extra path to exclude from the squashfs (mounted partitions
#                   inside <src-tree>, e.g. /data, /boot/efi). Repeatable.
#   <src-tree>  rootfs tree to pack. Must already be finalized and have its
#               initramfs regenerated with the arasaka-ab/arasaka-verity hooks.
#   <out-img>   output raw squashfs image (the hash tree is appended to this
#               same file; hash-offset marks where it starts).
#   <conf-out>  optional: write root_hash= / hash_offset= lines here (the
#               /boot/ab/verity-<slot>.conf shape the initramfs hook reads).
#
# Must run as root (mksquashfs + veritysetup write the output as root).
set -euo pipefail

EXCLUDES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --exclude=*) EXCLUDES+=("${1#--exclude=}"); shift ;;
        *) break ;;
    esac
done

if [ $# -lt 2 ]; then
    echo "usage: $0 [--exclude=PATH ...] <src-tree> <out-img> [<conf-out>]" >&2
    exit 1
fi
SRC="$1"
IMG="$2"
CONF="${3:-}"

command -v mksquashfs >/dev/null 2>&1 \
    || { echo "make-verity-slot: mksquashfs not found (install squashfs-tools)" >&2; exit 1; }
command -v veritysetup >/dev/null 2>&1 \
    || { echo "make-verity-slot: veritysetup not found (install cryptsetup)" >&2; exit 1; }
[ -d "${SRC}" ] || { echo "make-verity-slot: source tree not found: ${SRC}" >&2; exit 1; }

rm -f "${IMG}"
# Always exclude pseudo/temporary filesystems and staging dirs: a source tree
# may have live /proc|/sys|/dev|/run bind mounts (build-bundle's hardened copy
# leaves /proc etc. mounted until we snap it; mksquashfs descending a live /proc
# is pathologically slow and OOM-prone). Caller-supplied --exclude flags still
# win and are appended after these defaults.
default_excludes=(proc sys dev run tmp mnt)
if [ ${#EXCLUDES[@]} -gt 0 ]; then
    mksquashfs "${SRC}" "${IMG}" \
        -comp zstd -Xcompression-level 19 -b 1M -no-xattrs -noappend -no-progress \
        -e "${EXCLUDES[@]}" "${default_excludes[@]}" 2>&1 || {
            echo "make-verity-slot: mksquashfs failed (exit $?)" >&2
            exit 1
        }
else
    mksquashfs "${SRC}" "${IMG}" \
        -comp zstd -Xcompression-level 19 -b 1M -no-xattrs -noappend -no-progress \
        -e "${default_excludes[@]}" 2>&1 || {
            echo "make-verity-slot: mksquashfs failed (exit $?)" >&2
            exit 1
        }
fi

img_size=$(stat -c %s "${IMG}")
# The hash tree must start on a block boundary so the data and hash areas never
# overlap: round the image size up to the next 4096 block.
off=$(( (img_size + 4095) / 4096 * 4096 ))
# Capture veritysetup's stderr so a failure is reported instead of silently
# aborting via set -e on the pipeline (the || guard keeps the assignment from
# tripping errexit; $? is the pipeline's own exit code).
verr=$(mktemp)
vrc=0
root_hash=$(veritysetup format \
    --format=1 \
    --data-block-size=4096 --hash-block-size=4096 \
    --hash-offset="${off}" \
    "${IMG}" "${IMG}" 2>"${verr}" | sed -n 's/^Root hash:[[:space:]]*//p') || vrc=$?
if [ -n "${root_hash}" ]; then
    rm -f "${verr}"
else
    echo "make-verity-slot: veritysetup format failed (exit ${vrc})" >&2
    cat "${verr}" >&2
    rm -f "${verr}"
    exit 1
fi

if [ -n "${CONF}" ]; then
    printf 'root_hash=%s\nhash_offset=%s\n' "${root_hash}" "${off}" > "${CONF}"
fi
echo "root_hash=${root_hash} hash_offset=${off}"
