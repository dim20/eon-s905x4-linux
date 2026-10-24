#!/bin/bash
# build-kernel-package.sh — build the kernel as an installable Debian package.
#
#     scripts/build-kernel-package.sh --kernel <Image> --dtb <dtb> \
#                                     --version <version> [--out <file>]
#
# WHY A PACKAGE AT ALL
#
#   The kernel lives on the boot partition (p1), which is NOT the root
#   filesystem. That is forced by the vendor's U-Boot: the bootloader
#   loads the kernel from a partition of its own before the root
#   filesystem is even mounted. So a kernel update is not a file copy
#   into /boot - it is a write to another partition, plus a change to
#   the U-Boot environment, plus a rollback story.
#
#   Apt cannot do that by itself. This package does it, and does it
#   safely:
#
#     * the new kernel is written to a VERSIONED name on p1, and the
#       old one is kept, so a failed boot can be rolled back without
#       a stick and without a rebuild;
#     * the U-Boot environment is backed up before it is touched, and
#       restored if the new boot fails;
#     * the write is verified by reading it back from the filesystem
#       after an unmount/remount cycle, not from the page cache.
#
# WHAT IS IN THE PACKAGE
#
#   The kernel Image (34.5 MB) and the device tree. There are NO
#   MODULES: the kernel is built with everything in, so the package has
#   no /lib/modules tree, and that is why it is small.
#
# WHAT IT DOES NOT DO
#
#   It does not install the kernel into the root filesystem's /boot.
#   /boot on the running system is empty: the kernel is not there, it
#   is on p1. Putting a copy in /boot would be a second copy of
#   something that is already on the box, and the two would drift.
#
# THE ROLLBACK
#
#   apt install ./linux-image-sc2_....deb     install a new kernel
#   sc2-kernel-select <version>               choose which one boots
#   sc2-kernel-list                           what is installed
#
#   The package's postinst never changes which kernel boots on its own:
#   installing a kernel is not the same as choosing it. The first
#   installation sets the default, and after that the operator chooses.
#
# SEE ALSO
#
#   docs/kernel-package.md      how this is used, and why
#   manifest/kernel-package.txt what the package must contain

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

KERNEL=""
DTB=""
VERSION=""
OUT=""
WORK=""

die() { printf '[build-kernel-package] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[build-kernel-package] %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel)  KERNEL="${2:-}"; shift 2 ;;
        --dtb)     DTB="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --out)     OUT="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$KERNEL" ]  || die "usage: $0 --kernel <Image> --dtb <dtb> --version <version>"
[ -n "$DTB" ]     || die "--dtb is required"
[ -n "$VERSION" ] || die "--version is required"
[ -f "$KERNEL" ]  || die "no such file: $KERNEL"
[ -f "$DTB" ]     || die "no such file: $DTB"

[ -n "$OUT" ] || OUT="$REPO/dist/linux-image-sc2_${VERSION}_arm64.deb"

# The version must be a valid Debian version: it ends up in a package
# name and in a directory name, and a slash or a space in either is a
# problem three steps later.
case "$VERSION" in
    *[!A-Za-z0-9.+~:-]*) die "the version '$VERSION' has characters a Debian version cannot have" ;;
esac
[ -n "${SOURCE_DATE_EPOCH:-}" ] || die "SOURCE_DATE_EPOCH must be set, or the package is not reproducible"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/pkg/DEBIAN"

# ---------------------------------------------------------------- payload
# The layout is the one the boot code expects. The kernel and the
# device tree are named after the version so that several can be
# installed at once and the operator can choose between them.
install -Dm644 "$KERNEL" "$WORK/pkg/usr/lib/sc2-kernel/$VERSION/Image"
install -Dm644 "$DTB"    "$WORK/pkg/usr/lib/sc2-kernel/$VERSION/sc2_s905x4_ah212_linux.dtb"

# The hashes travel with the package, so that what was installed can
# always be checked against what was published.
{
    echo "# The artefacts this package installs."
    echo "# Verified by the postinst after it writes them to the boot partition."
    ( cd "$WORK/pkg/usr/lib/sc2-kernel/$VERSION" && sha256sum Image sc2_s905x4_ah212_linux.dtb )
} > "$WORK/pkg/usr/lib/sc2-kernel/$VERSION/SHA256SUMS"

# ---------------------------------------------------------------- scripts
install -Dm755 "$HERE/kernel-package/postinst" "$WORK/pkg/DEBIAN/postinst"
install -Dm755 "$HERE/kernel-package/prerm"   "$WORK/pkg/DEBIAN/prerm"
install -Dm755 "$HERE/kernel-package/postrm"  "$WORK/pkg/DEBIAN/postrm"

# The two commands the operator uses.
install -Dm755 "$HERE/kernel-package/sc2-kernel-list"   "$WORK/pkg/usr/sbin/sc2-kernel-list"
install -Dm755 "$HERE/kernel-package/sc2-kernel-select" "$WORK/pkg/usr/sbin/sc2-kernel-select"

# The shared activation logic. The postinst and sc2-kernel-select both
# call it, so there is exactly one implementation of "write a kernel to
# the boot partition, archive what was there, and verify the write".
install -Dm755 "$HERE/kernel-package/activate" "$WORK/pkg/usr/lib/sc2-kernel/activate"

# The documentation ships with the package, so that a box that has the
# package has the instructions even without the internet.
install -Dm644 "$REPO/docs/kernel-package.md" "$WORK/pkg/usr/share/doc/sc2-kernel/$VERSION/kernel-package.md"

# ---------------------------------------------------------------- control
cat > "$WORK/pkg/DEBIAN/control" <<EOF
Package: sc2-kernel
Version: $VERSION
Section: kernel
Priority: optional
Architecture: arm64
Maintainer: sc2-linux contributors
Installed-Size: $(du -ks "$WORK/pkg/usr/lib/sc2-kernel/$VERSION" | cut -f1)
Description: The SC2 Linux kernel for the EON SDSTB02 (Amlogic S905X4), installable and selectable
 The SC2 Linux kernel for the EON SDSTB02 set-top box, packaged so that it can be
 installed with apt and switched between versions without a USB stick and
 without rebuilding anything.
 .
 The kernel is written to the boot partition, which is where the vendor's
 U-Boot reads it from - not to the root filesystem's /boot, which is empty
 on this box. Several versions can be installed at once; sc2-kernel-list
 shows them and sc2-kernel-select chooses which one boots.
 .
 This package contains no modules: the kernel is built with everything
 built in.
EOF

# The md5sums file is what dpkg uses to verify the installed files.
( cd "$WORK/pkg" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' \
    | sort -z | xargs -0 md5sum ) > "$WORK/pkg/DEBIAN/md5sums"

# ---------------------------------------------------------------- build
# dpkg-deb is deterministic if the timestamps are pinned and the
# compression is told not to record a name. SOURCE_DATE_EPOCH is
# honoured by dpkg-deb itself for the member timestamps.
find "$WORK/pkg" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
dpkg-deb --root-owner-group -Zgzip -z9 --build "$WORK/pkg" "$OUT" >/dev/null

log "built $OUT"
dpkg-deb --info "$OUT" | sed 's/^/  /'
echo
sha256sum "$OUT" | sed 's/^/  /'
