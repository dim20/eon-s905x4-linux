#!/bin/bash
# check-patches.sh - do the published patches still build the tree?
#
#   usage: scripts/check-patches.sh [patch-dir] [tree]
#
# For each patch in order: apply it to a pristine copy of the vendor's
# tree, and then compare the result with the tree we actually build.
#
# WHY THIS EXISTS
#
# The patches are the only way anybody else can rebuild this kernel, so
# they have to apply to the vendor's tree and produce the same result.
# They did not: 0005 had been generated against a tree that already had
# part of its own change in it, so it did not apply, and 0006's
# justification was wrong (the "missing flush" turned out not to be
# missing at all).
#
# The patches are applied with "patch -p1", the way a person would.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCHES="${1:-$HERE/../patches}"
TREE="${2:-$HERE/../build/linux}"
WORK="$(mktemp -d)"

trap 'rm -rf "$WORK"' EXIT

echo "the patches: $PATCHES"
echo "the tree:    $TREE"

if [ ! -d "$TREE/.git" ]; then
    echo "the tree is not a git checkout - cannot take the pristine files from it" >&2
    exit 1
fi

# The files the patches touch, taken from the patch headers. Both forms
# are used in the wild: "diff --git a/x b/x" and a bare "--- a/x".
FILES=$( { grep -h "^diff --git " "$PATCHES"/*.patch 2>/dev/null |
           sed 's|^diff --git a/||; s| b/.*$||'
           grep -h "^--- a/" "$PATCHES"/*.patch 2>/dev/null |
           sed 's|^--- a/||'; } | sort -u)
if [ -z "$FILES" ]; then
    echo "no patches found in $PATCHES" >&2
    exit 1
fi

echo "=== the files the patches touch ==="
echo "$FILES" | sed 's/^/  /'

# A pristine copy of just those files.
for f in $FILES; do
    mkdir -p "$WORK/$(dirname "$f")"
    if ! git -C "$TREE" show "HEAD:$f" > "$WORK/$f" 2>/dev/null; then
        echo "  (no pristine copy of $f - it is a new file)"
        rm -f "$WORK/$f"
    fi
done

echo "=== applying the patches, in order ==="
for p in "$PATCHES"/*.patch; do
    name=$(basename "$p")
    if patch -d "$WORK" -p1 --dry-run --forward < "$p" > /tmp/patch-out.$$ 2>&1; then
        patch -d "$WORK" -p1 --forward < "$p" > /dev/null 2>&1
        printf "  %-44s applies\n" "$name"
    else
        printf "  %-44s DOES NOT APPLY\n" "$name"
        sed 's/^/      /' /tmp/patch-out.$$ | head -8
        rm -f /tmp/patch-out.$$
        continue
    fi
    rm -f /tmp/patch-out.$$
done

echo "=== does the result match the tree we build? ==="
rc=0
for f in $FILES; do
    [ -f "$WORK/$f" ] || continue
    printf "  %-44s " "$f"
    if diff -q "$WORK/$f" "$TREE/$f" > /dev/null 2>&1; then
        echo "identical"
    else
        echo "DIFFERS"
        rc=1
    fi
done

if [ $rc -eq 0 ]; then
    echo "  the patches reproduce the tree"
else
    echo "  THE PATCHES DO NOT REPRODUCE THE TREE"
fi
exit $rc
