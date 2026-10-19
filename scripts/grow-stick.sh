#!/bin/bash
# grow-stick.sh — extend a USB stick's rootfs partition into the free space
# at the end of the device.
#
# WHY THIS EXISTS
# The published stick image is deliberately small (p1 64MB + p2 800MB = 880MB)
# so that it fits on a 1GB stick, which is the smallest thing anyone is likely
# to have. If you wrote it to a 16GB stick, 15GB of the stick is sitting there
# unused, and the live system you booted into only has ~800MB of root
# filesystem.
#
# This script grows p2 to fill the remaining space on the device and then grows
# the ext4 filesystem to fill the partition. It is the same thing the
# installer does to the eMMC, just on the stick.
#
# It is safe to re-run: it does nothing if p2 already fills the device.
#
# Run it on the HOST (not on the box) with the stick plugged in, OR on the box
# if you booted from the stick — in which case p2 is the running root and you
# cannot resize it in place. See the note at the end.
#
#   sudo ./grow-stick.sh /dev/sdb
#
# Linux distros ship ISOs and the installer uses the whole disk; this is the
# equivalent for a stick that is both a boot medium and a live system.

set -euo pipefail

DEV=${1:-}
[ -n "$DEV" ] || { echo "usage: $0 <device>   e.g. $0 /dev/sdb" >&2; exit 1; }
[ -b "$DEV" ] || { echo "$DEV is not a block device" >&2; exit 1; }

# Refuse to operate on a mounted root partition.
ROOT_SRC=$(awk '$2=="/" {print $1; exit}' /proc/self/mountinfo)
case "$ROOT_SRC" in
    "$DEV"[0-9]*)
        echo "refusing: $DEV is the running root filesystem ($ROOT_SRC)" >&2
        echo "Unmount it, or run this from another machine." >&2
        exit 1 ;;
esac

log()  { printf '[grow-stick] %s\n' "$*"; }
die()  { printf '[grow-stick] ERROR: %s\n' "$*" >&2; exit 1; }

for t in parted partprobe e2fsck resize2fs dumpe2fs; do
    command -v "$t" >/dev/null || die "$t not found"
done
# sfdisk is preferred (it can rewrite a single entry precisely) but it is not
# installed everywhere — the box has parted only. parted can do the same job.
HAVE_SFDISK=0
command -v sfdisk >/dev/null && HAVE_SFDISK=1

log "device: $DEV"
log "size:   $(blockdev --getsize64 "$DEV" | awk '{printf "%.0f MiB", $1/1048576}')"

# ---------------------------------------------------------------- read layout
# Read the partition table so we do not depend on the exact partition numbering
# the image was built with.
if [ "$HAVE_SFDISK" = 1 ]; then
    PART_OUT=$(sfdisk -d "$DEV" 2>/dev/null) || die "cannot read the partition table of $DEV"
    P2_LINE=$(echo "$PART_OUT" | awk -F': ' '/^[^:]+ *: *start=/{n++; if(n==2) print $2}')
    [ -n "$P2_LINE" ] || die "could not find a second partition in the table"
    P2_START=$(echo "$P2_LINE" | sed -n 's/.*start=\([0-9]*\).*/\1/p')
    P2_SIZE=$(echo "$P2_LINE" | sed -n 's/.*size=\([0-9]*\).*/\1/p')
else
    # parted, in sector units, machine-readable.
    # The output has a header line, then a label line, then one line per
    # partition, so partition N is on line N+2. Fields are
    #   number:start:end:size:filesystem:bootflag:name
    # and sector values carry an "s" suffix ("32768s") that must be stripped
    # before doing arithmetic on them.
    PART_OUT=$(parted -s -m "$DEV" unit s print 2>/dev/null) || die "cannot read the partition table of $DEV"
    P2_LINE=$(echo "$PART_OUT" | awk -F: 'NR==4 {print $0}')
    [ -n "$P2_LINE" ] || die "could not find a second partition in the table"
    P2_START=$(echo "$P2_LINE" | cut -d: -f2 | tr -d 's')
    P2_SIZE=$(echo "$P2_LINE" | cut -d: -f4 | tr -d 's')
fi
[ -n "$P2_START" ] && [ -n "$P2_SIZE" ] || die "could not parse the p2 entry"

DEV_SECTORS=$(blockdev --getsz "$DEV")
P2_END=$(( P2_START + P2_SIZE ))

log "p2: start=$P2_START size=$P2_SIZE end=$P2_END (device has $DEV_SECTORS sectors)"

if [ "$P2_END" -ge "$DEV_SECTORS" ]; then
    log "p2 already fills the device — nothing to do."
    exit 0
fi

NEW_SIZE=$(( DEV_SECTORS - P2_START ))
log "growing p2 by $(( (NEW_SIZE - P2_SIZE) * 512 / 1048576 )) MiB"

# ---------------------------------------------------------------- grow
if [ "$HAVE_SFDISK" = 1 ]; then
    # Rewrite the partition entry with the new size. --no-reread avoids a
    # kernel rescan while the device is in use; we rescan explicitly after.
    cp "$PART_OUT" /tmp/grow-stick.sfdisk
    sed -i "s/^\([^:]*: *start=$P2_START, *size=\)$P2_SIZE/\1$NEW_SIZE/" /tmp/grow-stick.sfdisk
    sfdisk --no-reread "$DEV" < /tmp/grow-stick.sfdisk || die "sfdisk failed"
else
    # parted: resize the partition to the end of the device.
    parted -s "$DEV" unit s resizepart 2 $(( P2_START + NEW_SIZE - 1 )) \
        || die "parted resizepart failed"
fi
partprobe "$DEV" 2>/dev/null || true
sleep 2

# ---------------------------------------------------------------- resize fs
# The kernel's partition device node name is not always "${DEV}2": for a loop
# device it is "${DEV}p2". Try both.
P2_PART=""
for cand in "${DEV}2" "${DEV}p2"; do
    if [ -b "$cand" ]; then P2_PART="$cand"; break; fi
done
[ -n "$P2_PART" ] || die "no partition device found for p2 (tried ${DEV}2 and ${DEV}p2) after repartitioning"

log "growing the ext4 filesystem"
e2fsck -fp "$P2_PART" >/dev/null 2>&1 || true
resize2fs "$P2_PART" || die "resize2fs failed"

# Report the result rather than trusting the exit code.
FS_MIB=$(dumpe2fs -h "$P2_PART" 2>/dev/null | awk '
    /^Block count:/ { bc=$3 }
    /^Block size:/  { bs=$3 }
    END { if (bc && bs) print int(bc*bs/1048576) }')
PART_MIB=$(blockdev --getsize64 "$P2_PART" 2>/dev/null | awk '{print int($1/1048576)}')
log "  filesystem now ${FS_MIB} MiB (partition is ${PART_MIB} MiB)"
if [ -n "$FS_MIB" ] && [ -n "$PART_MIB" ] && [ "$FS_MIB" -lt "$PART_MIB" ]; then
    log "  WARNING: filesystem is still smaller than its partition."
    log "  Run 'resize2fs $P2_PART' by hand to reclaim the difference."
fi

log "done. Unmount and re-plug the stick to use the new space."
