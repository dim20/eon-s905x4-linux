#!/usr/bin/env python3
"""Log a UART stream to a file. usage: uartcap.py <dev> <baud> <seconds> <outfile>"""
import os
import sys
import time

dev, baud, secs, out = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
import termios
import tty

fd = os.open(dev, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
tty.setraw(fd)
attrs = termios.tcgetattr(fd)
attrs[0] = 0                      # iflag: raw
attrs[1] = 0                      # oflag: raw
attrs[2] = (termios.CLOCAL | termios.CREAD | termios.CS8)
attrs[3] = 0                      # lflag: raw
attrs[4] = baud                   # ispeed
attrs[5] = baud                   # ospeed
termios.tcsetattr(fd, termios.TCSANOW, attrs)

start = time.time()
with open(out, "wb") as f:
    while time.time() - start < secs:
        try:
            data = os.read(fd, 4096)
        except BlockingIOError:
            data = b""
        if data:
            f.write(data)
            f.flush()
            sys.stdout.write(data.decode("utf-8", "replace"))
            sys.stdout.flush()
        else:
            time.sleep(0.05)
os.close(fd)