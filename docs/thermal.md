# Thermal and sustained load

One hour of full CPU load on the eMMC system, with the SoC and DDR
temperatures sampled every ten seconds. Read from the box on
**2026-10-23**.

---

## The test

Four `nice`-ed `yes` processes, one per core, for **3600 seconds**
(17:51:25 → 18:51:34). A shell loop read the two thermal zones and the
per-core frequency every 10 seconds into `/root/thermal.log`. The load
processes were `nice 10`, so the SSH session stayed responsive and the
sampling could run.

**356 samples**, no gaps.

## The sensors

```
/sys/class/thermal/thermal_zone0   soc_thermal
/sys/class/thermal/thermal_zone1   ddr_thermal
```

Trip points reported by the SoC: **85 °C, 95 °C, 105 °C**.

## The result

| | |
|---|---|
| SoC maximum | **54.8 °C** |
| SoC average | **54.0 °C** |
| DDR maximum | **54.1 °C** |
| Lowest CPU0 frequency seen | **2,004,000 kHz** |
| Throttling | **none** |

All four cores ran at the maximum 2.004 GHz for the whole hour. The
temperature rose from ~34 °C idle to ~47 °C within 30 seconds, then
settled at **54–55 °C** and stayed there. The first trip point is 85 °C —
the box has **30 °C of headroom** under this load.

## What this does and does not say

**Does:** with all four cores pegged for an hour, in this box, on this
desk, the SoC does not approach its throttle point and never drops below
maximum clock.

**Does not:**

- **ambient temperature was not measured.** The numbers are only
  meaningful with the room temperature; if it was 22 °C, a 35 °C rise
  matters more than if it was 30 °C. Re-run with a thermometer beside the
  box to make the result portable.
- **the enclosure and airflow are not recorded.** A box in an open
  position cools very differently from one in a closed cabinet.
- **the load is integer-only** (`yes`). It stresses the CPU, not the GPU,
  the VPU, or the DSP. A video or GPU workload would add heat from other
  blocks.
- **one hour is not forever.** This shows the plateau is reached and
  stable; it does not prove the box cannot heat-soak over a day.

## Reproducing it

```sh
# on the box, as root
cat > /root/thermal-test.sh <<'EOF'
#!/bin/bash
set -u
LOG=/root/thermal.log
DURATION=${1:-3600}; INTERVAL=10
: > "$LOG"
pids=""
for i in 1 2 3 4; do nice -n 10 yes > /dev/null & pids="$pids $!"; done
end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$end" ]; do
  echo "$(date -Is) $(cat /sys/class/thermal/thermal_zone0/temp) \
$(cat /sys/class/thermal/thermal_zone1/temp) \
$(cat /sys/devices/system/cpu/cpu[0-3]/cpufreq/scaling_cur_freq | tr '\n' ' ')" >> "$LOG"
  sleep "$INTERVAL"
done
for p in $pids; do kill "$p" 2>/dev/null; done
EOF
chmod +x /root/thermal-test.sh
/root/thermal-test.sh 3600
```

---

## Last verified

**2026-10-23**, eMMC system (`/dev/mmcblk0p2`): 1 hour at 4-core load,
SoC max 54.8 °C, DDR max 54.1 °C, all cores at 2.004 GHz throughout, no
throttling, trip points 85/95/105 °C. Ambient and enclosure not recorded.