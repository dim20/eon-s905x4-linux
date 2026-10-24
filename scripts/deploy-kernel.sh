#!/bin/bash
# deploy-kernel.sh — put a kernel on a box, and prove it got there.
#
#   scripts/deploy-kernel.sh <host> [options]
#
#   <host>        the box, as [user@]host. Or set SC2_HOST.
#   --image FILE  the Image to send (default: kernel/Image in this repo)
#   --p1 DEV      also write it to a boot partition on the box, e.g.
#                 /dev/mmcblk0p1 (eMMC) or /dev/sda1 (a USB stick). The
#                 partition is mounted, written, synced and verified.
#   --reboot      reboot the box after a successful --p1 write
#   --user U      ssh user (default: root; overrides the user in <host>)
#   --port N      ssh port
#   --keep        leave the staged copy in the box's /root
#
# WHY THIS EXISTS
#
# The kernel is 34 MB and the box's link is 100 Mbps. A plain copy stalls
# partway (6.4 MB was observed) and leaves a file that has the right name
# and the wrong size - which is how a truncated 3.5 MB "Image.published"
# ended up on a box looking like a kernel. So:
#
#   * the transfer is resumable (rsync --partial --append-verify), and it
#     is retried rather than reported as a failure on the first stall;
#   * NOTHING is reported as done until a sha256 of the bytes on the box
#     matches the bytes on the host - not the transfer, not the write to
#     the boot partition;
#   * writing to a boot partition prints the hash that was there before,
#     because a boot partition is small enough that the old kernel cannot
#     be kept as well.
#
# It does not touch the U-Boot environment, and it does not decide which
# partition to write. It says what it did, and it stops if it cannot
# prove it.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

HOSTARG=""
IMAGE="$REPO/kernel/Image"
P1=""
REBOOT=0
USER=""
PORT=""
KEEP=0

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --image)  IMAGE="${2:-}"; shift 2 ;;
        --p1)     P1="${2:-}"; shift 2 ;;
        --reboot) REBOOT=1; shift ;;
        --user)   USER="${2:-}"; shift 2 ;;
        --port)   PORT="${2:-}"; shift 2 ;;
        --keep)   KEEP=1; shift ;;
        -h|--help) usage 0 ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) [ -z "$HOSTARG" ] || { echo "too many arguments" >&2; usage; }
           HOSTARG="$1"; shift ;;
    esac
done

HOSTARG="${HOSTARG:-${SC2_HOST:-}}"
[ -n "$HOSTARG" ] || { echo "no host given (pass one, or set SC2_HOST)" >&2; usage; }

# [user@]host, with --user overriding the user part.
case "$HOSTARG" in
    *@*) HOSTUSER="${HOSTARG%%@*}"; HOST="${HOSTARG#*@}" ;;
    *)   HOSTUSER="${USER:-root}";   HOST="$HOSTARG" ;;
esac
[ -n "$USER" ] && HOSTUSER="$USER"
TARGET="$HOSTUSER@$HOST"

[ -f "$IMAGE" ] || { echo "no image at $IMAGE" >&2; exit 1; }
LOCAL_HASH=$(sha256sum "$IMAGE" | cut -d' ' -f1)
LOCAL_SIZE=$(stat -c %s "$IMAGE")
STAGE="/root/$(basename "$IMAGE").deploy"

log()  { printf '[deploy] %s\n' "$*"; }
die()  { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- ssh plumbing
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10
          -o PreferredAuthentications=password,keyboard-interactive,publickey)
[ -n "$PORT" ] && SSH_OPTS+=(-p "$PORT")

# sshpass is used only if SC2_PASS is set; otherwise ssh uses keys or prompts.
SUDO_SSH=""
if [ -n "${SC2_PASS:-}" ]; then
    command -v sshpass >/dev/null || die "SC2_PASS is set but sshpass is not installed"
    SUDO_SSH="sshpass -p $SC2_PASS"
fi

sshcmd() { $SUDO_SSH ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

# ---------------------------------------------------------------- reach it
log "host:  $TARGET"
log "image: $IMAGE"
log "hash:  $LOCAL_HASH  ($LOCAL_SIZE bytes)"
sshcmd true 2>/dev/null || die "cannot run a command on $TARGET"
log "the box answered."

# ---------------------------------------------------------------- send
# Resumable, retried, and only believed after a hash.
MAX_TRIES=${SC2_TRIES:-8}
attempt=0
while :; do
    attempt=$((attempt + 1))
    [ "$attempt" -le "$MAX_TRIES" ] || die "gave up after $MAX_TRIES tries"

    # If a *complete-looking* file is already there with the wrong hash,
    # --append-verify would try to extend it and never match. Start over.
    # Pull the hash and the size out by shape, not by line: a login banner
    # or a stray message on the channel must not be able to look like an
    # answer. A 64-hex token is a hash; a bare number is a size.
    rsize=$(sshcmd "stat -c %s '$STAGE' 2>/dev/null || echo 0" 2>/dev/null |
            grep -oE '^[0-9]+$' | head -1)
    rhash=$(sshcmd "sha256sum '$STAGE' 2>/dev/null | cut -d' ' -f1" 2>/dev/null |
            grep -oE '[0-9a-f]{64}' | head -1)
    if [ "$rhash" = "$LOCAL_HASH" ]; then
        log "already on the box and verified (attempt $attempt)."
        break
    fi
    if [ -n "$rsize" ] && [ "$rsize" -ge "$LOCAL_SIZE" ] && [ "$rhash" != "$LOCAL_HASH" ]; then
        log "a wrong file of the same size is there; removing it to start clean."
        sshcmd "rm -f '$STAGE'"
    fi

    log "transfer, attempt $attempt${rsize:+ (resuming from $rsize bytes)} ..."
    if $SUDO_SSH rsync -e "ssh ${SSH_OPTS[*]}" \
            --partial --append-verify --timeout=45 \
            "$IMAGE" "$TARGET:$STAGE" >/dev/null 2>&1; then
        log "  transfer completed; verifying the bytes on the box."
    else
        log "  transfer did not complete; verifying whatever arrived."
    fi

    rhash=$(sshcmd "sha256sum '$STAGE' 2>/dev/null | cut -d' ' -f1" 2>/dev/null |
            grep -oE '[0-9a-f]{64}' | head -1)
    if [ "$rhash" = "$LOCAL_HASH" ]; then
        log "  verified: the box has the same bytes."
        break
    fi
    log "  not there yet (box has ${rhash:0:16}...); retrying."
    sleep 2
done

# ---------------------------------------------------------------- write to p1
if [ -n "$P1" ]; then
    log "writing $P1 ..."
    out=$(sshcmd "
        set -e
        dev='$P1'
        [ -b \"\$dev\" ] || { echo NOTBLOCK; exit 3; }
        # Mount it unless something already has it; remember whether we did.
        if findmnt -n -o TARGET --source \"\$dev\" >/dev/null 2>&1; then
            mnt=\$(findmnt -n -o TARGET --source \"\$dev\" | head -1); owned=0
        else
            mnt=\$(mktemp -d)
            mount \"\$dev\" \"\$mnt\" || { echo MOUNTFAIL; exit 4; }; owned=1
        fi
        old=\$(sha256sum \"\$mnt/Image\" 2>/dev/null | cut -d' ' -f1 || true)
        cp '$STAGE' \"\$mnt/Image\"
        sync
        new=\$(sha256sum \"\$mnt/Image\" | cut -d' ' -f1)
        [ \"\$owned\" = 1 ] && umount \"\$mnt\"
        echo \"old=\$old\"
        echo \"new=\$new\"
    " 2>&1)
    rc=$?
    # Print the answer, and anything that looks like an error. Anything else
    # on the channel (a login banner, say) is noise.
    printf '%s\n' "$out" | grep -E '^(old|new)=|ERROR|FAIL|error|fail' |
        sed 's/^/[deploy]   /'
    [ "$rc" = 0 ] || { printf '%s\n' "$out" | sed 's/^/[deploy]   /'; die "writing $P1 failed"; }
    new=$(printf '%s\n' "$out" | sed -n 's/^new=//p' | tr -d '\r')
    old=$(printf '%s\n' "$out" | sed -n 's/^old=//p' | tr -d '\r')
    [ "$new" = "$LOCAL_HASH" ] || die "$P1 does not hold the image we sent (it holds ${new:0:16}...)"
    log "  $P1 now holds $new"
    [ -n "$old" ] && log "  it held ${old} before"

    if [ "$REBOOT" = 1 ]; then
        log "rebooting the box."
        sshcmd "systemctl reboot" >/dev/null 2>&1 || true
    fi
fi

if [ "$KEEP" != 1 ]; then
    sshcmd "rm -f '$STAGE'" >/dev/null 2>&1 || true
fi

log "done. $TARGET has $LOCAL_HASH${P1:+ , and $P1 holds it}."
