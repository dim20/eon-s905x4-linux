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
# The stick is the INSTALL SOURCE - the installer copies the rootfs's
# CONTENT onto the eMMC - so p2's size directly sets the install time.
# The eMMC takes all the space anyway: the installer partitions it to 100%
# and then grows the filesystem to fill. This is the same relationship an
# ISO has to the disk it is installed onto.
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
# THE IMAGE IS CHECKED AGAINST THE MANIFEST
#   manifest/ says what the image must contain and what it must not. The
#   build runs scripts/check-image.sh against what it has just composed,
#   and refuses to produce an image that does not satisfy it. It also
#   writes an inventory - every file, with its owner, mode, size and
#   checksum - and prints the difference against the last one.
#
# THE BUILD DOES NOT MODIFY ITS INPUT
#   The source tree is copied to a scratch directory first and everything
#   happens to the copy. Building twice gives the same result as building
#   once, and the source tree is exactly what it was.
#
# THE BUILD IS REPRODUCIBLE
#   The filesystem's timestamps, its UUIDs and the gzip header are all
#   pinned, so the same tree gives the same image, byte for byte. The
#   image's hash is then a statement about its content rather than about
#   when it was built.
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

# ---------------------------------------------------------------- staging
# The build works on a COPY of the source tree.
#
# It used to modify the tree in place: it chowned it, emptied its /run,
# deleted its machine-id and replaced its login-message hooks. That made
# the tree an OUTPUT that got reused as the next INPUT, so building twice
# was not the same as building once, and there was no way to tell what the
# tree looked like before a build. That is the shape of "one step forward,
# two steps back".
#
# Copying first costs a few seconds and makes the input immutable.
SRC_TREE="$ROOTFS_TREE"
ROOTFS_TREE="$WORK/rootfs"
log "staging the rootfs tree"
log "  from: $SRC_TREE"
log "  to:   $ROOTFS_TREE   (the source tree is never modified)"
cp -a "$SRC_TREE" "$ROOTFS_TREE" || die "could not stage the rootfs tree"

# The build time, pinned so that the same inputs give the same bytes.
# The filesystem's timestamps are set from it, and it defaults to the
# newest file in the tree so that nothing in the filesystem is "from the
# future".
: "${SOURCE_DATE_EPOCH:=$(find "$ROOTFS_TREE" -newermt '@0' -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)}"
: "${SOURCE_DATE_EPOCH:=0}"
export SOURCE_DATE_EPOCH
log "  SOURCE_DATE_EPOCH = $SOURCE_DATE_EPOCH"

# The filesystem UUIDs are fixed too. A random one would make every build
# differ from every other build, and the image's hash is more useful as a
# statement that "nothing changed" than as a statement that "it was built
# at a different time".
FS_UUID=${FS_UUID:-6e6f6e73-8000-4000-8000-000000000001}
FS_HASH_SEED=${FS_HASH_SEED:-6e6f6e73-8000-4000-8000-000000000002}
FAT_SERIAL=${FAT_SERIAL:-1a2b3c4d}

# ---------------------------------------------------------------- p1: FAT
log "building p1 (${P1_SIZE_MB}MB FAT32, flat layout)"
truncate -s "${P1_SIZE_MB}M" "$WORK/p1.img"
# --invariant: use constants for the values that would otherwise be
# random or the current time. And mtools honours SOURCE_DATE_EPOCH, so
# the files' timestamps are the same in every build. Without these, the
# FAT filesystem's directory entries carry the time the image was built,
# and two builds of the same tree differ.
mkfs.vfat -F 32 -n BOOT -i "$FAT_SERIAL" --invariant "$WORK/p1.img" >/dev/null

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

# A rootfs copied as an unprivileged user ends up owned by that user, and
# `cp -a` cannot preserve ownership when it is not root. The result boots
# fine and then fails in ways that look like nothing to do with ownership:
# sshd refuses to start because /run/sshd is not root-owned, and the whole
# filesystem is writable by the wrong uid. Fix the ownership before the
# image is built, rather than discovering it later.
#
# This runs on the STAGED COPY, so the source tree keeps whatever
# ownership it has.
#
# If the tree is ALREADY root-owned, chown will fail for a non-root user
# even though there is nothing to fix - so check first, and only chown
# when there is actually something to change.
#
# NB: `find` exits non-zero when it cannot descend into a mode-0700
# directory, which under `set -e` would kill the script. Force the exit
# status to zero and handle the output instead.
NOT_ROOT=$(find "$ROOTFS_TREE" ! -uid 0 2>/dev/null | head -1 || true)
# find as a non-root user cannot descend into mode-0700 directories, so it may
# report nothing even when files inside are not root-owned. Check the
# top-level entries too, which is enough to catch the common case.
if [ -z "$NOT_ROOT" ]; then
    for d in "$ROOTFS_TREE" "$ROOTFS_TREE/root" "$ROOTFS_TREE/etc" "$ROOTFS_TREE/run" "$ROOTFS_TREE/var"; do
        [ -e "$d" ] || continue
        if [ "$(stat -c%u "$d" 2>/dev/null)" != "0" ]; then
            NOT_ROOT="$d"
            break
        fi
    done
fi
if [ -n "$NOT_ROOT" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        die "the rootfs tree contains files not owned by root (e.g. $NOT_ROOT).
  They came from an unprivileged copy, and the image must be owned by root.

  Run the build inside a user namespace, where you are root without
  needing to be:

      unshare -r scripts/build-stick-image.sh <tree> <out>

  or fix the tree first:

      sudo chown -R 0:0 <tree>"
    fi
    log "  fixing ownership of the staged tree (some files are not root-owned)"
    chown -R 0:0 "$ROOTFS_TREE" || die "chown failed"
    log "  ownership fixed"
else
    log "  ownership already root:root"
fi

# ---------------------------------------------------------------- mount points
# The kernel INITIALISES devtmpfs but does not mount it (CONFIG_DEVTMPFS_MOUNT
# is not set on this kernel), so the rootfs must contain the directories the
# init mounts onto. A rootfs with no /dev boots and then dies at the login
# prompt with "cannot create /dev/null: Directory nonexistent" — every
# command that redirects output fails.
for d in dev proc sys run tmp; do
    if [ ! -d "$ROOTFS_TREE/$d" ]; then
        mkdir -p "$ROOTFS_TREE/$d"
        chmod 0755 "$ROOTFS_TREE/$d"
        log "  created the missing /$d mount point"
    fi
done
[ -d "$ROOTFS_TREE/tmp" ] && chmod 1777 "$ROOTFS_TREE/tmp"

# ---------------------------------------------------------------- /run
# /run is runtime state: pid files, sockets, caches, and the template that
# update-motd writes for the login message. None of it belongs in an image.
#
# A stale motd.dynamic in particular is worse than useless: it means the
# box greets you with the vendor's banner, full of terminal escape
# sequences that the framebuffer console on the HDMI output cannot render,
# so it arrives on the television as literal escape text.
if [ -d "$ROOTFS_TREE/run" ]; then
    find "$ROOTFS_TREE/run" -mindepth 1 -delete 2>/dev/null || true
    # sshd insists that this directory exists and is root-owned
    mkdir -p "$ROOTFS_TREE/run/sshd"
    chmod 0755 "$ROOTFS_TREE/run"
    log "  cleared the stale runtime state out of /run"
fi

# ---------------------------------------------------------------- machine-id
# The machine-id must NOT be shipped in the image. Every box flashed with
# the same image would otherwise share one identity, which is wrong and can
# confuse services that key on it. systemd generates a transient one when
# the file is absent and persists it on first boot, so each box gets its own.
if [ -e "$ROOTFS_TREE/etc/machine-id" ]; then
    rm -f "$ROOTFS_TREE/etc/machine-id"
    log "  removed the machine-id — systemd will generate a unique one per box"
fi

# ---------------------------------------------------------------- no desktop
# The image ships NO desktop. A desktop is 450 MB of packages and a display
# manager that grabs the framebuffer console, and the whole point of this
# image is a small, minimal system with a TEXT console on the HDMI output.
# The user picks a desktop afterwards with tasksel.
#
# This is checked rather than assumed: a build machine that happens to have a
# desktop installed would otherwise quietly ship one, and the display manager
# would fight the console for the framebuffer.
DESKTOP_PKGS="lightdm lightdm-gtk-greeter gdm3 sddm xfce4 xfce4-session
              task-xfce-desktop task-lxde-desktop task-lxqt-desktop
              task-gnome-desktop task-kde-desktop xserver-xorg-core
              xserver-xorg xserver-xorg-input-all xinit"
STATUS="$ROOTFS_TREE/var/lib/dpkg/status"
if [ -f "$STATUS" ]; then
    for p in $DESKTOP_PKGS; do
        if grep -q "^Package: ${p}$" "$STATUS"; then
            die "the source tree has $p installed.
  The published image must not contain a desktop or a display manager:
  the text console on the HDMI output needs the framebuffer, and a display
  manager takes it. Remove it from the tree first, for example:
      chroot $ROOTFS_TREE apt-get purge --auto-remove $p
  and leave tasksel in place so the user can choose a desktop later."
        fi
    done
    if ! grep -q "^Package: tasksel$" "$STATUS"; then
        die "the source tree has no tasksel.
  Without it the user cannot choose a desktop after installing."
    fi
    log "  no desktop packages in the source tree; tasksel is present"
else
    log "  WARNING: no dpkg status file - cannot check for desktop packages"
fi

# ---------------------------------------------------------------- overrides
# Drop-in unit overrides that the image needs on this hardware. They are
# applied to the source tree before it is built into the image, so a rebuilt
# image gets them automatically.
#
# scripts/overrides/chrony-wait.service.d/ — this kernel has CONFIG_USER_NS
# unset, so chrony-wait.service cannot set up a user namespace and fails,
# leaving the system "degraded" with one failed unit even though everything
# works. The drop-in disables PrivateUsers for that unit.
if [ -d "$HERE/overrides" ]; then
    for src in "$HERE"/overrides/*; do
        [ -e "$src" ] || continue
        name=$(basename "$src")
        if [ "$name" = "motd" ]; then
            # the login-message hooks: they go to /etc/update-motd.d/ and
            # must stay executable
            dest="$ROOTFS_TREE/etc/update-motd.d"
            mkdir -p "$dest"
            # The vendor replaced Debian's own login-message hooks with
            # their own, by symlinking /etc/update-motd.d/<name> to
            # /usr/lib/qubian/update-motd.d/<name>. Their hooks print
            # terminal escape sequences and Amlogic branding, and the
            # framebuffer console on the HDMI output cannot interpret
            # escape sequences - the banner arrives on the television as
            # literal "\e[0;91m" text. Take the vendor's hooks out of the
            # way entirely and use ours instead.
            for f in "$dest"/*; do
                [ -L "$f" ] || continue
                case "$(readlink "$f")" in
                    /usr/lib/qubian/update-motd.d/*)
                        rm -f "$f"
                        log "  removed the vendor's login-message hook $(basename "$f")"
                        ;;
                esac
            done
            rm -rf "$ROOTFS_TREE/usr/lib/qubian/update-motd.d"
            # Remove any entry with the same name first. The vendor image
            # has these as DANGLING SYMLINKS into a directory that is not
            # installed, and cp refuses to write through a dangling
            # symlink - it would fail with "not writing through dangling
            # symlink" rather than replacing it.
            for f in "$src"/*; do
                [ -e "$f" ] || continue
                rm -f "$dest/$(basename "$f")"
            done
            cp -a "$src/." "$dest/"
            chmod 0755 "$dest"/* 2>/dev/null || true
            log "  applied override: $name"
        elif [ -d "$src" ]; then
            # a drop-in directory: e.g. chrony-wait.service.d/
            dest="$ROOTFS_TREE/etc/systemd/system/$name"
            mkdir -p "$dest"
            cp -a "$src/." "$dest/"
            log "  applied override: $name"
        else
            # a whole unit file: e.g. enable-hdmi.service
            cp -a "$src" "$ROOTFS_TREE/etc/systemd/system/$name"
            log "  installed unit: $name"
        fi
    done
fi

# ------------------------------------------------- the vendor's leftovers
# The image is built from the vendor's rootfs, so it inherits the vendor's
# assumptions. Some of them are hazards rather than features, and the
# manifest says they must not be in the image.
#
# This is the big one: /etc/boot-run-once/early/01-resize-rootfs grows the
# root filesystem to fill its device, on every boot. On the stick that
# rewrites the partition table, so the stick stops being the image we
# published, and the install source becomes "the whole stick" rather than
# 800 MB - which is why the installer has to copy the rootfs CONTENT
# rather than the partition. On the eMMC it repartitions the flash on every
# boot.
#
# We grow the stick on purpose, with scripts/grow-stick.sh, and the
# installer grows the eMMC's filesystem itself.
for f in "$ROOTFS_TREE"/etc/boot-run-once/early/*resize*; do
    [ -e "$f" ] || continue
    rm -f "$f"
    log "  removed the vendor's stick-growing script: ${f#$ROOTFS_TREE}"
done
rmdir "$ROOTFS_TREE"/etc/boot-run-once/early 2>/dev/null || true

# ------------------------------------------------- enable our own units
# A unit file that is not enabled never runs. enable-hdmi.service
# programs the HDMI output at boot - the vendor driver leaves the
# connector disabled, and a mode set is runtime state, so it has to be
# done on every boot.
WANTS="$ROOTFS_TREE/etc/systemd/system/multi-user.target.wants"
mkdir -p "$WANTS"
if [ -f "$ROOTFS_TREE/etc/systemd/system/enable-hdmi.service" ]; then
    ln -sf /etc/systemd/system/enable-hdmi.service "$WANTS/enable-hdmi.service"
    log "  enabled enable-hdmi.service"
fi

# ---------------------------------------------------------------- the tools
# The image ships scripts that use other programs, and a script that fails
# at boot is a silent failure: the service just says "failed" in the
# journal and the box comes up without the thing the script was for.
#
# enable-hdmi.sh needs modetest, from libdrm-tests, to set the display
# mode. Without it the HDMI output is never programmed and the television
# stays black - which is exactly what happened to the first build of this
# image. Check for it rather than hope.
for t in modetest; do
    found=no
    for d in usr/bin usr/sbin bin sbin; do
        [ -e "$ROOTFS_TREE/$d/$t" ] && found=yes && break
    done
    if [ "$found" != yes ]; then
        die "the source tree has no $t.
  The image's enable-hdmi.sh uses it to set the display mode at boot.
  Install it into the tree, for example:
      apt-get install -y libdrm-tests
  and make sure the package is recorded in the tree's dpkg database."
    fi
done
log "  the tools the shipped scripts need are present"

# ---------------------------------------------------------------- HDMI
# The HDMI output needs two things, and neither happens on its own:
#   * the DTB's fb node enabled (status = "okay"), which is what makes the
#     vendor's OSD framebuffer driver bind and create /dev/fb0. This is a
#     change to the DTB, and the DTB is copied into the image separately.
#   * a mode set at every boot, because the vendor driver leaves the HDMI
#     connector disabled and a mode set is not persistent.
# The script does the second; the unit and the rescue-init hook call it.
if [ -f "$HERE/enable-hdmi.sh" ]; then
    cp -a "$HERE/enable-hdmi.sh" "$ROOTFS_TREE/root/"
    chmod 0755 "$ROOTFS_TREE/root/enable-hdmi.sh"
    log "  installed enable-hdmi.sh"
fi

# The rest of the scripts the image needs in /root. Installing them here
# means a build from a plain Debian rootfs is complete, rather than relying
# on the source tree having been prepared with them already.
for s in rescue-init.sh install-to-emmc.sh find-env.sh prepare-stick.sh grow-stick.sh; do
    [ -f "$HERE/$s" ] || continue
    cp -a "$HERE/$s" "$ROOTFS_TREE/root/$s"
    chmod 0755 "$ROOTFS_TREE/root/$s"
    log "  installed $s"
done

# mke2fs -d populates the filesystem from the directory at creation time.
# No mount and no loop device, which is what makes this buildable on a
# machine where the loop module cannot be loaded.
#
# The UUID and the hash seed are fixed, and the timestamps come from
# SOURCE_DATE_EPOCH, so the same tree gives the same filesystem, byte for
# byte. E2FSPROGS_FAKE_TIME is what makes the superblock's timestamps
# reproducible.
E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH" \
mke2fs -q -F -t ext4 -L ROOTFS -U "$FS_UUID" -E hash_seed="$FS_HASH_SEED" \
       -d "$ROOTFS_TREE" "$WORK/p2.img" || die "mke2fs failed"

# Check the SOURCE before trusting the result. mke2fs -d does not complain
# about an empty or truncated directory: it builds a filesystem containing
# exactly what it was given, which may be nothing. A rootfs with no /dev
# boots to a dead login prompt, and a rootfs with no files is not a rootfs.
SRC_FILES=$(find "$ROOTFS_TREE" -type f 2>/dev/null | wc -l)
[ "$SRC_FILES" -gt 1000 ] || die "the source tree has only $SRC_FILES files — that is not a rootfs.
  Refusing to build an image from it."
for d in dev proc sys run tmp etc usr root; do
    [ -d "$ROOTFS_TREE/$d" ] || die "the source tree has no /$d directory.
  The init mounts onto these; without them the image will not boot."
done
log "  source tree: $SRC_FILES files"

# Check the RESULT. The cheapest and most sensitive signal that the
# filesystem actually got populated is how well it compresses: a real
# 670 MB rootfs gzips to a few hundred MB, an empty one to almost nothing.
P2_GZ=$(gzip -9 -c "$WORK/p2.img" | wc -c)
log "  p2 compresses to $(( P2_GZ / 1048576 )) MiB"
[ "$P2_GZ" -gt 50000000 ] || die "the built p2 compresses to only $P2_GZ bytes — it is almost empty.
  The source tree was probably not what you thought. Refusing to continue."

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

# The ownership inside the filesystem, read out of the image itself rather
# than from the tree it was built from. mke2fs -d copies the ownership,
# but "it should have" is not "it did".
for p in /bin/bash /etc/shadow /etc/passwd; do
    own=$(debugfs -R "stat $p" "$WORK/p2.img" 2>/dev/null \
          | sed -n 's/.*User: *\([0-9]*\) *Group: *\([0-9]*\).*/\1:\2/p')
    if [ -z "$own" ]; then
        log "  WARNING: could not read the ownership of $p out of the image"
    elif [ "$own" != "0:0" ]; then
        die "the file $p is owned by $own inside the image; it must be 0:0"
    fi
done
log "  the files inside the image are owned by root"

# Now check the image against the manifest: the rules, as data, about what
# the image must and must not contain. The checks above are about the copy
# being faithful; these are about the image being RIGHT.
log "checking the image against the manifest"
"$HERE/check-image.sh" --rootfs "$ROOTFS_TREE" --p1 "$WORK/p1.img" \
    || die "the image does not satisfy the manifest (see the failures above)"

# And write down what is in it, so that the next build can say what
# changed. The inventory is the record: it is what "which files must
# remain in the image" means, written out.
INVENTORY_OUT="$(dirname "$OUT")/inventory.txt"
"$HERE/inventory.sh" --rootfs "$ROOTFS_TREE" --out "$INVENTORY_OUT" --quiet
if [ -f "${INVENTORY_BASELINE:-$REPO/manifest/inventory.txt}" ]; then
    "$HERE/inventory.sh" --rootfs "$ROOTFS_TREE" \
        --diff "${INVENTORY_BASELINE:-$REPO/manifest/inventory.txt}" || true
else
    log "  (no baseline inventory yet - $INVENTORY_OUT is the first record)"
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

# sfdisk gives the disk a RANDOM identifier, which it writes into the MBR
# at offset 440. It was the first reason two builds of the same tree came
# out different. It is set from the kernel's checksum instead: stable for
# a given kernel, different for a different one.
DISK_ID="0x$(sha256sum "$KERNEL" | cut -c1-8)"
sfdisk --no-reread --disk-id "$WORK/stick.img" "$DISK_ID" >/dev/null
log "disk identifier: $DISK_ID (derived from the kernel's checksum)"
log "partition table:"
sfdisk -l "$WORK/stick.img" | sed 's/^/  /'

# ---------------------------------------------------------------- compress
mkdir -p "$(dirname "$OUT")"
log "compressing to $OUT"
# -n: do not store the file name or the modification time in the gzip
# header. Without it, two builds of the same tree give two different
# hashes, and the image's hash stops being a statement about its content.
gzip -9 -n -c "$WORK/stick.img" > "$OUT"

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
