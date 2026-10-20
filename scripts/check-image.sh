#!/bin/bash
# check-image.sh — check an image against the manifest.
#
#     scripts/check-image.sh --rootfs <dir> [--p1 <image>] [--manifest <dir>]
#
# The manifest is data, not code: manifest/ says what the image must
# contain and what it must not. This script is the only thing that reads
# it, so the rules live in one place and can be reviewed as a list rather
# than as code.
#
# It checks the SHIPPED ARTEFACT, not the input it was built from. That
# distinction matters: a defect introduced while assembling the image
# would pass a check that ran against the input.
#
# Exit status: 0 if everything passes, 1 if anything does not. Every
# violation is reported, not just the first one - a build that fails
# should tell you everything that is wrong with it.
#
# See manifest/ for the format of each file.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

ROOTFS=""
P1=""
MANIFEST="$REPO/manifest"
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs)   ROOTFS="${2:-}"; shift 2 ;;
        --p1)       P1="${2:-}"; shift 2 ;;
        --manifest) MANIFEST="${2:-}"; shift 2 ;;
        --quiet)    QUIET=1; shift ;;
        -h|--help)  sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$ROOTFS" ] || { echo "usage: $0 --rootfs <dir> [--p1 <image>]" >&2; exit 2; }
[ -d "$ROOTFS" ] || { echo "not a directory: $ROOTFS" >&2; exit 2; }
[ -d "$MANIFEST" ] || { echo "no manifest directory: $MANIFEST" >&2; exit 2; }

FAILS=0
CHECKS=0

fail() { FAILS=$((FAILS + 1)); printf '  FAIL  %s\n' "$*"; }
ok()   { CHECKS=$((CHECKS + 1)); }
note() { [ "$QUIET" = 1 ] || printf '  %s\n' "$*"; }

# The list of non-comment, non-blank lines of a manifest file.
entries() {
    sed -e 's/#.*$//' -e 's/[[:space:]]*$//' "$1" 2>/dev/null | grep -v '^$'
}

# The names of every package dpkg believes is installed.
installed_packages() {
    awk '/^Package: /{print substr($0, 10)}' "$1" 2>/dev/null | sort -u
}

# ---------------------------------------------------------------- packages
check_packages() {
    local list=$1 kind=$2
    local status="$ROOTFS/var/lib/dpkg/status"
    [ -f "$status" ] || { fail "no dpkg status file at $status - cannot check packages"; return; }
    local installed p
    installed=$(installed_packages "$status")
    while read -r p; do
        [ -n "$p" ] || continue
        if printf '%s\n' "$installed" | grep -Fxq "$p"; then
            # it is installed
            if [ "$kind" = required ]; then
                ok
            else
                fail "the package '$p' is FORBIDDEN but is installed"
            fi
        else
            # it is not installed
            if [ "$kind" = required ]; then
                fail "the package '$p' is required but is NOT installed"
            else
                ok
            fi
        fi
    done < <(entries "$list")
}

# ---------------------------------------------------------------- paths
check_required_paths() {
    local line path mode actual
    while read -r line; do
        [ -n "$line" ] || continue
        path="${line%% *}"
        mode="${line#* }"
        [ "$mode" = "$line" ] && mode=""     # no second field
        if [ ! -e "$ROOTFS$path" ] && [ ! -L "$ROOTFS$path" ]; then
            fail "the required path '$path' is missing"
            continue
        fi
        ok
        if [ -n "$mode" ]; then
            # A symlink's own mode is always 777, which says nothing, so
            # for a symlink we check that it resolves instead.
            if [ -L "$ROOTFS$path" ]; then
                if [ ! -e "$ROOTFS$path" ]; then
                    fail "the path '$path' is a symlink that does not resolve"
                else
                    ok
                fi
                continue
            fi
            # stat prints the mode without a leading zero ("755"), the
            # manifest may write it with one ("0755"). Compare as octal
            # numbers so both spellings mean the same thing.
            actual=$(stat -c %a "$ROOTFS$path" 2>/dev/null)
            if [ "$(( 8#$actual ))" != "$(( 8#$mode ))" ]; then
                fail "the path '$path' has mode $actual, expected $mode"
            else
                ok
            fi
        fi
    done < <(entries "$MANIFEST/required-paths.txt")
}

check_forbidden_paths() {
    local pattern path rel e
    local exceptions=()

    while read -r pattern; do
        [ -n "$pattern" ] || continue
        case "$pattern" in
            \!*) exceptions+=("${pattern#!}") ;;
        esac
    done < <(entries "$MANIFEST/forbidden-paths.txt")

    while read -r pattern; do
        [ -n "$pattern" ] || continue
        case "$pattern" in
            \!*) continue ;;
        esac
        rel="${pattern#/}"
        while read -r path; do
            [ -n "$path" ] || continue
            local exempt=0
            for e in "${exceptions[@]:-}"; do
                [ -n "$e" ] || continue
                # an exception may itself be a glob
                case "$path" in
                    "$ROOTFS/${e#/}") exempt=1; break ;;
                esac
            done
            if [ "$exempt" = 1 ]; then ok; continue; fi
            fail "the forbidden path '${path#$ROOTFS}' is present"
        done < <(find "$ROOTFS" -mindepth 1 -path "$ROOTFS/$rel" -print 2>/dev/null)
    done < <(entries "$MANIFEST/forbidden-paths.txt")
}

# ---------------------------------------------------------------- units
check_units() {
    local unit d
    while read -r unit; do
        [ -n "$unit" ] || continue
        local found=no
        for d in "$ROOTFS"/etc/systemd/system/*.wants; do
            [ -d "$d" ] || continue
            if [ -e "$d/$unit" ] || [ -L "$d/$unit" ]; then found=yes; break; fi
        done
        if [ "$found" = yes ]; then
            ok
        else
            fail "the unit '$unit' is not enabled (no symlink in any *.wants directory)"
        fi
    done < <(entries "$MANIFEST/required-units.txt")
}

# ---------------------------------------------------------------- global
check_global() {
    local line key value p missing names n bad
    # read from fd 3, so that the commands run inside the loop cannot
    # consume the file we are reading
    while read -r line <&3; do
        line="${line%%#*}"
        line="$(echo "$line" | sed -e 's/[[:space:]]*$//')"
        [ -n "$line" ] || continue
        key="${line%%=*}"
        value="${line#*=}"
        key="$(echo "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        value="$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$key" in
            rootfs-owner)
                bad=$(find "$ROOTFS" -mindepth 1 \( ! -uid "${value%%:*}" -o ! -gid "${value##*:}" \) -print 2>/dev/null | head -5)
                if [ -n "$bad" ]; then
                    n=$(find "$ROOTFS" -mindepth 1 \( ! -uid "${value%%:*}" -o ! -gid "${value##*:}" \) -print 2>/dev/null | wc -l)
                    fail "$n path(s) are not owned by $value, for example:"
                    printf '%s\n' "$bad" | sed "s|^$ROOTFS|          |" | head -5
                else
                    ok
                fi
                ;;
            package-file-lists)
                if [ "$value" != required ]; then
                    fail "unknown value for '$key': '$value'"
                    continue
                fi
                local status="$ROOTFS/var/lib/dpkg/status"
                [ -f "$status" ] || { fail "no dpkg status file"; continue; }
                missing=0; names=""
                while read -r p; do
                    [ -n "$p" ] || continue
                    # A multi-arch package's dpkg files are named with the
                    # architecture: "libacl1:arm64.list", not "libacl1.list".
                    has=no
                    for g in "$ROOTFS"/var/lib/dpkg/info/"$p".list \
                             "$ROOTFS"/var/lib/dpkg/info/"$p":*.list; do
                        [ -f "$g" ] && { has=yes; break; }
                    done
                    if [ "$has" = no ]; then
                        missing=$((missing + 1))
                        [ ${#names} -lt 200 ] && names="$names $p"
                    fi
                done < <(installed_packages "$status")
                if [ "$missing" -gt 0 ]; then
                    fail "$missing installed package(s) have no file list in the dpkg database:$names"
                else
                    ok
                fi
                ;;
            *)
                fail "unknown key in manifest/global.txt: '$key'
  An unknown key is an error, not a warning: a rule that is silently
  ignored looks like protection and is not."
                ;;
        esac
    done 3< "$MANIFEST/global.txt"
}

# ---------------------------------------------------------------- p1
check_p1() {
    [ -n "$P1" ] || return 0
    [ -f "$P1" ] || { fail "the boot partition image $P1 does not exist"; return; }
    command -v mdir >/dev/null || { fail "mtools is not installed - cannot check the boot partition"; return; }
    local name
    while read -r name; do
        [ -n "$name" ] || continue
        if mdir -i "$P1" "::/$name" >/dev/null 2>&1; then
            ok
        else
            fail "the boot artefact '$name' is not at the ROOT of the boot partition"
        fi
    done < <(entries "$MANIFEST/boot-artifacts.txt")

    # the kernel and the device tree must be the ones we published
    local sums="$REPO/kernel/SHA256SUMS"
    if [ -f "$sums" ]; then
        local f want got
        for f in Image sc2_s905x4_ah212_linux.dtb; do
            want=$(awk -v n="$f" '$2==n{print $1}' "$sums")
            [ -n "$want" ] || continue
            got=$(mtype -i "$P1" "::/$f" 2>/dev/null | sha256sum | cut -d' ' -f1)
            if [ "$got" = "$want" ]; then
                ok
            else
                fail "the $f on the boot partition is $got, expected $want (kernel/SHA256SUMS)"
            fi
        done
    fi
}

# ---------------------------------------------------------------- run
if [ "$QUIET" = 0 ]; then
    echo "[check-image] checking $ROOTFS against $MANIFEST"
fi

[ -f "$MANIFEST/required-packages.txt" ] && check_packages "$MANIFEST/required-packages.txt" required
[ -f "$MANIFEST/forbidden-packages.txt" ] && check_packages "$MANIFEST/forbidden-packages.txt" forbidden
check_required_paths
check_forbidden_paths
[ -f "$MANIFEST/required-units.txt" ] && check_units
[ -f "$MANIFEST/global.txt" ] && check_global
check_p1

# The vendor leftovers are a record, not a check, but they should be
# visible whenever the image is checked.
if [ -f "$MANIFEST/vendor-leftovers.txt" ] && [ "$QUIET" = 0 ]; then
    n=$(grep -c '^## ' "$MANIFEST/vendor-leftovers.txt" 2>/dev/null || echo 0)
    echo "  note: $n recorded vendor leftover(s) in manifest/vendor-leftovers.txt"
fi

if [ "$FAILS" -gt 0 ]; then
    echo "[check-image] FAILED: $FAILS violation(s)"
    exit 1
fi
[ "$QUIET" = 0 ] && echo "[check-image] OK: $CHECKS checks passed"
exit 0
