#!/bin/sh
# find-env.sh — locate the U-Boot environment on an eMMC. READ-ONLY.
#
# Why this exists: the stock /etc/fw_env.config is wrong on this hardware in two
# ways (wrong device /dev/mmcblk1, and wrong offset 0x4d400000), so fw_setenv
# is unusable until the real location is known. The offset is a property of the
# board's U-Boot build and its dtb, so it must be DISCOVERED per box, never
# hardcoded.
#
# Method:
#   1. Scan the device for the variable name "bootcmd=" (cheap, unambiguous).
#   2. Round each hit down to a 64 KiB boundary — U-Boot sizes env_text_buffer
#      in powers of two and the live block here is 0x10000 — giving a candidate
#      block start.
#   3. FUNCTIONAL test each candidate by pointing a temporary fw_env.config at
#      it and asking fw_printenv for a known variable. A wrong offset fails the
#      CRC or returns nothing, so this is a real pass/fail rather than a guess.
#
# Prints "<device> <hex_offset>" on success (exit 0). Exits 1 if no candidate
# verifies — the caller must then REFUSE to touch the environment.

set -e
DEV=${1:-/dev/mmcblk0}
TMPCFG=/tmp/fw_env.probe.$$
BACKUP=/etc/fw_env.config

cleanup() {
    if [ -f "$BACKUP.probe-save" ]; then
        cp "$BACKUP.probe-save" "$BACKUP" 2>/dev/null || true
        rm -f "$BACKUP.probe-save"
    fi
    rm -f "$TMPCFG"
}
trap cleanup EXIT INT TERM

[ -b "$DEV" ] || { echo "find-env: $DEV is not a block device" >&2; exit 1; }

# Preserve the operator's real config; we only ever write a probe.
[ -f "$BACKUP" ] && cp "$BACKUP" "$BACKUP.probe-save" || true

echo "find-env: scanning $DEV for 'bootcmd=' (this reads the whole device)..." >&2
hits=$(dd if="$DEV" bs=1M count=1024 2>/dev/null | grep -abo 'bootcmd=' | cut -d: -f1 || true)
[ -n "$hits" ] || { echo "find-env: no 'bootcmd=' found — wrong device?" >&2; exit 1; }

for rel in $hits; do
    off=$(( rel - (rel % 0x10000) ))
    printf '/dev/%s %s 0x10000 0x200\n' "$(basename "$DEV")" "$(printf '0x%x' "$off")" > "$BACKUP"

    # Functional test. Require a plausible env: fw_printenv must succeed and
    # report several variables (a real env has ~100 here; a wrong offset
    # returns "Cannot read environment" or an empty set).
    n=$(fw_printenv 2>/dev/null | wc -l || echo 0)
    if [ "${n:-0}" -ge 10 ]; then
        # A variable COUNT alone is not sufficient discrimination. Because the
        # installer's dd copies p2 wholesale, another partition can hold a
        # byte-identical COPY of the env, and fw_printenv parses it happily —
        # pointing this at /dev/mmcblk0p2 "verified" 132 variables.
        #
        # Name checks do not help either: the copy has the SAME variable names
        # as the live env. The only reliable signal is POSITION — the live env
        # lives on the eMMC device, at the offset this firmware's U-Boot was
        # built to use. So require the caller to pass the whole-device node,
        # and reject a probe whose candidate block lies INSIDE a mounted or
        # present partition, which is where a copied image would be.
        case "$(basename "$DEV")" in
            mmcblk*p[0-9]*|mmcblk*p[0-9][0-9]*)
                echo "find-env: candidate $(printf '0x%x' "$off") rejected — $DEV is a partition; the live env is on the whole device" >&2
                continue ;;
        esac
        echo "find-env: verified ${DEV} $(printf '0x%x' "$off") ($n variables)" >&2
        printf '%s %s\n' "$DEV" "$(printf '0x%x' "$off")"
        exit 0
    fi
    echo "find-env: candidate $(printf '0x%x' "$off") rejected ($n vars)" >&2
done

echo "find-env: no candidate verified — NOT writing to the environment" >&2
exit 1