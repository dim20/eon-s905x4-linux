#!/bin/bash
# check-docs.sh — the documentation's own checks.
#
#     scripts/check-docs.sh
#
# Documentation drifts silently: a link stops resolving, a version string
# is left behind, a renamed file is still required under its old name. None
# of that is caught by building the image, because none of it is in the
# image. This script checks the claims that can be checked mechanically.
#
# What it checks:
#   1. README.md mentions the version in kernel/VERSION.
#   2. The latest release in docs/releases/ is mentioned in README.md.
#   3. Every relative Markdown link resolves.
#   4. The branding overrides contain no vendor strings.
#   5. Every login file the manifest requires has an override source.
#
# Exit status: 0 if everything passes, 1 if anything does not.
#
# It does not check that prose is true. That is what the manifest, the
# release notes and the evidence rule in docs/README.md are for.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO" || exit 2

FAILS=0
CHECKS=0
fail() { FAILS=$((FAILS + 1)); printf '  FAIL  %s\n' "$*"; }
ok()   { CHECKS=$((CHECKS + 1)); }

echo "[check-docs] checking the documentation in $REPO"

# ---------------------------------------------------------------- version
# The release label is the package's identity; README is the one place
# that states the current product, so it has to name it.
if [ -f kernel/VERSION ]; then
    KVER=$(tr -d '[:space:]' < kernel/VERSION)
    if [ -z "$KVER" ]; then
        fail "kernel/VERSION is empty"
    elif grep -qF "$KVER" README.md; then
        ok
    else
        fail "README.md does not mention the kernel release label '$KVER'"
    fi
else
    fail "kernel/VERSION is missing"
fi

# ---------------------------------------------------------------- releases
# The latest release is the highest v* slug among the release notes.
# README must name it, and there must be notes for it.
latest=$(printf '%s\n' docs/releases/v*.md 2>/dev/null | sort -V | tail -1)
case "$latest" in
    *'*'*) fail "docs/releases/ contains no release notes"
           latest="" ;;
esac
if [ -n "$latest" ] && [ -f "$latest" ]; then
    slug=$(basename "$latest" .md)
    if grep -qF "$slug" README.md; then
        ok
    else
        fail "the latest release '$slug' is not mentioned in README.md"
    fi
    ok
fi

# ---------------------------------------------------------------- links
# Relative links only. Anchors are stripped; external URLs are not fetched
# (the check must work offline, and a network failure is not a docs bug).
while IFS= read -r md; do
    dir=$(dirname "$md")
    while IFS= read -r link; do
        [ -n "$link" ] || continue
        case "$link" in
            http://*|https://*|mailto:*|tel:*|'#'*) continue ;;
            /*) continue ;;                     # site-absolute; not ours
        esac
        target=${link%%#*}
        [ -n "$target" ] || continue
        target=${target%\"}                     # tolerate "title" quoting
        target=${target% }
        if [ -e "$dir/$target" ] || [ -L "$dir/$target" ]; then
            ok
        else
            fail "$md links to '$link', which does not exist"
        fi
    done < <(grep -oE '\]\([^)]+\)' "$md" 2>/dev/null | sed -e 's/^](//' -e 's/)$//')
done < <(find . -name '*.md' -not -path './.git/*' -print | sort)

# ---------------------------------------------------------------- branding
# The same vendor strings the image check forbids, applied to the SOURCE
# of the login files. Catching them here means a bad override never reaches
# an image at all.
BRAND_FILES=(scripts/overrides/etc/issue
             scripts/overrides/etc/issue.net
             scripts/overrides/etc/eon-release
             scripts/overrides/motd/01-eon-header
             scripts/overrides/motd/15-eon-system-state)
for f in "${BRAND_FILES[@]}"; do
    [ -f "$f" ] || continue
    if grep -Eqi 'qubian|dev[[:space:]]*mfc' "$f"; then
        fail "$f contains a vendor string (QUBIAN/qubian or DEVMFC/devmfc)"
    else
        ok
    fi
done

# ---------------------------------------------------------------- sources
# Every login file the manifest requires must come from an override, or a
# rename lands in the manifest while the build quietly keeps the old file.
for path in /etc/issue /etc/issue.net /etc/eon-release \
            /etc/update-motd.d/01-eon-header \
            /etc/update-motd.d/15-eon-system-state; do
    grep -qE "^${path}([[:space:]]|$)" manifest/required-paths.txt || continue
    case "$path" in
        /etc/update-motd.d/*) src="scripts/overrides/motd/$(basename "$path")" ;;
        *)                    src="scripts/overrides/etc/$(basename "$path")" ;;
    esac
    if [ -f "$src" ]; then
        ok
    else
        fail "manifest/required-paths.txt requires '$path' but there is no source at $src"
    fi
done

if [ "$FAILS" -gt 0 ]; then
    echo "[check-docs] FAILED: $FAILS problem(s)"
    exit 1
fi
echo "[check-docs] OK: $CHECKS checks passed"
exit 0
