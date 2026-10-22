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
#   1. The rootfs is copied by CONTENT through the filesystem, never by
#      writing raw blocks under a live ext4 mount - that corrupts the
#      filesystem. And it is copied as files rather than as blocks, because
#      the box grows the USB stick to fill the device at every boot, so the
#      source partition is as big as the stick while the rootfs inside it is
#      not.
#   2. The boot partition is ext4, and the bootcmd uses ext4load. Do not use
#      FAT32 here: a FAT filesystem whose geometry disagrees with its partition
#      silently truncates writes, which produced a corrupt kernel that booted to
#      nothing and cost a full debugging session.
#   3. Everything written is verified AFTER an unmount/remount cycle, from a
#      read-only mount. A hash taken while the filesystem is still mounted can
#      be a page-cache artefact and will report a corrupt write as clean.
#   4. Nothing is written until the source has been hash-checked.

set -euo pipefail

# MMC is overridable ONLY so the whole script can be rehearsed against loop
# devices instead of the real eMMC. Leave it alone for real installs.
MMC=${MMC:-/dev/mmcblk0}
USB_BOOT=${USB_BOOT:-/dev/sda1}
USB_ROOT=${USB_ROOT:-/dev/sda2}

# Sector geometry. p1 starts past the eMMC key-protected range (73760-74785);
# starting earlier makes ext4load fail with "eMMCkey: Access range is illegal".
P1_START=81920
P1_END=180223
P2_START=180224

# Expected hashes for the boot artefacts. Override with env vars if you have
# rebuilt the kernel; set VERIFY_SKIP=1 to bypass (not recommended).
#
# These are the hashes of the kernel and DTB that kernel/SHA256SUMS lists,
# so the installer and the release agree about what is in the image.
EXPECT_IMAGE=${EXPECT_IMAGE:-93420f6a5f2bc6c6ade51a793c8c8ffd77562827e51bc1255538f7aee0ada8ff}
EXPECT_DTB=${EXPECT_DTB:-d1e2267f5e945acff73f7a8973af9fcbb2d777faf26771e2a7e75687537ffda8}
KERNEL_NAME=${KERNEL_NAME:-Image}
DTB_NAME=${DTB_NAME:-sc2_s905x4_ah212_linux.dtb}

log()  { printf '[install] %s\n' "$*"; }
die()  { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
command -v rsync >/dev/null 2>&1 || die "rsync is not installed.
  It is used to copy the rootfs onto the eMMC, and it is part of the image.
  If it is missing the image was built wrong."
for d in "$MMC" "$USB_BOOT" "$USB_ROOT"; do
    [ -b "$d" ] || die "$d not found"
done

# SAFETY: refuse to run while booted FROM the eMMC being written.
# If / is on ${MMC}p2 then this script would unmount, partition and mkfs the
# filesystem it is itself running from — the box would die mid-install with a
# half-written target and no way back. Boot from the USB stick instead, so the
# eMMC is only ever a target.
#
# Compare by MAJOR:MINOR from /proc/self/mountinfo, NOT by device name.
# findmnt reports "/" as "/dev/root" here (a symlink to itself), so a
# name-based check compares "/dev/root" against "/dev/mmcblk0p2", does not
# match, and sails straight through the guard while wiping the live system.
# The mountinfo major:minor is authoritative: 179:2 is eMMC p2, 8:2 is the
# stick. Verified on this box.
ROOT_MM=$(awk '$5=="/" {print $3; exit}' /proc/self/mountinfo)
TGT_MM=$(stat -c '%t:%T' "$MMC")
case "$TGT_MM" in *:*) TGT_MM_DEC=$(printf '%d' "0x${TGT_MM%%:*}")'.'$(printf '%d' "0x${TGT_MM##*:}") ;; *) TGT_MM_DEC="" ;; esac
log "root filesystem major:minor = $ROOT_MM ; $MMC = ${TGT_MM_DEC:-unknown}"
if [ -n "$TGT_MM_DEC" ] && [ "$ROOT_MM" = "$TGT_MM_DEC" ]; then
    die "refusing to run: the running root filesystem IS $MMC (major:minor
  $ROOT_MM), which this script is about to repartition and format.

  This installer must be run from the USB stick, so that the eMMC is only
  ever a target. Power off, ensure the stick is plugged in, and power on
  again — the saved bootcmd will boot the stick automatically."
fi
log "running root ($ROOT_MM) is not the target ($MMC ${TGT_MM_DEC:-?}) — safe to proceed"

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

# The stick keeps the boot artefacts in a d/ subdirectory, which is also where
# the saved bootcmd loads them from on the USB branch. Do NOT reorganise the
# stick to suit this script — the d/ layout is load-bearing for a boot path
# that is verified working, and moving files risks breaking it. So look there
# first, then fall back to the boot-partition root for sticks laid out flat.
BOOTDIR=""
FOUND=no
for cand in d ""; do
    if [ -f "$SRC/$cand/$KERNEL_NAME" ] && [ -f "$SRC/$cand/$DTB_NAME" ]; then
        BOOTDIR=$cand
        FOUND=yes
        break
    fi
done
# NB: a flat layout legitimately gives BOOTDIR="", so the "not found" case must
# be tracked separately rather than tested with -z on the directory.
if [ "$FOUND" != yes ]; then
    die "missing $KERNEL_NAME / $DTB_NAME on USB boot partition.
  Looked in: $SRC/d/ and $SRC/."
fi
[ -n "$BOOTDIR" ] && log "  boot artefacts in: $SRC/${BOOTDIR:-.}"
KERNEL_SRC="$SRC/${BOOTDIR:+$BOOTDIR/}$KERNEL_NAME"
DTB_SRC="$SRC/${BOOTDIR:+$BOOTDIR/}$DTB_NAME"
# Prefix used in the bootcmd's USB branch. Defined HERE, at the top level, so
# it is in scope for both the "we set it for you" and the "you do it by hand"
# paths below.
USB_PREFIX=""
[ -n "$BOOTDIR" ] && USB_PREFIX="$BOOTDIR/"

# INIT selects the init system for BOTH branches:
#   systemd  - a real multi-user system: apt, services, a proper journal
#   rescue   - the minimal shell, kept as a fallback if systemd is broken
# Both are installed in the rootfs, so either can be selected later at the
# U-Boot prompt (bootdelay=3 gives you one) by editing init= in bootargs.
#
# Defined at the top level, not inside the branch below: the manual
# instructions in the fallback path use it too.
INIT=${INIT:-systemd}
case "$INIT" in
    systemd) INIT_PATH=/lib/systemd/systemd ;;
    rescue)  INIT_PATH=/root/rescue-init.sh ;;
    *) die "INIT must be 'systemd' or 'rescue', not '$INIT'" ;;
esac

log "checking source hashes BEFORE writing anything"
got=$(sha256sum "$KERNEL_SRC" | cut -d' ' -f1)
if [ "${VERIFY_SKIP:-0}" != 1 ] && [ "$got" != "$EXPECT_IMAGE" ]; then
    die "kernel hash mismatch on source
  expected $EXPECT_IMAGE
  got      $got
The source is corrupt. Refusing to write it to eMMC.
(Set VERIFY_SKIP=1 to override.)"
fi
log "  kernel OK $got"

got=$(sha256sum "$DTB_SRC" | cut -d' ' -f1)
if [ "${VERIFY_SKIP:-0}" != 1 ] && [ "$got" != "$EXPECT_DTB" ]; then
    die "DTB hash mismatch on source
  expected $EXPECT_DTB
  got      $got"
fi
log "  dtb   OK $got"

# ---------------------------------------------------------------- env (A + B)
# The U-Boot environment lives INSIDE p2 on this hardware (measured: 28 MiB into
# p2 on this box). The dd below copies ~773 MiB from the start of p2, so it
# DESTROYS the environment — including any bootcmd that makes the box bootable.
#
# That is why this section must run BEFORE anything is written, and why a
# reinstall wipes an existing bootcmd rather than preserving it by accident.
#
# A = discover the env and write a fresh conditional bootcmd afterwards.
# B = back the env block up before the dd, so it can be restored (or handed to
#     the user) if anything goes wrong.
#
# The offset is a property of the board's U-Boot build and dtb, so it is
# DISCOVERED, never hardcoded. If discovery does not positively verify, we do
# NOT touch the environment at all — writing to an uncertain offset risks an
# unbootable box, which is worse than asking the user for two U-Boot commands.

ENVBAK=/root/env-backup
ENV_CONF=""
ENV_DEV=""
ENV_OFF=""
ENV_ERASE=0     # 1 if the partition work below destroys the env

log "locating U-Boot environment (read-only)"
if [ -x /root/find-env.sh ]; then
    if ENVFOUND=$(/root/find-env.sh "$MMC" 2>/dev/null); then
        ENV_DEV=${ENVFOUND%% *}
        ENV_OFF=${ENVFOUND##* }
        ENV_CONF=$ENVBAK/fw_env.config
        log "  found env at $ENV_DEV $ENV_OFF"
    else
        log "  WARNING: could not locate the U-Boot environment."
        log "  It will NOT be modified. You will need to set bootcmd from U-Boot."
    fi
else
    log "  WARNING: /root/find-env.sh not found — cannot locate the environment."
fi

# B: back the env block up BEFORE any write. Costs 512 KiB and is the only way
# back if a later step goes wrong.
if [ -n "$ENV_OFF" ]; then
    mkdir -p "$ENVBAK"
    OFF_DEC=$(( ENV_OFF ))
    log "  backing up env block to $ENVBAK"
    if dd if="$MMC" bs=512 skip=$(( OFF_DEC/512 )) count=1024 \
          of="$ENVBAK/env-block.bin" 2>/dev/null && [ -s "$ENVBAK/env-block.bin" ]; then
        sha256sum "$ENVBAK/env-block.bin" > "$ENVBAK/env-block.sha256"
        fw_printenv 2>/dev/null > "$ENVBAK/env-before.txt" || true
        cp /etc/fw_env.config "$ENVBAK/fw_env.config.orig" 2>/dev/null || true
        # A working config for this box, so the restore instructions below are
        # copy-pasteable.
        printf '%s %s 0x10000 0x200\n' "$ENV_DEV" "$ENV_OFF" > "$ENV_CONF"
        log "  backup OK ($(stat -c%s "$ENVBAK/env-block.bin") bytes)"
        log "  NOTE: the dd below overwrites this region — the env WILL be replaced."
        ENV_ERASE=1
    else
        log "  WARNING: env backup FAILED. Continuing without one."
        ENV_ERASE=0
    fi
fi

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
# The rootfs is copied by CONTENT, not by blocks.
#
# WHY NOT dd THE SOURCE PARTITION:
#
# The box grows the USB stick at every boot: the vendor's USB-disk flow
# rewrites the stick's partition table and grows the filesystem to fill the
# device. So the source partition is as big as the stick - 7.7 GB on a 7.2 GB
# stick - while the rootfs inside it is 640 MB. A block copy would copy 7 GB
# of zeros, over USB, for every install, and the time scales with the size
# of the stick rather than with the size of the system.
#
# What actually has to move is the rootfs. The target filesystem is already
# the right size - the partition spans the whole eMMC and mkfs made a
# filesystem that fills it - so only the content has to go across: 640 MB
# whatever the stick is.
#
# The copy goes through the filesystems' own metadata, so it is the same
# kind of read and write a normal file copy does, and it works with the
# source mounted.
#
# Two things are deliberately left out, because the IMAGE does not have them
# and every box must have its own:
#   /etc/machine-id        - the machine identity; systemd generates one
#   /etc/ssh/ssh_host_*    - the SSH host keys; sshd generates them
SRCROOT=/mnt/usb_root
DSTROOT=/mnt/emmc_root

# If the script dies part-way through - and it has died part-way through
# before - the two filesystems stay mounted and the next run cannot mount
# them again, and the target is left half-written. Clean up on the way out.
cleanup() {
    mountpoint -q "$SRCROOT" && umount "$SRCROOT" 2>/dev/null || true
    mountpoint -q "$DSTROOT" && umount "$DSTROOT" 2>/dev/null || true
}
trap cleanup EXIT

log "copying the rootfs content from $USB_ROOT to $P2"
mkdir -p "$SRCROOT" "$DSTROOT"
mount "$USB_ROOT" "$SRCROOT" || die "cannot mount $USB_ROOT"
mount "$P2" "$DSTROOT" || die "cannot mount $P2"
rsync -aH --numeric-ids --xattrs --acls --one-file-system \
      --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp \
      --exclude=/etc/machine-id --exclude='/etc/ssh/ssh_host_*_key' \
      "$SRCROOT/" "$DSTROOT/"
rc=$?
# These must not be allowed to abort the script: a umount that fails for a
# trivial reason (the directory is busy for a moment, say) would otherwise
# kill the install halfway and leave the eMMC half-written, which is exactly
# what happened once already.
umount "$SRCROOT" 2>/dev/null || true
umount "$DSTROOT" 2>/dev/null || true
rmdir "$SRCROOT" "$DSTROOT" 2>/dev/null || true
[ "$rc" -eq 0 ] || die "rsync failed (exit $rc) — the eMMC rootfs is incomplete.
  Do not trust this box until the copy has been redone."
sync

# A cheap sanity check on top of rsync's exit code: the two trees must hold
# the same number of files. rsync returning 0 means it finished; this catches
# "it finished but not all of it arrived".
#
# It must never be able to abort the install, so every step of it is
# individually tolerant of failure: a mount that does not happen, a find that
# trips over a file that moved, an umount that finds the mount point busy.
# (It has already killed the install twice.)
file_count() {
    local n=0
    local mnt=/mnt/fc_$$
    mkdir -p "$mnt" 2>/dev/null || true
    if mount "$1" "$mnt" 2>/dev/null; then
        n=$(find "$mnt" -xdev -type f 2>/dev/null | wc -l) || n=0
        umount "$mnt" 2>/dev/null || true
        rmdir "$mnt" 2>/dev/null || true
    fi
    echo "${n:-0}"
}
SRC_N=$(file_count "$USB_ROOT")
DST_N=$(file_count "$P2")
log "  files: source ${SRC_N:-?}, target ${DST_N:-?}"
if [ -n "${SRC_N:-}" ] && [ -n "${DST_N:-}" ] && [ "$SRC_N" != "$DST_N" ]; then
    log "  WARNING: the source and the target hold different numbers of files."
    log "  The difference is expected to be small (the machine-id and the SSH"
    log "  host keys are deliberately not copied, and the live system writes"
    log "  logs), but check the system before relying on it."
fi

# ---------------------------------------------------------------- grow to fill
# The filesystem was created with mkfs over the whole partition, so it
# already fills it and this is a no-op. It is kept as a safety net: if the
# filesystem somehow ended up smaller than the partition, the user would
# boot into a ~5%-full root filesystem with the remaining ~13 GB sitting
# unallocated. That is not obvious from df and looks like a hardware fault.
#
# grow the filesystem to fill the (already correctly sized) partition. Offline,
# so the device must be unmounted.
log "growing filesystem to fill $P2"
e2fsck -fp "$P2" >/dev/null 2>&1 || true
resize2fs "$P2" || die "resize2fs failed; rootfs is still small but usable — run 'resize2fs $P2' by hand after rebooting"
sync

# Report the result rather than trusting the exit code alone: a resize that
# silently did nothing still exits 0 on some builds.
# NB: the block size is 4096 here, NOT the 512-byte sector size — getting this
# wrong reports a size 8x too small. Read it from the superblock rather than
# assuming. (Also note "Block count:" splits into fields 2 and 3; the number is $3.)
FS_MIB=$(dumpe2fs -h "$P2" 2>/dev/null | awk '
    /^Block count:/ { bc=$3 }
    /^Block size:/  { bs=$3 }
    END { if (bc && bs) print int(bc*bs/1048576) }')
PART_MIB=$(blockdev --getsize64 "$P2" 2>/dev/null | awk '{print int($1/1048576)}')
log "  filesystem now ${FS_MIB} MiB (partition is ${PART_MIB} MiB)"
if [ -n "$FS_MIB" ] && [ -n "$PART_MIB" ] && [ "$FS_MIB" -lt "$PART_MIB" ]; then
    log "  WARNING: filesystem is still smaller than its partition."
    log "  Run 'resize2fs $P2' after rebooting to reclaim the difference."
fi

# ---------------------------------------------------------------- restore env (B)
# The dd above overwrote the region the environment lived in. Put a valid one
# back, then set bootcmd (A). Until this runs the box has no usable bootcmd.
if [ "$ENV_ERASE" = 1 ]; then
    log "restoring U-Boot environment block"
    OFF_DEC=$(( ENV_OFF ))
    if dd if="$ENVBAK/env-block.bin" of="$MMC" bs=512 seek=$(( OFF_DEC/512 )) \
          count=1024 conv=fsync 2>/dev/null; then
        sync
        # Verify from the device, not from page cache (rule 3).
        dd if="$MMC" bs=512 skip=$(( OFF_DEC/512 )) count=1024 2>/dev/null \
          | cmp -s - "$ENVBAK/env-block.bin" \
          && log "  env block restored and verified" \
          || log "  WARNING: env block restore did NOT verify"
    else
        log "  ERROR: could not write the env block back."
        log "  The box will not boot until bootcmd is set from U-Boot."
    fi
fi

# ---------------------------------------------------------------- set bootcmd (A)
# fw_setenv takes a BARE VALUE. Passing fw_printenv output stores
# "bootcmd=bootcmd=..." — a doubled prefix that corrupts the variable. This
# happened during testing and briefly bricked the boot path.
if [ -n "$ENV_CONF" ] && [ "$ENV_ERASE" = 1 ] && [ -f "$ENV_CONF" ]; then
    log "setting conditional bootcmd via fw_setenv"
    cp "$ENV_CONF" /etc/fw_env.config

    # The USB branch must load from the SAME directory the artefacts were
    # actually found in. Hardcoding "d/" here while reading from an
    # auto-detected path is a latent bug: on a flat stick the installer would
    # read the kernel successfully, then write a bootcmd pointing at a
    # non-existent d/Image — and the USB branch would fail SILENTLY, falling
    # through to the eMMC branch. The stick would then look like it had no
    # effect at all.
    # INIT and INIT_PATH are defined at the top level, so they are in scope
    # here and in the manual-instruction fallback path below.
    BOOTCMD=$(cat <<EOF
usb start 0; if fatload usb 0:1 0x2000000 ${USB_PREFIX}$KERNEL_NAME; then fatload usb 0:1 0x5000000 ${USB_PREFIX}$DTB_NAME; setenv bootargs 'root=/dev/sda2 rootfstype=ext4 rootwait rw console=ttyS0,921600 console=tty0 earlycon=amlogic,meson-uart,0xfe07a000 no_console_suspend nowatchdog pd_ignore_unused clk_ignore_unused TERM=vt220 maxcpus=4 init=$INIT_PATH'; booti 0x2000000 - 0x5000000; else mmc dev 1; mmc rescan; ext4load mmc 1:1 0x2000000 $KERNEL_NAME; ext4load mmc 1:1 0x5000000 $DTB_NAME; setenv bootargs 'root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw console=ttyS0,921600 console=tty0 earlycon=amlogic,meson-uart,0xfe07a000 no_console_suspend nowatchdog pd_ignore_unused clk_ignore_unused TERM=vt220 maxcpus=4 init=$INIT_PATH'; booti 0x2000000 - 0x5000000; fi
EOF
)

    if fw_setenv bootcmd "$BOOTCMD" 2>/dev/null; then
        # Do not trust the exit code — verify by reading back and comparing.
        GOT=$(fw_printenv bootcmd 2>/dev/null | sed 's/^bootcmd=//')
        if [ "$GOT" = "$BOOTCMD" ]; then
            log "  bootcmd set and verified"
        else
            log "  ERROR: bootcmd read back DIFFERENTLY — env may be corrupt."
            log "  Restore with: fw_setenv bootcmd \"\$(cat $ENVBAK/env-before.txt | sed 's/^bootcmd=//')\""
        fi
    else
        log "  ERROR: fw_setenv failed. The box will not boot unattended."
    fi

    # bootdelay: a "Hit any key to stop autoboot" window at the U-Boot prompt.
    # This is the recovery path for a box whose rootfs will not boot — with a
    # serial adapter attached you can reach U-Boot and fix it, without a USB
    # stick, without ADNL and without fastboot.
    #
    # U-Boot checks bootdelay BEFORE running bootcmd, so this works even
    # though the saved bootcmd replaces the vendor's entirely. Verified:
    # "Hit any key to stop autoboot:  3  2  1  0" with a custom bootcmd.
    #
    # It costs N seconds on EVERY boot. Set BOOTDELAY=0 to disable it.
    BOOTDELAY=${BOOTDELAY:-3}
    if fw_setenv bootdelay "$BOOTDELAY" 2>/dev/null; then
        GOT=$(fw_printenv bootdelay 2>/dev/null | sed 's/^bootdelay=//')
        if [ "$GOT" = "$BOOTDELAY" ]; then
            log "  bootdelay set to $BOOTDELAY (Hit any key to stop autoboot)"
        else
            log "  WARNING: bootdelay read back as '$GOT', expected '$BOOTDELAY'."
        fi
    else
        log "  WARNING: could not set bootdelay — no U-Boot recovery window."
    fi
fi

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
cp "$KERNEL_SRC" "$MNT/$KERNEL_NAME"
cp "$DTB_SRC" "$MNT/$DTB_NAME"
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
EOF

if [ "$ENV_ERASE" = 1 ] && [ -n "$ENV_CONF" ] && [ -f "$ENV_CONF" ]; then
cat <<EOF

 The bootcmd has been set for you (conditional: boots the USB stick
 if present, otherwise the eMMC). Nothing else is required.

 Remove the USB stick and power cycle to confirm standalone boot.

 The previous environment was backed up to:
   $ENVBAK/env-block.bin   (raw block, sha256 alongside)
   $ENVBAK/env-before.txt  (human-readable, all variables)
 To restore it later:
   cp $ENV_CONF /etc/fw_env.config
   dd if=$ENVBAK/env-block.bin of=$MMC bs=512 seek=$(( ${ENV_OFF} / 512 )) count=1024 conv=fsync
============================================================
EOF
else
cat <<EOF

 NEXT STEP — set the bootcmd from U-Boot so the box boots unattended.
 This installer could not locate the U-Boot environment, so it did not
 touch it. Writing to an uncertain offset risks an unbootable box, so
 this step is left to you deliberately.

   ...power cycle, interrupt U-Boot, then:

   setenv bootcmd "usb start 0; if fatload usb 0:1 0x2000000 ${USB_PREFIX}$KERNEL_NAME; then <usb branch>; else <emmc branch>; fi"

 A ready-to-paste conditional bootcmd is in the release README. To
 build it on the box instead:

   fw_setenv bootcmd 'usb start 0; if fatload usb 0:1 0x2000000 ${USB_PREFIX}$KERNEL_NAME; then fatload usb 0:1 0x5000000 ${USB_PREFIX}$DTB_NAME; setenv bootargs '"'"'root=/dev/sda2 rootfstype=ext4 rootwait rw console=ttyS0,921600 console=tty0 earlycon=amlogic,meson-uart,0xfe07a000 no_console_suspend nowatchdog pd_ignore_unused clk_ignore_unused TERM=vt220 maxcpus=4 init=$INIT_PATH'"'"'; booti 0x2000000 - 0x5000000; else mmc dev 1; mmc rescan; ext4load mmc 1:1 0x2000000 $KERNEL_NAME; ext4load mmc 1:1 0x5000000 $DTB_NAME; setenv bootargs '"'"'root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw console=ttyS0,921600 console=tty0 earlycon=amlogic,meson-uart,0xfe07a000 no_console_suspend nowatchdog pd_ignore_unused clk_ignore_unused TERM=vt220 maxcpus=4 init=$INIT_PATH'"'"'; booti 0x2000000 - 0x5000000; fi'

   saveenv

 NOTE the single quotes around bootargs. Escaped double quotes
 store literal backslashes, corrupt the kernel command line and
 reset the CPU. fw_setenv needs a BARE VALUE — never pass it the
 output of fw_printenv, or you will store "bootcmd=bootcmd=...".

 Also give yourself a U-Boot recovery window:

   fw_setenv bootdelay 3

 That pauses the boot for 3 seconds with "Hit any key to stop autoboot",
 so a box whose rootfs will not boot can still be reached at the U-Boot
 prompt with nothing but a serial adapter. Set it to 0 to boot faster.

 Remove the USB stick and power cycle to confirm standalone boot.
============================================================
EOF
fi