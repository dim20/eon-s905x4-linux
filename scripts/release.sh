#!/bin/bash
# release.sh — build a release, check it, and say what to do next.
#
#     scripts/release.sh --name <release> --tree <rootfs-tree>
#
# One command, so that a release is never assembled by hand:
#
#   1. build the image  (the build checks it against the manifest, and
#                        refuses to produce an image that fails)
#   2. write the inventory and show what changed since the last release
#   3. write the checksums for the release's assets
#   4. print the hardware test checklist - the one part that cannot be
#      automated, so it is printed rather than remembered
#
# The artefacts are left in dist/ ready to upload:
#   dist/<name>-img.gz        the stick image
#   dist/Image                the kernel
#   dist/sc2_s905x4_ah212_linux.dtb   the device tree
#   dist/SHA256SUMS           their checksums
#   dist/inventory.txt        what is in the image, file by file
#   dist/TEST-CHECKLIST.md    what a human has to do next

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

NAME=""
TREE=""
DIST="$REPO/dist"

while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="${2:-}"; shift 2 ;;
        --tree) TREE="${2:-}"; shift 2 ;;
        --dist) DIST="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$NAME" ] || { echo "usage: $0 --name <release> --tree <rootfs-tree>" >&2; exit 2; }
[ -n "$TREE" ] || { echo "usage: $0 --name <release> --tree <rootfs-tree>" >&2; exit 2; }
[ -d "$TREE" ] || { echo "not a directory: $TREE" >&2; exit 2; }

mkdir -p "$DIST"

# ---------------------------------------------------------------- 1. build
echo
echo "=== 1. building the image ==========================================="
"$HERE/build-stick-image.sh" "$TREE" "$DIST/$NAME-img.gz"

# ---------------------------------------------------------------- 2. record
echo
echo "=== 2. the record ==================================================="
# The inventory is the answer to "which files must remain in the image",
# written out, file by file. The baseline in the repo is what the NEXT
# build is compared against.
if [ -f "$REPO/manifest/inventory.txt" ]; then
    "$HERE/inventory.sh" --rootfs "$TREE" --diff "$REPO/manifest/inventory.txt" || true
else
    echo "[release] no baseline inventory yet - this is the first record"
fi
cp "$DIST/inventory.txt" "$REPO/manifest/inventory.txt"
echo "[release] the baseline inventory is now manifest/inventory.txt"

# ---------------------------------------------------------------- 3. hashes
echo
echo "=== 3. the checksums ================================================"
cp "$REPO/kernel/Image" "$DIST/Image"
cp "$REPO/kernel/sc2_s905x4_ah212_linux.dtb" "$DIST/sc2_s905x4_ah212_linux.dtb"
{
    echo "# $NAME"
    echo "# verify with: sha256sum -c SHA256SUMS"
    ( cd "$DIST" && sha256sum "$NAME-img.gz" Image sc2_s905x4_ah212_linux.dtb )
} > "$DIST/SHA256SUMS"
cat "$DIST/SHA256SUMS"

# ---------------------------------------------------------------- 4. the box
echo
echo "=== 4. what a human has to do ======================================="
cat > "$DIST/TEST-CHECKLIST.md" <<EOF
# $NAME - the hardware test

Everything below needs a person, a box and a television. The automated
checks are done; these are the ones that cannot be.

- [ ] Write the image to a USB stick **from the eMMC system**, never from
      the stick itself. The box must not be running from the stick while
      it is being written.

      gunzip -c $NAME-img.gz | sudo dd of=/dev/sdX bs=4M status=progress
      sync

- [ ] Verify the stick against the image, in full:

      gunzip -c $NAME-img.gz | cmp - /dev/sdX

      A hash of a prefix is NOT a verification: it reads through the page
      cache and will report a corrupt stick as clean.

- [ ] Boot the stick. On the television there must be a TEXT CONSOLE, not
      a black screen. Then:

      findmnt -n -o SOURCE /          # /dev/sda2
      dmesg | grep -c "Taking over console"   # 1
      dmesg | grep -ciE "Kernel panic|Internal error"   # 0

- [ ] Run the installer from the stick:

      /root/install-to-emmc.sh

      It must end with the env restored and verified, the conditional
      bootcmd set and verified, and the boot artefacts verified.

- [ ] UNPLUG THE STICK and power-cycle the box. With nothing plugged in it
      must boot the eMMC on its own, with the text console on the
      television again.

      findmnt -n -o SOURCE /          # /dev/mmcblk0p2
      dmesg | grep -c "Taking over console"   # 1

- [ ] Confirm the stick does NOT grow any more: the vendor's stick-growing
      script has been removed from the image.

      ls /dev/sda2 >/dev/null && df -h /dev/sda2
EOF
cat "$DIST/TEST-CHECKLIST.md"

echo
echo "=== done ==========================================================="
echo "  the artefacts are in $DIST"
echo "  the image is: $DIST/$NAME-img.gz"
echo "  sha256:      $(sha256sum "$DIST/$NAME-img.gz" | cut -d' ' -f1)"
echo
echo "  The hardware test above has NOT been done yet. Do not publish"
echo "  before it has."
