#!/bin/bash
# write-stick-image.sh — write a prepared stick image to a USB stick.
#
# Run this on a machine that has the stick attached, and where the box is NOT
# running from that stick. The script refuses to run if the running root
# filesystem is on the device it is about to overwrite.
#
#   ./write-stick-image.sh <image.img.gz> /dev/sdX
#
# WHY THE REFUSAL MATTERS
# Writing raw blocks to a device that is mounted as the running root
# filesystem corrupts it: the kernel keeps using the old in-memory and
# on-disk structures while the blocks underneath are replaced. The box then
# crashes, or worse, limps along with a half-written filesystem.
#
# The check compares MAJOR:MINOR, taken from /proc/self/mountinfo, against
# the same for the target device. Do NOT compare device NAMES or paths:
# mountinfo field 3 is major:minor ("8:2"), not "/dev/sda2", so a name
# comparison never matches and the guard silently never fires. That mistake
# was made twice in this project.
#
# The write is verified afterwards by reading the device back and comparing
# it byte-for-byte with the source.

set -euo pipefail

IMG=${1:-}
DEV=${2:-}

log()  { printf '[write-stick] %s\n' "$*"; }
die()  { printf '[write-stick] ERROR: %s\n' "$*" >&2; exit 1; }

[ -n "$IMG" ] && [ -n "$DEV" ] || die "usage: $0 <image.img.gz> /dev/sdX"
[ -f "$IMG" ] || die "$IMG not found"
[ -b "$DEV" ] || die "$DEV is not a block device"

command -v gzip >/dev/null || die "gzip not found"
command -v cmp >/dev/null || die "cmp not found"

# ---------------------------------------------------------------- guard
# major:minor of the running root, and of the target device.
ROOT_MM=$(awk '$5=="/" {print $3; exit}' /proc/self/mountinfo)

# stat -c '%t:%T' prints hex. mawk has no strtonum, so convert in shell.
# Strip leading zeros but keep at least one digit: "0" must not become "",
# or "0x" alone is not a number and prints as "00".
hex2dec() {
    local h
    h=$(printf '%s' "$1" | sed 's/^0*//')
    [ -z "$h" ] && h=0
    printf '%d' "0x$h" 2>/dev/null || echo 0
}
DEV_RAW=$(stat -c '%t:%T' "$DEV")
DEV_MM="$(hex2dec "${DEV_RAW%%:*}"):$(hex2dec "${DEV_RAW##*:}")"

log "running root: $ROOT_MM ; $DEV: $DEV_MM"
if [ "$ROOT_MM" = "$DEV_MM" ]; then
    die "refusing: the running root filesystem is on $DEV ($ROOT_MM).
  Writing would corrupt the live system. Boot the box from its eMMC, or
  run this from a different machine."
fi

# A partition of the target would also be a problem even if the whole
# device is not the root.
for p in "${DEV}"1 "${DEV}"2 "${DEV}"p1 "${DEV}"p2; do
    [ -b "$p" ] || continue
    PM=$(stat -c '%t:%T' "$p")
    PM="$(hex2dec "${PM%%:*}"):$(hex2dec "${PM##*:}")"
    if [ "$PM" = "$ROOT_MM" ]; then
        die "refusing: $p ($PM) is the running root filesystem."
    fi
done

# Belt and braces: the major:minor comparison above is exact for a plain
# filesystem, but a btrfs root with a subvolume reports a DIFFERENT
# major:minor in mountinfo than the underlying device has (seen: 0:35 in
# mountinfo vs 8:23 from stat on /dev/sdc3). So also refuse if the target
# is named in the mount table as the source of any mount point we care
# about, and refuse outright if it is the source of "/".
MOUNTED_ROOT=$(awk '$5=="/" {print $10; exit}' /proc/self/mountinfo)
for src in "$MOUNTED_ROOT" $(awk '{print $10}' /proc/self/mountinfo 2>/dev/null | sort -u); do
    case "$src" in
        "$DEV"|"${DEV}"[0-9p]*|"${DEV}"[0-9])
            die "refusing: $DEV is the source of a mounted filesystem ($src).
  Writing would corrupt it." ;;
    esac
done
if [ -n "$MOUNTED_ROOT" ] && [ "${MOUNTED_ROOT#/dev/}" != "$MOUNTED_ROOT" ]; then
    case "${MOUNTED_ROOT#/dev/}" in
        "$(basename "$DEV")"|"$(basename "$DEV")"[0-9p]*)
            die "refusing: $DEV appears to be the running root ($MOUNTED_ROOT)." ;;
    esac
fi

# ---------------------------------------------------------------- write
log "unmounting anything on $DEV"
for p in "${DEV}"1 "${DEV}"2 "${DEV}"p1 "${DEV}"p2; do
    [ -b "$p" ] && umount "$p" 2>/dev/null || true
done
sleep 2

log "writing $IMG to $DEV — this takes a few minutes on a slow stick"
gzip -dc "$IMG" | dd of="$DEV" bs=4M conv=fsync status=progress
sync

# ---------------------------------------------------------------- verify
log "verifying the write"
VERIFY=$(mktemp)
trap 'rm -f "$VERIFY"' EXIT

# Read back exactly as much as the image occupies.
SIZE=$(gzip -dc "$IMG" | wc -c)
BLOCKS=$(( (SIZE + 4194303) / 4194304 ))
dd if="$DEV" of="$VERIFY" bs=4M count="$BLOCKS" 2>/dev/null

if cmp -s "$VERIFY" <(gzip -dc "$IMG"); then
    log "WRITE VERIFIED — byte-identical"
else
    die "VERIFY FAILED — the stick does not match the image"
fi

log "done."
