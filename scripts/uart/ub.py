#!/usr/bin/env python3
"""Send commands to the Amlogic box over UART and log everything it sends back.

usage: ub.py [--port DEV] [--baud N] [--log FILE] "cmd" [--wait S] "cmd" ...

Commands are typed one per argument; "--wait S" sets how long to collect the
reply after the preceding command.  All output (both directions) is appended
to the log file and echoed to stdout.
"""
import os
import select
import subprocess
import sys
import time

PORT = "/dev/ttyUSB0"
BAUD = 1000000
LOG = "/home/dim20/amlogic/serial/ub.log"
CMDS = []

a = list(sys.argv[1:])
while a:
    t = a.pop(0)
    if t == "--port":
        PORT = a.pop(0)
    elif t == "--baud":
        BAUD = int(a.pop(0))
    elif t == "--log":
        LOG = a.pop(0)
    elif t == "--wait":
        CMDS.append((float(a.pop(0)), None))
    else:
        CMDS.append((None, t))

steps = []
for wait, cmd in CMDS:
    if cmd is not None:
        steps.append(["cmd", cmd, 4.0])
    elif steps:
        steps[-1][2] = wait
if not steps:
    steps = [["cmd", "printenv", 4.0]]

subprocess.run(["stty", "-F", PORT, str(BAUD), "raw", "-echo", "-echoe",
                "-echok", "-echoctl", "-echoke", "cs8", "-parenb", "-cstopb",
                "-ixon", "-ixoff", "-crtscts", "min", "0", "time", "1"],
               check=False)

fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
out = open(LOG, "wb", buffering=0)
out.write(b"=== ub session %s baud=%d port=%s ===\n"
          % (time.strftime("%H:%M:%S").encode(), BAUD, PORT.encode()))


def drain(secs):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if fd in r:
            try:
                d = os.read(fd, 8192)
            except OSError:
                d = b""
            if d:
                out.write(d)


drain(1.0)
for _, cmd, wait in steps:
    out.write(b"\n### send: %s\n" % cmd.encode())
    os.write(fd, cmd.encode() + b"\n")
    drain(wait)
drain(2.0)
os.close(fd)
print("logged %d steps -> %s" % (len(steps), LOG))