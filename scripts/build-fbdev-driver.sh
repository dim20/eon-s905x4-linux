#!/bin/bash
# build-fbdev-driver.sh - build the patched fbdev X driver.
#
#   usage: scripts/build-fbdev-driver.sh [--box <host>] [--install]
#
# STATUS: FROZEN (P2, desktop). This is not run by any release target and
# its output is not in any published image. The TTY product does not need
# it. It is kept because it records the fb24_32 work, and it will come
# back with the optional desktop package set after v0.7-tty.
#
# WHY
#
# The X server's screen visual is 24 bits deep inside a 32-bit
# framebuffer, so the X server's own rasteriser - the font engine and
# the mouse pointer - writes three bytes to a pixel into a framebuffer
# that stores four, and the text and the pointer come out unreadable.
# Everything a client draws is fine, which is why it looks like a
# driver bug rather than a depth bug.
#
# The fix is in the fbdev X driver (xserver-xorg-video-fbdev): it has
# to ask for a 32-bit visual when the framebuffer has an alpha
# channel, and it has to set the visual's weights itself, because
# xf86SetWeight() has no case for depth 32 and refuses it.
#
# SEE ALSO
#
#   patches/xserver-xorg-video-fbdev/0001-depth-32.patch
#
# THE BUILD
#
# The driver has to be built for the box's architecture - aarch64 - so
# it cannot be built on an x86 build machine without a cross
# toolchain. The box itself is a Debian, so the driver is built there.
# The build needs:
#
#   build-essential pkg-config libxfont-dev libpixman-1-dev
#   x11proto-dev xserver-xorg-dev
#
# and the source of xserver-xorg-video-fbdev (0.5.0).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PATCH="$REPO/patches/xserver-xorg-video-fbdev/0001-depth-32.patch"
SRCTAR=xserver-xorg-video-fbdev_0.5.0.orig.tar.gz
SRCDIR=xf86-video-fbdev-0.5.0

BOX=""
INSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --box) BOX="${2:-}"; shift 2 ;;
        --install) INSTALL=1; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

WORK="${WORK:-$(mktemp -d)}"
echo "[fbdev-driver] working in $WORK"

# ---------------------------------------------------------------- the source
if [ ! -f "$WORK/$SRCTAR" ]; then
    URL="http://deb.debian.org/debian/pool/main/x/xserver-xorg-video-fbdev/$SRCTAR"
    echo "[fbdev-driver] fetching $SRCTAR"
    curl -sSL -o "$WORK/$SRCTAR" "$URL"
fi
cd "$WORK"
rm -rf "$SRCDIR"
tar xzf "$SRCTAR"

# ---------------------------------------------------------------- the patch
echo "[fbdev-driver] applying the patch"
patch -p1 -d "$SRCDIR" < "$PATCH"

# ---------------------------------------------------------------- the build
if [ -n "$BOX" ]; then
    echo "[fbdev-driver] copying the source to $BOX"
    tar czf fbdev-src.tar.gz "$SRCDIR"
    scp -o StrictHostKeyChecking=no fbdev-src.tar.gz "$BOX:/root/"
    ssh "$BOX" "cd /root && rm -rf $SRCDIR && tar xzf fbdev-src.tar.gz && cd $SRCDIR && \
        ./configure --with-xorg-module-dir=/usr/lib/xorg/modules && make -j4 && \
        ls -la src/.libs/fbdev_drv.so"
    if [ "$INSTALL" = 1 ]; then
        echo "[fbdev-driver] installing it on $BOX"
        ssh "$BOX" "cp /root/$SRCDIR/src/.libs/fbdev_drv.so \
            /usr/lib/xorg/modules/drivers/fbdev_drv.so && \
            systemctl restart lightdm && sleep 15 && \
            grep -E 'FBDEV.*Depth' /var/log/Xorg.0.log | tail -1"
    fi
else
    cd "$SRCDIR"
    ./configure --with-xorg-module-dir=/usr/lib/xorg/modules
    make -j4
    ls -la src/.libs/fbdev_drv.so
fi
