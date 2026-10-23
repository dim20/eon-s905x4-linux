#!/bin/bash
# smoke-test.sh — one command after every kernel or image change.
#
#     /root/smoke-test.sh [--quiet] [--p1 <device>]
#
# WHAT IT IS FOR
#
#   A build can pass every check in the repository and still produce a box
#   that boots to a black screen, a login prompt with no keyboard, or a
#   kernel that panics on the first framebuffer call. Those failures only
#   appear on the target. This script asks the target the questions the
#   repository cannot: is the console where we said it would be, is the
#   kernel on the boot partition the one we published, did anything fail to
#   start.
#
#   It is read-only. It mounts the boot partition read-only and unmounts it
#   again. It changes nothing, so it is safe to run at any time.
#
# WHAT IT CHECKS
#
#   1. identity        the port's branding is ours and has no vendor strings
#   2. console         serial is the kernel console, getty on the VT and serial
#   3. systemd         no failed units; the units that matter are active
#   4. desktop         no desktop/display-manager packages; tasksel present
#   5. packages        dpkg --audit and apt-get check are clean
#   6. boot artefacts  p1's Image and DTB match the expected hashes
#   7. running system  root device, writable root, framebuffer, no panic
#
# THE EXPECTED KERNEL
#
#   If the eon-kernel package is installed, its SHA256SUMS is the authority:
#   the kernel on p1 must match the kernel the package installed. If the
#   package is not installed (an image written straight to eMMC, as the
#   installer does), the constants below are used. Update them when the
#   kernel changes, or pass --expect-image / --expect-dtb.
#
# Exit status: 0 if everything passes, 1 if anything does not. Warnings are
# reported and do not fail the run.

set -uo pipefail

# The kernel this script was shipped with. Overridden by the eon-kernel
# package's own SHA256SUMS when that package is installed.
EXPECT_IMAGE=${EXPECT_IMAGE:-45a677435e2af01c5c77dd60692f60ce9482eaa51725fd983717e552d873c0d0}
EXPECT_DTB=${EXPECT_DTB:-d1e2267f5e945acff73f7a8973af9fcbb2d777faf26771e2a7e75687537ffda8}

QUIET=0
P1=""
while [ $# -gt 0 ]; do
    case "$1" in
        --quiet) QUIET=1; shift ;;
        --p1)    P1="${2:-}"; shift 2 ;;
        --expect-image) EXPECT_IMAGE="${2:-}"; shift 2 ;;
        --expect-dtb)   EXPECT_DTB="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

FAILS=0
WARNS=0
CHECKS=0

fail() { FAILS=$((FAILS + 1)); printf '  FAIL  %s\n' "$*"; }
warn() { WARNS=$((WARNS + 1)); printf '  WARN  %s\n' "$*"; }
ok()   { CHECKS=$((CHECKS + 1)); [ "$QUIET" = 1 ] || printf '  ok    %s\n' "$*"; }
note() { [ "$QUIET" = 1 ] || printf '  ..    %s\n' "$*"; }

section() { [ "$QUIET" = 1 ] || { echo; echo "=== $* ==="; }; }

# ---------------------------------------------------------------- 1. identity
section "identity"
if [ -f /etc/eon-release ]; then
    ok "/etc/eon-release exists"
    if grep -q '^NAME="EON Linux"' /etc/eon-release; then
        ok "the product name is EON Linux"
    else
        fail "/etc/eon-release does not say NAME=\"EON Linux\""
    fi
else
    fail "/etc/eon-release is missing"
fi

for f in /etc/issue /etc/issue.net; do
    if [ -f "$f" ]; then
        if grep -q 'EON Linux' "$f"; then
            ok "$f carries the EON Linux banner"
        else
            fail "$f does not carry the EON Linux banner"
        fi
    else
        fail "$f is missing"
    fi
done

# The vendor's strings must not survive in anything a user reads at login.
vendor=$(grep -rilE 'qubian|quban|devmfc' \
         /etc/issue /etc/issue.net /etc/eon-release /etc/motd \
         /etc/update-motd.d 2>/dev/null || true)
if [ -z "$vendor" ]; then
    ok "no vendor branding strings in the login files"
else
    fail "vendor branding strings survive in: $vendor"
fi

# ---------------------------------------------------------------- 2. console
section "console"
if grep -q 'ttyS0' /proc/consoles 2>/dev/null; then
    ok "the serial port is registered as a console (/proc/consoles)"
else
    fail "ttyS0 is not in /proc/consoles"
fi

cmdline=$(cat /proc/cmdline 2>/dev/null || true)
case "$cmdline" in
    *console=ttyS0*) ok "the kernel command line sends the log to ttyS0" ;;
    *)               fail "console=ttyS0 is not on the kernel command line" ;;
esac
case "$cmdline" in
    *console=tty0*) fail "console=tty0 is on the command line; the VT is not the console" ;;
    *)              ok "console=tty0 is not on the command line" ;;
esac

for u in getty@tty1.service serial-getty@ttyS0.service; do
    state=$(systemctl is-active "$u" 2>/dev/null || true)
    if [ "$state" = active ]; then
        ok "$u is active"
    else
        fail "$u is not active (state: ${state:-unknown})"
    fi
done

# ---------------------------------------------------------------- 3. systemd
section "systemd"
failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
if [ "$failed" -eq 0 ]; then
    ok "no failed units"
else
    fail "$failed failed unit(s):"
    systemctl --failed --no-legend 2>/dev/null | sed 's/^/      /'
fi

for u in ssh.service; do
    state=$(systemctl is-active "$u" 2>/dev/null || true)
    if [ "$state" = active ]; then
        ok "$u is active"
    else
        fail "$u is not active (state: ${state:-unknown})"
    fi
done

# ---------------------------------------------------------------- 4. desktop
section "desktop"
desktop=$(dpkg-query -W -f='${Package}\n' 2>/dev/null \
          | grep -cE '^(xfce4|lightdm|xserver-xorg|xinit)$' || true)
if [ "${desktop:-0}" -eq 0 ]; then
    ok "no desktop or display-manager package is installed"
else
    fail "$desktop desktop/display-manager package(s) are installed"
fi

if dpkg-query -W -f='${Package}\n' tasksel 2>/dev/null | grep -qx tasksel; then
    ok "tasksel is present (the later optional-desktop work needs it)"
else
    fail "tasksel is missing"
fi

# ---------------------------------------------------------------- 5. packages
section "packages"
audit=$(dpkg --audit 2>&1 || true)
if [ -z "$audit" ]; then
    ok "dpkg --audit is clean"
else
    fail "dpkg --audit reports problems:"
    printf '%s\n' "$audit" | sed 's/^/      /'
fi

if apt-get check >/tmp/smoke-apt.$$ 2>&1; then
    ok "apt-get check is clean"
else
    fail "apt-get check failed:"
    sed 's/^/      /' /tmp/smoke-apt.$$ | tail -10
fi
rm -f /tmp/smoke-apt.$$

n=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | wc -l)
if [ "$n" -gt 200 ]; then
    ok "$n packages installed"
else
    fail "only $n packages installed; the image looks truncated"
fi

# ---------------------------------------------------------------- 6. boot artefacts
section "boot artefacts"
# Find the boot partition from the root device, so this works whether the
# system booted from the stick (/dev/sda2) or the eMMC (/dev/mmcblk0p2).
rootdev=$(findmnt -n -o SOURCE / 2>/dev/null || true)
case "$rootdev" in
    *[0-9]) P1=${P1:-${rootdev%[0-9]}1} ;;
esac
[ -n "$P1" ] || P1=/dev/mmcblk0p1

if [ -b "$P1" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        warn "not root: skipping the boot-partition check on $P1"
    else
        mnt=$(mktemp -d)
        if mount -o ro "$P1" "$mnt" 2>/dev/null; then
            # If the kernel package is installed, it is the authority.
            if dpkg-query -W -f='${Version}' eon-kernel >/dev/null 2>&1; then
                kver=$(dpkg-query -W -f='${Version}' eon-kernel 2>/dev/null)
                sums="/usr/lib/eon-kernel/$kver/SHA256SUMS"
                if [ -f "$sums" ]; then
                    eimg=$(awk '$2=="Image"{print $1}' "$sums")
                    edtb=$(awk '$2=="sc2_s905x4_ah212_linux.dtb"{print $1}' "$sums")
                    [ -n "$eimg" ] && EXPECT_IMAGE=$eimg
                    [ -n "$edtb" ] && EXPECT_DTB=$edtb
                    note "expected hashes come from eon-kernel $kver"
                else
                    warn "eon-kernel is installed but $sums is missing"
                fi
            else
                note "eon-kernel is not installed; using the built-in hashes"
            fi

            got=$(sha256sum "$mnt/Image" 2>/dev/null | cut -d' ' -f1 || true)
            if [ "$got" = "$EXPECT_IMAGE" ]; then
                ok "p1/Image matches the expected kernel"
            else
                fail "p1/Image is $got, expected $EXPECT_IMAGE"
            fi

            got=$(sha256sum "$mnt/sc2_s905x4_ah212_linux.dtb" 2>/dev/null | cut -d' ' -f1 || true)
            if [ "$got" = "$EXPECT_DTB" ]; then
                ok "p1 DTB matches the expected device tree"
            else
                fail "p1 DTB is $got, expected $EXPECT_DTB"
            fi

            if [ -f "$mnt/aml_autoscript" ]; then
                note "aml_autoscript is present (the stick's first-boot entry)"
            else
                note "aml_autoscript is absent (expected on the eMMC)"
            fi
            umount "$mnt" 2>/dev/null || true
        else
            fail "could not mount the boot partition $P1 read-only"
        fi
        rmdir "$mnt" 2>/dev/null || true
    fi
else
    fail "the boot partition $P1 does not exist"
fi

# ---------------------------------------------------------------- 7. running system
section "running system"
if [ -n "$rootdev" ]; then
    case "$cmdline" in
        *"root=$rootdev"*) ok "the running root is $rootdev, as the command line says" ;;
        *)                 fail "the running root is $rootdev but the command line says otherwise" ;;
    esac
else
    fail "cannot determine the running root device"
fi

if [ -w / ]; then
    ok "the root filesystem is writable"
else
    fail "the root filesystem is read-only"
fi

if [ -e /dev/fb0 ]; then
    ok "/dev/fb0 exists"
else
    fail "/dev/fb0 does not exist"
fi

panics=$(dmesg 2>/dev/null | grep -c 'Kernel panic' || true)
if [ "${panics:-0}" -eq 0 ]; then
    ok "no kernel panic in this boot"
else
    fail "$panics kernel panic message(s) in this boot"
fi

if [ -r /proc/version ]; then
    note "kernel: $(cut -d' ' -f3 /proc/version)"
fi
if [ -r /proc/uptime ]; then
    note "uptime: $(cut -d' ' -f1 /proc/uptime)s"
fi
if [ -r /proc/sys/kernel/random/boot_id ]; then
    note "boot id: $(cat /proc/sys/kernel/random/boot_id)"
fi
if command -v findmnt >/dev/null 2>&1; then
    note "free space on /: $(df -h / 2>/dev/null | awk 'NR==2{print $4" free of "$2}')"
fi
hdcp=$(dmesg 2>/dev/null | grep -ci 'hdcp' || true)
[ "${hdcp:-0}" -gt 0 ] && note "HDCP messages: $hdcp (the vendor TX has no HDCP key; harmless)"

# ---------------------------------------------------------------- summary
echo
if [ "$FAILS" -eq 0 ]; then
    printf '[smoke-test] OK: %d checks passed' "$CHECKS"
    [ "$WARNS" -gt 0 ] && printf ', %d warning(s)' "$WARNS"
    echo
    exit 0
else
    printf '[smoke-test] FAILED: %d violation(s), %d checks passed' "$FAILS" "$CHECKS"
    [ "$WARNS" -gt 0 ] && printf ', %d warning(s)' "$WARNS"
    echo
    exit 1
fi
