#!/bin/bash
# build-stick-image.sh — build the published USB stick image from source.
#
# The output is a single .img.gz you can `dd` onto a USB stick:
#
#     gunzip -c eon-s905x4-linux-stick.img.gz | sudo dd of=/dev/sdX bs=4M
#
# GEOMETRY
#   p1  64MB  FAT32 (LBA)   LBA 32768    boot artefacts, flat (no d/)
#   p2 800MB  ext4          LBA 163840   the Debian rootfs / live system
#   total 880MB, so it fits a 1GB stick
#
# WHY SO SMALL WHEN THE eMMC IS 14.9GB?
# The stick is the INSTALL SOURCE — the installer dd's p2 onto the eMMC — so
# p2's size directly sets the install time (measured: 773MB -> 39s,
# 7GB -> 109s). The eMMC takes all the space anyway: the installer
# partitions it to 100% and then grows the filesystem to fill. This is the
# same relationship an ISO has to the disk it is installed onto.
#
# If you write it to a bigger stick, scripts/grow-stick.sh extends p2 into
# the leftover space.
#
# REQUIREMENTS
#   mke2fs, mkfs.vfat, mtools (mcopy/mdir), debugfs, sfdisk, gzip
#   NO LOOP DEVICE NEEDED: mke2fs -d populates the ext4 filesystem from a
#   directory at creation time, and mtools writes FAT images directly. The
#   build therefore works on a machine where the loop module cannot be
#   loaded, which is a common restriction in containers and VMs.
#
# INPUT
#   A prepared rootfs tree. The one shipped in the release is the live
#   system; to rebuild it from scratch you need a rootfs with the packages
#   pre-installed (chrony, curl, openssh-server, ca-certificates) and
#   /root/rescue-init.sh, /root/install-to-emmc.sh, /root/find-env.sh and
#   /root/prepare-stick.sh in place.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

ROOTFS_TREE=${1:-}
OUT=${2:-"$REPO/dist/eon-s905x4-linux-stick.img.gz"}

P1_SIZE_MB=64
P2_SIZE_MB=800
P1_START=32768          # 16MB — matches the vendor layout
P1_SECTORS=$(( P1_SIZE_MB * 2048 ))
P2_START=$(( P1_START + P1_SECTORS ))
P2_SECTORS=$(( P2_SIZE_MB * 2048 ))
IMG_MB=$(( 16 + P1_SIZE_MB + P2_SIZE_MB ))

KERNEL=${KERNEL:-$REPO/kernel/Image}
DTB=${DTB:-$REPO/kernel/sc2_s905x4_ah212_linux.dtb}
MKIMAGE=${MKIMAGE:-$HERE/../tools/utils/mkimage}

log()  { printf '[build-image] %s\n' "$*"; }
die()  { printf '[build-image] ERROR: %s\n' "$*" >&2; exit 1; }

for t in mke2fs mkfs.vfat mcopy mdir debugfs sfdisk gzip; do
    command -v "$t" >/dev/null || die "$t not found"
done
[ -n "$ROOTFS_TREE" ] || die "usage: $0 <rootfs-tree> [output.img.gz]"
[ -d "$ROOTFS_TREE" ] || die "$ROOTFS_TREE is not a directory"
[ -f "$KERNEL" ] || die "kernel Image not found at $KERNEL"
[ -f "$DTB" ] || die "DTB not found at $DTB"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- p1: FAT
log "building p1 (${P1_SIZE_MB}MB FAT32, flat layout)"
truncate -s "${P1_SIZE_MB}M" "$WORK/p1.img"
mkfs.vfat -F 32 -n BOOT "$WORK/p1.img" >/dev/null

# The boot artefacts go at the ROOT of the boot partition. U-Boot's fatload
# reads only FAT, so this partition must be FAT; the eMMC's must be ext4.
# The kernel is loaded from a different filesystem type than the one the OS
# runs from, and that asymmetry is required.
mcopy -i "$WORK/p1.img" "$KERNEL" :: || die "could not copy the kernel"
mcopy -i "$WORK/p1.img" "$DTB" :: || die "could not copy the DTB"

# The stick's aml_autoscript is the FIRST-BOOT entry vector: the vendor
# bootloader scans the stick, finds it, and runs it. It must boot the
# STICK (root=/dev/sda2), not the eMMC — the eMMC is what we are replacing.
if [ -f "$HERE/stick/aml_autoscript" ]; then
    mcopy -i "$WORK/p1.img" "$HERE/stick/aml_autoscript" :: || die "could not copy aml_autoscript"
else
    die "scripts/stick/aml_autoscript is missing"
fi

log "p1 contents:"
mdir -i "$WORK/p1.img" :: | sed 's/^/  /'

# ---------------------------------------------------------------- p2: ext4
log "building p2 (${P2_SIZE_MB}MB ext4 from $ROOTFS_TREE)"
truncate -s "${P2_SIZE_MB}M" "$WORK/p2.img"

# mke2fs -d populates the filesystem from the directory at creation time.
# No mount and no loop device, which is what makes this buildable on a
# machine where the loop module cannot be loaded.
mke2fs -q -F -t ext4 -L ROOTFS -d "$ROOTFS_TREE" "$WORK/p2.img" || die "mke2fs failed"

# Verify the result by extracting it back out and diffing against the
# source. A copy that silently skipped an unreadable file (mode 0640, for
# instance) looks complete until you diff it.
log "verifying p2 against the source tree"
mkdir -p "$WORK/verify"
debugfs -R "rdump / $WORK/verify" "$WORK/p2.img" >/dev/null 2>&1 || true
if diff -r --no-dereference "$ROOTFS_TREE" "$WORK/verify" >/dev/null 2>&1; then
    log "  p2 matches the source tree exactly"
else
    die "p2 does NOT match the source tree — diff them by hand:
    diff -r --no-dereference '$ROOTFS_TREE' '$WORK/verify'"
fi

# ---------------------------------------------------------------- assemble
log "assembling the ${IMG_MB}MB image"
truncate -s "${IMG_MB}M" "$WORK/stick.img"
dd if="$WORK/p1.img" of="$WORK/stick.img" bs=1M seek=16 conv=notrunc status=none
dd if="$WORK/p2.img" of="$WORK/stick.img" bs=1M seek=$(( 16 + P1_SIZE_MB )) conv=notrunc status=none

# The partition table is written last so it cannot be clobbered by the dd.
sfdisk --no-reread "$WORK/stick.img" >/dev/null <<EOF
label: dos
unit: sectors

start=$P1_START, size=$P1_SECTORS, type=c, bootable
start=$P2_START, size=$P2_SECTORS, type=83
EOF
log "partition table:"
sfdisk -l "$WORK/stick.img" | sed 's/^/  /'

# ---------------------------------------------------------------- compress
mkdir -p "$(dirname "$OUT")"
log "compressing to $OUT"
gzip -9 -c "$WORK/stick.img" > "$OUT"

log "done."
ls -la "$OUT" | sed 's/^/  /'
echo
echo "  sha256: $(sha256sum "$OUT" | cut -d' ' -f1)"
echo
cat <<EOF
  Write it to a USB stick (1GB or larger) with:

      gunzip -c $(basename "$OUT") | sudo dd of=/dev/sdX bs=4M status=progress
      sync

  Then power cycle the box with the stick plugged in. It should boot the
  stick unattended, bring up networking and SSH, and you can then run the
  installer to provision the eMMC.

  If your stick is larger than 1GB and you want the extra space:

      sudo scripts/grow-stick.sh /dev/sdX
EOF
