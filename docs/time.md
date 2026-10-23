# Time

The box has **no battery-backed real-time clock**. The vendor's `meson-vrtc`
registers as `rtc0` and starts at epoch 2; the kernel's clock is set from it
and is wrong until something corrects it. Two things do:

1. **`fake-hwclock`** restores the time saved in `/etc/fake-hwclock.data`
   during early boot. This is the fallback when the network is not up yet.
2. **chrony** corrects the clock from NTP once the network is available.

The arrangement is "start near the last known time, correct as soon as the
network appears". It is coherent, but without a network and without a
battery-backed RTC, the clock cannot be *exact* — it can only be the last
saved time.

---

## What was wrong in v0.7-tty

`/etc/fake-hwclock.data` was copied from the source tree without refreshing
its **contents**. The build's `SOURCE_DATE_EPOCH` set the file's *timestamp*
but not the text inside it. The published v0.7-tty image therefore carried
`2026-10-04 17:13:35` — 19 days before the image was built.

A cold boot from the stick without network started 19 days in the past. With
the network up, chrony corrected it within seconds, so the fault was easy to
miss.

## The fix

`scripts/build-stick-image.sh` now rewrites `/etc/fake-hwclock.data` from
`SOURCE_DATE_EPOCH`:

```sh
date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S' \
    > "$ROOTFS_TREE/etc/fake-hwclock.data"
```

`SOURCE_DATE_EPOCH` defaults to the newest file in the tree, so the same tree
still gives the same image bytes. The fallback is the tree's last-known time,
not "now" — which is the honest thing to ship and keeps the build
reproducible. The build log says what it set:

```
[build-image]   clock fallback set to 2026-10-20 16:38:06 UTC
```

The installer refreshes the file to the install time on the eMMC, and the
`fake-hwclock-save` timer keeps it current afterwards. So the eMMC's fallback
is the last time the system was running, not the build time.

## What you will see

| Situation | What happens |
|---|---|
| Cold boot, network up | The clock starts at the saved time, then chrony corrects it within seconds. `timedatectl` shows `System clock synchronized: yes`. |
| Cold boot, no network | The clock is the saved time. It is monotonic and plausible, but it is not exact. This is the best available without an RTC. |
| Warm boot | The clock is already correct; chrony keeps it so. |

## Checking it on a box

```sh
cat /etc/fake-hwclock.data        # the saved fallback, UTC
timedatectl                       # current time, NTP state, RTC time
chronyc tracking                  # how far the clock is from NTP
journalctl --list-boots           # boot times, and whether the clock jumped
```

The first journal entry of a boot shows the clock as it was when the kernel
started. A large gap between that and the real time means the fallback was
stale; a jump later in the log means NTP corrected it.

## Last verified

**2026-10-23**, on the eMMC system:

- `fake-hwclock.data` = `2026-10-23 15:00:07` (the install time);
- first journal entry of the boot = `16:35:37 CEST` (the bootloader's
  restored time, close to the real time);
- chrony synchronised to a stratum-4 source; `timedatectl` reports
  `System clock synchronized: yes`;
- the vendor's `meson-vrtc` logs `setting system clock to
  1970-01-01T00:00:02 UTC`, which is the driver's registration, not the
  time the system ends up with.

On the stick the same check showed the stale fallback: `fake-hwclock.data` =
`2026-10-04 17:13:35`, and the boot started 19 days in the past. The build fix
changes that for the next image. The published v0.7-tty image still carries
the old value; with the network up it is corrected within seconds, so it is a
fallback-quality problem rather than a boot-stopper.
