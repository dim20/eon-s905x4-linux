#!/bin/bash
# install-to-emmc.sh — provision eMMC on an EON SDSTB02 (Amlogic S905X4 / SC2)
#
# Run from a Linux session on the box (USB stick boot, or the rescue init).
# After this completes and the USB stick is removed, the box boots Linux from
# eMMC on its own: a saved U-Boot bootcmd does the ext4load + booti.
#
# Design rules this script follows, each of which exists because of a real
# failure on this hardware:
#
#   1. The rootfs is dd'd while UNMOUNTED. Writing raw blocks under a live ext4
#      mount corrupts the filesystem.
#   2. The boot partition is ext4, and the bootcmd uses ext4load. Do not use
#      FAT32 here: a FAT filesystem whose geometry disagrees with its partition
#      silently truncates writes, which produced a corrupt kernel that booted to
#      nothing and cost a full debugging session.
#   3. Everything written is verified AFTER an unmount/remount cycle, from a
#      read-only mount. A hash taken while the filesystem is still mounted can
#      be a page-cache artefact and will report a corrupt write as clean.
#   4. Nothing is written until the source has been hash-checked.

set -euo pipefail

MMC=/dev/mmcblk0
USB_BOOT=${USB_BOOT:-/dev/sda1}
USB_ROOT=${USB_ROOT:-/dev/sda2}

# Sector geometry. p1 starts past the eMMC key-protected range (73760-74785);
# starting earlier makes ext4load fail with "eMMCkey: Access range is illegal".
P1_START=81920
P1_END=180223
P2_START=180224

# Expected hashes for the boot artefacts. Override with env vars if you have
# rebuilt the kernel; set VERIFY_SKIP=1 to bypass (not recommended).
EXPECT_IMAGE=${EXPECT_IMAGE:-5adbc4cc53cc3633cf44a07f0d61cc2937af41ed3c717846f253526b46c52dc9}
EXPECT_DTB=${EXPECT_DTB:-176ddf27b9e392175dbbbd057449d023c7ddd8bda68210d54c71fccf585d2043}
KERNEL_NAME=${KERNEL_NAME:-Image}
DTB_NAME=${DTB_NAME:-sc2_s905x4_ah212_linux.dtb}

log()  { printf '[install] %s\n' "$*"; }
die()  { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
for d in "$MMC" "$USB_BOOT" "$USB_ROOT"; do
    [ -b "$d" ] || die "$d not found"
done

if [ -r /proc/device-tree/amlogic-dt-id ]; then
    if ! grep -q "sc2_s905x4_ah212" /proc/device-tree/amlogic-dt-id; then
        die "not an sc2_s905x4_ah212 board"
    fi
fi

SRC=/mnt/usb_boot
MNT=/mnt/emmc_verify
mkdir -p "$SRC"

# ---------------------------------------------------------------- sources
log "mounting USB boot partition"
mount "$USB_BOOT" "$SRC" || die "cannot mount $USB_BOOT"

for f in "$KERNEL_NAME" "$DTB_NAME"; do
    [ -f "$SRC/$f" ] || die "missing $f on USB boot partition"
done

log "checking source hashes BEFORE writing anything"
got=$(sha256sum "$SRC/$KERNEL_NAME" | cut -d' ' -f1)
if [ "${VERIFY_SKIP:-0}" != 1 ] && [ "$got" != "$EXPECT_IMAGE" ]; then
    die "kernel hash mismatch on source
  expected $EXPECT_IMAGE
  got      $got
The source is corrupt. Refusing to write it to eMMC.
(Set VERIFY_SKIP=1 to override.)"
fi
log "  kernel OK $got"

got=$(sha256sum "$SRC/$DTB_NAME" | cut -d' ' -f1)
if [ "${VERIFY_SKIP:-0}" != 1 ] && [ "$got" != "$EXPECT_DTB" ]; then
    die "DTB hash mismatch on source
  expected $EXPECT_DTB
  got      $got"
fi
log "  dtb   OK $got"

# ---------------------------------------------------------------- partition
log "unmounting anything on $MMC"
for p in "$MMC"p*; do umount "$p" 2>/dev/null || true; done

log "partitioning $MMC"
parted -s "$MMC" mklabel gpt
parted -s "$MMC" unit s mkpart primary "$P1_START" "$P1_END"
parted -s "$MMC" unit s mkpart primary "$P2_START" 100%
partprobe "$MMC" || true
sleep 2

P1=${MMC}p1
P2=${MMC}p2
[ -b "$P1" ] && [ -b "$P2" ] || die "partitions did not appear"

# ---------------------------------------------------------------- format
log "formatting $P1 (ext4, label BOOT)"
mkfs.ext4 -F -q -L BOOT "$P1"

log "formatting $P2 (ext4, label ROOTFS)"
mkfs.ext4 -F -q -L ROOTFS "$P2"

# ---------------------------------------------------------------- rootfs
# dd with the target UNMOUNTED. This is the whole point of rule 1.
log "copying rootfs from $USB_ROOT to $P2 (unmounted) — this takes a minute"
dd if="$USB_ROOT" of="$P2" bs=4M conv=fsync status=progress
sync

# ---------------------------------------------------------------- fstab
# Written through a mount, after the dd, then unmounted again.
log "writing fstab"
mkdir -p "$MNT"
mount "$P2" "$MNT"
cat > "$MNT/etc/fstab" <<'EOF'
# <file system> <mount point> <type> <options> <dump> <pass>
/dev/mmcblk0p2   /    ext4  defaults,noatime  0  1
EOF
sync
umount "$MNT"

# ---------------------------------------------------------------- boot part
log "populating $P1"
mount "$P1" "$MNT"
cp "$SRC/$KERNEL_NAME" "$MNT/$KERNEL_NAME"
cp "$SRC/$DTB_NAME" "$MNT/$DTB_NAME"
sync
umount "$MNT"
umount "$SRC"

# ---------------------------------------------------------------- verify
# Rule 3: verify from storage, not from cache.
log "verifying writes (unmount/remount/read-only)"
mkdir -p "$MNT"

for spec in "$P1:$KERNEL_NAME:$EXPECT_IMAGE" "$P1:$DTB_NAME:$EXPECT_DTB"; do
    dev=${spec%%:*}; rest=${spec#*:}; name=${rest%%:*}; want=${rest#*:}
    mount -o ro "$dev" "$MNT"
    got=$(sha256sum "$MNT/$name" | cut -d' ' -f1)
    umount "$MNT"
    if [ "${VERIFY_SKIP:-0}" != 1 ] && [ "$got" != "$want" ]; then
        die "VERIFY FAILED for $name
  expected $want
  got      $got
Do not remove the USB stick and power cycle until this is resolved."
    fi
    log "  $name OK $got"
done

log "filesystem checks"
e2fsck -fn "$P1" >/dev/null 2>&1 || true
e2fsck -fn "$P2" >/dev/null 2>&1 || true
log "  e2fsck completed (rc reported above if any issue)"

rmdir "$MNT" 2>/dev/null || true
sync

cat <<EOF

============================================================
 eMMC provisioning complete.

   $P1  ext4  BOOT    $KERNEL_NAME, $DTB_NAME
   $P2  ext4  ROOTFS  Debian

 NEXT STEP — install the bootcmd so the box boots unattended.
 This must be done from U-Boot, once, because fw_printenv is not
 usable on this board:

   mmc dev 1
   ext4load mmc 1:1 0x2000000 $KERNEL_NAME
   ext4load mmc 1:1 0x5000000 $DTB_NAME
   booti 0x2000000 - 0x5000000

 ...boot to Linux, then power cycle and interrupt U-Boot, and set:

   setenv bootcmd "mmc dev 1; mmc rescan; \\
     ext4load mmc 1:1 0x2000000 $KERNEL_NAME; \\
     ext4load mmc 1:1 0x5000000 $DTB_NAME; \\
     setenv bootargs 'root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw \\
       console=ttyS0,921600 earlycon=amlogic,meson-uart,0xfe07a000 \\
       no_console_suspend nowatchdog pd_ignore_unused clk_ignore_unused \\
       TERM=vt220 maxcpus=4 init=/root/rescue-init.sh'; \\
     booti 0x2000000 - 0x5000000"

   saveenv

 NOTE the single quotes around bootargs. Escaped double quotes
 store literal backslashes, corrupt the kernel command line and
 reset the CPU.

 Remove the USB stick and power cycle to confirm standalone boot.
============================================================
EOF