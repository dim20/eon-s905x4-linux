#!/usr/bin/env python3
"""Interrupt U-Boot autoboot and capture everything, holding one FD."""
import os
import pty
import select
import subprocess
import sys
import termios
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB0"
LOG = sys.argv[2] if len(sys.argv) > 2 else os.environ.get(
    "CATCH_LOG", "/tmp/opencode/catch.log")
DUR = float(sys.argv[3]) if len(sys.argv) > 3 else 90.0
BAUD = int(sys.argv[4]) if len(sys.argv) > 4 else 1500000

# The CP210x re-enumerates between /dev/ttyUSB0 and /dev/ttyUSB2, and briefly
# vanishes entirely, whenever the box is power-cycled. Wait for it rather than
# dying on a missing node.
def wait_for_port(timeout=180):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(PORT):
            try:
                return os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
            except OSError:
                pass
        time.sleep(0.5)
    return None


# Request 1500000; this box's U-Boot is on that clock.
subprocess.run(["stty", "-F", PORT, str(BAUD), "raw", "-echo", "-echoe",
                "-echok", "-echoctl", "-echoke", "cs8", "-parenb", "-cstopb",
                "-ixon", "-ixoff", "-crtscts", "min", "0", "time", "1"],
               check=False)

fd = wait_for_port()
if fd is None:
    print("serial port never appeared: %s" % PORT)
    sys.exit(2)
out = open(LOG, "wb", buffering=0)
out.write(b"=== catcher start %s ===\n" % time.strftime("%H:%M:%S").encode())

start = time.time()
last_key = 0.0
nkey = 0
got = b""
# Opening the port asserts DTR/RTS, which makes the board emit a fresh U-Boot
# prompt immediately. Without this grace period the catcher sees that spurious
# prompt and exits at once, so it can never actually wait for a power cycle.
# Ignore any prompt seen during the first GRACE seconds; after that, treat the
# first real prompt as the catch.
GRACE = float(os.environ.get("CATCHER_GRACE", "12"))
while time.time() - start < DUR:
    now = time.time()
    # Spam CR hard - this is what reliably stops "Hit any key to stop autoboot".
    if now - last_key >= 0.12:
        try:
            os.write(fd, b"\r\r\r")
            os.write(fd, b"\n")
            os.write(fd, b"\x03")          # Ctrl-C
            nkey += 1
        except OSError:
            pass
        last_key = now
    r, _, _ = select.select([fd], [], [], 0.2)
    if fd in r:
        try:
            d = os.read(fd, 4096)
        except OSError:
            d = b""
        if d:
            out.write(d)
            got += d
    if (time.time() - start) > GRACE and (b"sc2_ah212#" in got or b"=>" in got):
        time.sleep(1.0)
        r, _, _ = select.select([fd], [], [], 0.5)
        if fd in r:
            try:
                out.write(os.read(fd, 4096))
            except OSError:
                pass
        break

out.write(b"\n=== catcher end %s keys=%d ===\n"
          % (time.strftime("%H:%M:%S").encode(), nkey))
os.close(fd)
print("captured %d bytes -> %s" % (len(got), LOG))
