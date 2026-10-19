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

# ---------------------------------------------------------------- hostname
HN=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo eon-sc2)
echo "$HN" > /etc/hostname 2>/dev/null

# ---------------------------------------------------------------- network
# Runs in the background. Every step is best-effort: a box with no cable should
# still reach a login prompt, not hang here.
net_setup() {
    # Up to ~20s for carrier. 100 Mbps link, no switch needed locally.
    i=0
    while [ $i -lt 20 ]; do
        [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = "1" ] && break
        sleep 1
        i=$((i+1))
    done

    ip link set eth0 up 2>/dev/null
    sleep 1

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

    # Clock. There is no hwclock and the RTC reads back invalid, so the box
    # boots at 1970 unless something sets it. Chrony is preferred; if it is not
    # installed we leave the clock alone rather than inventing a time, but say so
    # loudly - apt and TLS will both misbehave at epoch 0.
    if command -v chronyd >/dev/null 2>&1; then
        chronyd -q >/var/log/chrony.log 2>&1 || true
        sleep 2
    fi
    Y=$(date +%Y)
    if [ "$Y" -lt 2020 ] 2>/dev/null; then
        echo "WARNING: clock is not set (year $Y). apt and TLS will fail." >&2
        echo "         install chrony, or run: date -s \"\$(date -u)\"" >&2
    fi

    # sshd, so an unattended box is reachable over the network.
    mkdir -p /run/sshd 2>/dev/null
    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
        ssh-keygen -A >/dev/null 2>&1
    fi
    /usr/sbin/sshd 2>/dev/null

    IP=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    [ -n "$IP" ] && echo "network ready: $IP (ssh)"
}

net_setup &
NETPID=$!

# ---------------------------------------------------------------- HDMI console
# Backgrounded deliberately: it must never block or kill the serial console.
( while true; do /sbin/agetty --noreset --noclear tty1 vt220; sleep 1; done ) &

# ---------------------------------------------------------------- serial console
# Foreground. This is the recovery path - nothing above may prevent it.
echo "Starting serial console on ttyS0..."
while true; do
    /sbin/agetty --noreset --noclear ttyS0 vt220
    sleep 1
done