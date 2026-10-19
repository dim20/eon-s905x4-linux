#!/bin/sh
# Arm the U-Boot autoboot interceptor.
#   usage: scripts/arm.sh [seconds] [logfile]
# Always run this BEFORE asking the user to power-cycle. The catcher exits on
# its own timeout, so it must be re-armed for every cycle - do not assume the
# previous one is still alive.
#
# NOTE: do NOT use `pkill -f catch-uboot2.py` to clean up. The -f pattern also
# matches the shell that is running this script (its command line contains the
# script text), so pkill kills the invoking shell itself -> "Killed by SIGTERM".
# We track the PID in a pidfile instead.
set -e
cd "$(dirname "$0")/.."
SECS=${1:-3600}
LOG=${2:-serial/catch-$(date +%H%M%S).log}
PIDFILE=/tmp/opencode/catcher.pid
mkdir -p serial /tmp/opencode

# Auto-detect the UART adapter. Do NOT hardcode /dev/ttyUSB0: the device
# re-enumerates (e.g. when another USB device is unplugged, the whole USB bus
# re-enumerates and the adapter can come back as ttyUSB1). A hardcoded path
# silently captures nothing while the process still looks "alive".
PORT=${UART_PORT:-$(ls /dev/ttyUSB* 2>/dev/null | head -1)}
[ -n "$PORT" ] || { echo "ERROR: no /dev/ttyUSB* found - is the UART adapter plugged in?"; exit 1; }
echo "using port: $PORT"

if [ -f "$PIDFILE" ]; then
  OLD=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
    kill "$OLD" 2>/dev/null || true
    sleep 3
  fi
  rm -f "$PIDFILE"
fi

nohup python3 scripts/catch-uboot2.py "$PORT" "$PWD/$LOG" "$SECS" 1000000 \
  > /tmp/opencode/catcher.out 2>&1 &
NEW=$!
echo "$NEW" > "$PIDFILE"
sleep 5

# Verify the port is actually readable AND that bytes are arriving. A process
# can be alive while capturing nothing if the device node is wrong.
if kill -0 "$NEW" 2>/dev/null && [ -s "$LOG" ]; then
  echo "armed pid=$NEW port=$PORT secs=$SECS log=$LOG at $(date +%H:%M:%S)"
else
  echo "FAILED TO ARM (pid $NEW, port $PORT, log bytes: $(stat -c%s "$LOG" 2>/dev/null || echo 0))"
  tail -5 /tmp/opencode/catcher.out 2>/dev/null || true
  exit 1
fi
