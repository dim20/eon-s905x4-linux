#!/bin/bash
# prepare-stick.sh — turn a USB stick into a self-contained EON SDSTB02 image.
#
# Run ON THE BOX, while booted FROM the stick (so root=/dev/sda2). Everything
# this script installs lands in the stick's own root filesystem, which is what
# makes the stick both a live system and an installer.
#
# Idempotent: safe to re-run. It checks before it acts.
#
# Why the stick needs this rather than being a bare installer carrier:
# a box that boots from the stick is a working Linux machine with networking,
# SSH and a clock, whether or not the operator goes on to install to eMMC.
#
# Requires: booted from the stick, root, a network connection.

set -uo pipefail

USB_BOOT=/dev/sda1
USB_ROOT=/dev/sda2
MNT_BOOT=/mnt/stick_boot
HERE="$(cd "$(dirname "$0")" && pwd)"

log()  { printf '\033[1;34m[stick]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[stick]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[stick] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -b "$USB_BOOT" ] || die "$USB_BOOT not found — is this booted from the stick?"

# ------------------------------------------------------------------ network
# apt refuses every repository when the clock is at 1970, and the clock needs
# the network. Break that by setting the time from a host that has one.
log "checking clock"
Y=$(date +%Y)
if [ "${Y:-1970}" -lt 2020 ]; then
    warn "clock reads $Y — apt cannot work until this is fixed"
    if command -v chronyd >/dev/null 2>&1; then
        chronyd -q >/dev/null 2>&1 || true
    fi
    if [ "$(date +%Y)" -lt 2020 ]; then
        warn "still wrong after chronyd. Set it manually, then re-run:"
        warn "    date -s \"\$(date -u)\"    # from a host with the right time"
        die "refusing to continue with a wrong clock"
    fi
fi
log "clock OK: $(date)"

# ------------------------------------------------------------------ resolver
# The DHCP client on this image does not write resolv.conf (resolvconf is not
# installed), so DNS is dead without a static one.
if [ ! -s /etc/resolv.conf ]; then
    log "writing /etc/resolv.conf"
    printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
else
    log "/etc/resolv.conf already present"
fi

# DNS returns AAAA only for the Debian mirrors and this box has no IPv6 route,
# so apt stalls. Note the config-file directive syntax; the -o form is
# command-line only and is a syntax error here.
if [ ! -f /etc/apt/apt.conf.d/99force-ipv4 ]; then
    log "forcing IPv4 for apt"
    mkdir -p /etc/apt/apt.conf.d
    printf 'Acquire::ForceIPv4 "true";\n' > /etc/apt/apt.conf.d/99force-ipv4
fi

# ------------------------------------------------------------------ packages
export DEBIAN_FRONTEND=noninteractive

if ! command -v chronyd >/dev/null 2>&1; then
    log "installing chrony (clock; not shipped in the base image)"
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq chrony >/dev/null 2>&1 \
        || warn "chrony install FAILED — the box will boot at 1970"
fi

if [ ! -x /usr/sbin/sshd ]; then
    log "installing openssh-server"
    apt-get install -y -qq openssh-server >/dev/null 2>&1 \
        || warn "openssh-server install FAILED — no SSH after boot"
else
    log "openssh-server already present"
fi

# Host keys are generated once; keep them so SSH trust survives re-imaging.
[ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A >/dev/null 2>&1
ssh-keygen -A >/dev/null 2>&1

# ------------------------------------------------------------------ rescue-init
SRC=""
for c in "$HERE/rescue-init.sh" /root/rescue-init.sh; do
    [ -f "$c" ] && SRC="$c" && break
done
[ -n "$SRC" ] || die "rescue-init.sh not found next to this script"

if cmp -s "$SRC" /root/rescue-init.sh 2>/dev/null; then
    log "rescue-init.sh already up to date"
else
    log "installing rescue-init.sh (networking, clock, sshd)"
    cp "$SRC" /root/rescue-init.sh
    chmod +x /root/rescue-init.sh
fi

# ------------------------------------------------------------------ installer
if [ -f "$HERE/install-to-emmc.sh" ]; then
    cp "$HERE/install-to-emmc.sh" /root/install-to-emmc.sh
    chmod +x /root/install-to-emmc.sh
    log "installer available at /root/install-to-emmc.sh"
fi

# ------------------------------------------------------------------ boot part
mkdir -p "$MNT_BOOT"
mount "$USB_BOOT" "$MNT_BOOT" || die "cannot mount $USB_BOOT"

install_file() {
    local name=$1 dir=$2
    if [ -f "$HERE/$name" ]; then
        cp "$HERE/$name" "$dir/$name"
        log "  copied $name"
    elif [ -f "/mnt/emmc_stage/$name" ]; then
        cp "/mnt/emmc_stage/$name" "$dir/$name"
        log "  copied $name (from stage)"
    else
        warn "  MISSING $name — put it next to this script or in /mnt/emmc_stage"
    fi
}

log "populating the stick's boot partition"
mkdir -p "$MNT_BOOT/d"
install_file Image                     "$MNT_BOOT/d"
install_file sc2_s905x4_ah212_linux.dtb "$MNT_BOOT/d"
install_file aml_autoscript            "$MNT_BOOT"

# ------------------------------------------------------------------ verify
log "verifying kernel and DTB on the stick"
EXPECT_IMAGE=5adbc4cc53cc3633cf44a07f0d61cc2937af41ed3c717846f253526b46c52dc9
EXPECT_DTB=176ddf27b9e392175dbbbd057449d023c7ddd8bda68210d54c71fccf585d2043
FAIL=0

got=$(sha256sum "$MNT_BOOT/d/Image" 2>/dev/null | cut -d' ' -f1)
if [ "$got" = "$EXPECT_IMAGE" ]; then
    log "  Image OK"
else
    warn "  Image MISMATCH"; warn "    expected $EXPECT_IMAGE"; warn "    got      $got"
    FAIL=1
fi

got=$(sha256sum "$MNT_BOOT/d/sc2_s905x4_ah212_linux.dtb" 2>/dev/null | cut -d' ' -f1)
if [ "$got" = "$EXPECT_DTB" ]; then
    log "  DTB OK"
else
    warn "  DTB MISMATCH"; warn "    expected $EXPECT_DTB"; warn "    got      $got"
    FAIL=1
fi

sync
umount "$MNT_BOOT"

[ "$FAIL" -eq 0 ] || die "boot artefacts did not verify — do not use this stick"

cat <<'EOF'

============================================================
 Stick prepared.

 NEXT
 -----
 1. Power cycle with the stick still plugged in. It should now boot
    unattended from the stick, with network and SSH. The old
    autoscript looped forever; this one does not.

 2. Check you can reach it:
        ssh root@<address>

 3. Then provision the eMMC:
        /root/install-to-emmc.sh

    It verifies every artefact before and after writing, and will
    refuse to continue on a hash mismatch.

 4. Remove the stick and power cycle. The box should then boot
    standalone from eMMC.

 NOTE: step 4 will NOT work until a bootcmd has been saved into the
 U-Boot environment, because fw_printenv is unusable on this board.
 The installer prints the exact commands. That step needs a UART
 console once — automating it is the next task.
============================================================
EOF