#!/bin/bash
# inventory.sh — write a listing of everything in a rootfs, and diff it
# against the previous one.
#
#     scripts/inventory.sh --rootfs <dir> [--out <file>] [--diff <file>]
#
# The inventory is the record of what the image contains. It answers two
# questions that nothing else answers:
#
#   1. "which files must remain in the image" - by being the full list of
#      them, with their owner, mode, size and checksum
#   2. "what changed between this build and the last one" - by being
#      diffable
#
# The format is one line per entry, sorted by path:
#
#     <type> <mode> <uid>:<gid> <size> <sha256-or-link-target> <path>
#
#   f  regular file      d  directory      l  symlink
#
# A "-" means "not applicable" (a directory has no checksum; a symlink
# has no size that means anything).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

ROOTFS=""
OUT=""
DIFF=""
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs)   ROOTFS="${2:-}"; shift 2 ;;
        --out)      OUT="${2:-}"; shift 2 ;;
        --diff)     DIFF="${2:-}"; shift 2 ;;
        --quiet)    QUIET=1; shift ;;
        -h|--help)  sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$ROOTFS" ] || { echo "usage: $0 --rootfs <dir> [--out <file>] [--diff <file>]" >&2; exit 2; }
[ -d "$ROOTFS" ] || { echo "not a directory: $ROOTFS" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
TAB=$(printf '\t')

# --- the checksums --------------------------------------------------------
# find -exec sha256sum {} + batches them, so this is a handful of
# processes rather than one per file.
find "$ROOTFS" -mindepth 1 -type f -exec sha256sum {} + 2>/dev/null \
    | sed "s|^${ROOTFS}/||" \
    | awk '{ hash=$1; $1=""; sub(/^[ \t]+/, ""); print hash "\t" $0 }' \
    | sort > "$WORK/hashes"

# --- the symlink targets --------------------------------------------------
find "$ROOTFS" -mindepth 1 -type l -printf '%P\t%l\n' 2>/dev/null \
    | sort > "$WORK/links"

# --- the metadata ---------------------------------------------------------
find "$ROOTFS" -mindepth 1 -printf '%y\t%m\t%U:%G\t%s\t%P\n' 2>/dev/null \
    | sort -t"$TAB" -k5,5 > "$WORK/meta"

# --- merge ----------------------------------------------------------------
# The metadata is the spine; the checksums and the link targets are
# looked up by path.
awk -F'\t' '
    BEGIN { FS = "\t" }
    FILENAME == ARGV[1] { hash[$1] = $2; next }
    FILENAME == ARGV[2] { link[$1] = $2; next }
    {
        type = $1; mode = $2; owner = $3; size = $4; path = $5
        if (type == "f") {
            h = (path in hash) ? hash[path] : "-"
        } else if (type == "l") {
            h = (path in link) ? link[path] : "-"
            size = "-"          # for a link, the size would be the length of its target
        } else {
            h = "-"
            size = "-"          # for a directory, the size would be its inode size
        }
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", type, mode, owner, size, h, path
    }
' "$WORK/hashes" "$WORK/links" "$WORK/meta" \
    | sort -t"$TAB" -k6,6 > "$WORK/inventory"

if [ -n "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")"
    cp "$WORK/inventory" "$OUT"
    echo "[inventory] wrote $OUT ($(wc -l < "$WORK/inventory") entries)"
fi

# --- the diff -------------------------------------------------------------
if [ -n "$DIFF" ] && [ -f "$DIFF" ]; then
    read -r added removed changed <<EOF
$(awk -F'\t' '
    BEGIN { FS = "\t" }
    FILENAME == ARGV[1] { old[$6] = $0; next }
    FILENAME == ARGV[2] {
        if ($6 in old) { if (old[$6] != $0) changed++ }
        else { added++ }
        seen[$6] = 1
        next
    }
    END {
        for (p in old) if (!(p in seen)) removed++
        printf "%d %d %d\n", added, removed, changed
    }
' "$DIFF" "$WORK/inventory")
EOF
    echo "[inventory] against $DIFF:"
    echo "[inventory]   $added added, $removed removed, $changed changed"
    if [ "$QUIET" = 0 ] && [ "$(( added + removed + changed ))" != 0 ]; then
        diff -u "$DIFF" "$WORK/inventory" | head -80 | sed 's/^/    /'
    fi
elif [ -n "$DIFF" ]; then
    echo "[inventory] no baseline at $DIFF - this build is the first record"
fi

exit 0
