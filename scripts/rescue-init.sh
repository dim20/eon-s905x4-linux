#!/bin/sh
# rescue-init.sh - minimal init for the EON SDSTB02 (Amlogic S905X4) boxes.
#
# WHY THIS EXISTS: on the mainline kernel, systemd could not exec /sbin/agetty on
# this hardware at all - "Exec format error" on every attempt (51+ retries) -
# while the byte-identical binary execs with RC=0 from a plain shell. On the
# vendor 5.4.210 kernel systemd may well work (see docs/roadmap: migrating to it
# is phase P4), but this is what is proven and it boots in ~3s instead of ~100s.
#
# This is a RESCUE shell, not a full OS: no dbus, no logind, no networkd, no
# systemctl. It is deliberately small and uses absolute paths throughout, so it
# cannot itself be defeated by an exec problem.
#
# STRUCTURE - the ordering here matters:
#   * the serial console is FOREGROUND and is never backgrounded. It is the
#     recovery path; if anything can kill it, you lose the box.
#   * everything else - HDMI console, networking, clock, sshd - is backgrounded
#     and made non-fatal, so a failure there can never block login.
#   * background work is SEQUENTIAL inside one subshell, not parallel. This box
#     is marginal under concurrent I/O and parallel work has wedged the console
#     before.

PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH

# ---------------------------------------------------------------- pseudo-fs
# Without /proc, every "cat /proc/..." and every "ps" silently returns nothing,
# which makes present hardware look absent.
mount -t proc     proc     /proc     2>/dev/null
mount -t sysfs    sysfs    /sys      2>/dev/null
mount -t devtmpfs devtmpfs /dev      2>/dev/null
mount -t tmpfs    tmpfs    /tmp      2>/dev/null
mount -t devpts   devpts   /dev/pts  2>/dev/null
# /run must be a tmpfs of its own. The image ships a /run tree owned by the
# uid that built it (1000), and sshd refuses to start when /run/sshd is not
# owned by root: "/run/sshd must be owned by root and not group or
# world-writable". Mounting tmpfs over it gives a clean, root-owned /run.
mount -t tmpfs    tmpfs    /run      2>/dev/null

# ---------------------------------------------------------------- hostname
HN=$(cat /proc/sys/kernel/hostname 2>/dev/null)
case "$HN" in
    ""|"(none)") HN=sc2 ;;
esac
echo "$HN" > /proc/sys/kernel/hostname 2>/dev/null
echo "$HN" > /etc/hostname 2>/dev/null

# ---------------------------------------------------------------- network
# Runs in the background. Every step is best-effort: a box with no cable should
# still reach a login prompt, not hang here.
net_setup() {
    mkdir -p /var/lib
    # ORDER MATTERS: bring the link UP *first*, then wait for carrier.
    #
    # Waiting for carrier before `ip link set up` can never succeed: on a DOWN
    # interface, reading /sys/class/net/eth0/carrier returns EINVAL ("Invalid
    # argument"), not "0", so the loop runs to timeout and the interface is
    # still down afterwards.
    ip link set eth0 up 2>/dev/null

    # After the link goes up the PHY still needs ~1.5s to report ready
    # (observed: `ip link` at 146.12s, "Link is Up" at 147.61s). A fixed sleep
    # of 1s is not enough and dhclient then starts on an interface that cannot
    # yet transmit - it gets no lease and gives up silently.
    # So: poll for carrier, up to ~20s.
    i=0
    while [ $i -lt 20 ]; do
        [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = "1" ] && break
        sleep 1
        i=$((i+1))
    done

    # DHCP. ISC dhclient 4.4.3 has NO -t/--timeout flag (that is a udhcpc
    # option) - passing it makes dhclient exit with a usage error and no lease.
    # It forks to background by itself, so bound the wait by polling instead.
    dhclient -q eth0 >/var/log/dhclient.log 2>&1
    j=0
    while [ $j -lt 20 ]; do
        ip -4 addr show eth0 2>/dev/null | grep -q 'inet ' && break
        sleep 1
        j=$((j+1))
    done

    # The DHCP client on this image does not write /etc/resolv.conf (resolvconf
    # is not installed), so DNS is dead without this. Ship one regardless - a
    # static file is more predictable than depending on the lease.
    if [ ! -s /etc/resolv.conf ]; then
        printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
    fi

    # Clock. There is no hwclock and the RTC reads back invalid, so the box boots
    # at 1970 unless something sets it. This matters more than it looks: apt
    # rejects every repo signature as "not live yet" when the clock is at epoch
    # 0, which shows up as a misleading "no installation candidate" rather than
    # as a time problem.
    #
    # Order: try chrony (needs the network, which we now have). If that fails,
    # fall back to the last time we successfully knew - good enough for TLS and
    # far better than 1970. We never invent a time: a wrong-but-plausible clock
    # is harder to debug than an obviously-wrong one.
    set_clock() {
        if command -v chronyd >/dev/null 2>&1; then
            # -q sets the time once and exits; it does not daemonise.
            chronyd -q >/var/log/chrony.log 2>&1 || true
            sleep 2
        fi
        if [ "$(date +%Y)" -ge 2020 ] 2>/dev/null; then
            # Good clock - remember it for a future offline boot.
            date +%s >/var/lib/lastgoodtime 2>/dev/null
            return 0
        fi
        if [ -s /var/lib/lastgoodtime ]; then
            T=$(cat /var/lib/lastgoodtime 2>/dev/null)
            # Validate before use: a truncated or corrupted file would otherwise
            # be handed to `date -s` and could set a nonsense clock, which is far
            # harder to diagnose than having no clock at all.
            case "$T" in
                ''|*[!0-9]*) T="" ;;
            esac
            if [ -n "$T" ] && date -s "@$T" >/dev/null 2>&1; then
                echo "clock: chrony unavailable, restored last known good time" >&2
                return 0
            fi
        fi
        return 1
    }

    if ! set_clock; then
        echo "WARNING: clock is not set (year $(date +%Y)). apt and TLS will fail." >&2
        echo "         install chrony, or run: date -s \"\$(date -u)\"" >&2
    fi

    # sshd, so an unattended box is reachable over the network.
    mkdir -p /run/sshd 2>/dev/null
    # sshd refuses to start if the privilege-separation directory is not
    # root-owned, and it says so only in its own error output, which is
    # discarded below. So fix the ownership explicitly and say so if sshd
    # still refuses — a silent "network ready ... (ssh)" that cannot be
    # logged into is worse than a loud failure.
    chown root:root /run/sshd 2>/dev/null
    chmod 0755 /run/sshd 2>/dev/null
    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
        ssh-keygen -A >/dev/null 2>&1
    fi
    if ! /usr/sbin/sshd 2>/tmp/sshd.err; then
        echo "WARNING: sshd did not start: $(head -1 /tmp/sshd.err 2>/dev/null)" >&2
    fi

    IP=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    [ -n "$IP" ] && echo "network ready: $IP (ssh)"
}

net_setup &
NETPID=$!

# ---------------------------------------------------------------- HDMI console
# Backgrounded deliberately: it must never block or kill the serial console.
( while true; do /sbin/agetty --noreset --noclear tty1 vt220; sleep 1; done ) &

# ---------------------------------------------------------------- HDMI output
# The vendor DRM driver exposes the HDMI connector but never enables it: it
# sits at "disabled" and the screen stays blank. A mode set is needed, and it
# is runtime state, so it has to be redone on every boot.
#
# The DTB's fb node is enabled in the shipped device tree, which is what makes
# the OSD framebuffer driver bind and create /dev/fb0 at all.
#
# Best effort: no display attached, no modetest, or a driver that refuses
# the mode set must never stop the box from booting.
hdmi_setup() {
    [ -x /root/enable-hdmi.sh ] || return 0
    /root/enable-hdmi.sh 2>&1 | sed 's/^/[hdmi] /'
}
hdmi_setup &

# ---------------------------------------------------------------- serial console
# Foreground. This is the recovery path - nothing above may prevent it.
echo "Starting serial console on ttyS0..."
while true; do
    /sbin/agetty --noreset --noclear ttyS0 vt220
    sleep 1
done