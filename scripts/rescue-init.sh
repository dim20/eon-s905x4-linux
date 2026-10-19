#!/bin/sh
# rescue-init.sh - minimal init for the SDSTB02 boxes.
#
# WHY THIS EXISTS: systemd cannot exec /sbin/agetty on this hardware at all -
# "Exec format error" on every attempt (51+ retries) - while the byte-identical
# binary execs with RC=0 from a plain shell. Best hypothesis: a page of the
# binary poisoned in the page cache by an earlier bad read during systemd's
# parallel boot-time load, then mapped forever. Bypassing systemd avoids it.
#
# Boots to a login prompt in ~3s, versus ~100s to multi-user under systemd.
# This is a RESCUE shell: no dbus, no logind, no networkd, no systemctl.
#
# Uses only /bin/sh builtins plus coreutils, so it cannot itself be defeated by
# the exec problem. Everything is absolute-pathed.

PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH

/bin/mount -t proc     proc     /proc     2>/dev/null
/bin/mount -t sysfs    sysfs    /sys      2>/dev/null
/bin/mount -t devtmpfs devtmpfs /dev      2>/dev/null
/bin/mount -t tmpfs    tmpfs    /tmp      2>/dev/null
/bin/mount -t devpts   devpts   /dev/pts  2>/dev/null

# Hostname and a resolvable /etc/hosts, or agetty can be slow to start.
echo eon-sc2 > /proc/sys/kernel/hostname 2>/dev/null
echo eon-sc2 > /etc/hostname 2>/dev/null

# Serial console - this is the one that matters. Foreground.
echo "Starting serial console on ttyS0..."
while true; do
    /sbin/agetty --noreset --noclear ttyS0 vt220
    sleep 1
done
