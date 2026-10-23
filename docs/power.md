# Power and the display link

What happens on reboot, poweroff and an HDMI hotplug, and the evidence for
each. Read from the box on **2026-10-23**.

---

## Poweroff

`poweroff` stops the box; the front power button starts it again. Reported
by the person at the box and exercised more than once.

This was **not** measured with a power meter. The evidence is that the box
stops (no console, no SSH) and the button brings it back — which is what a
user means by "it powered off", but it does not prove the standby rail is
at zero. If that distinction ever matters, measure it; do not infer it from
this page.

## Reboot reliability

Ten consecutive reboots on the eMMC system, issued over SSH. Every one came
back:

| Reboot | Boot ID | Root | Failed units | Uptime on return |
|---|---|---|---|---|
| 1–10 | a new ID each time | `/dev/mmcblk0p2` | **0** | ~0 minutes |

The loop waited for the box to answer with a *different* boot ID than the
one before the reboot, so a "came back" result cannot be the old session
answering late. Ten out of ten is the reliability evidence; it is not a
claim that it will never fail.

## HDMI hotplug

The cable was unplugged and plugged back in while the box was running:

```
[   86.147508] hdmitx: ... HPD LOW
[   86.151980] [drm] drm hdmitx hpd notify
[   94.307938] hdmitx: ... HPD HIGH
[   95.054764] [drm] drm hdmitx hpd notify
```

The driver saw both edges and re-initialised the HDMI TX (audio type and
register writes follow the HPD HIGH). The connector returned to
`connected`, and the framebuffer stayed 1920×2160.

**The console came back on its own.** There was no new
`fbcon: Taking over console` line — only the one from boot — so the
framebuffer simply kept scanning out the same content. The picture was
confirmed on the television.

`enable-hdmi.service` runs once at boot; it does not react to hotplug. If a
future build ever leaves the screen black after a replug, run the same
script the service runs:

```sh
/root/enable-hdmi.sh
```

## What is not covered here

- **Power draw and standby current** — not measured.
- **Long-term power-button wear / cold-start timing** — not measured.
- **Hotplug while a mode set is in progress** — not tested; the window is
  small and the boot service already retries.
- **HDCP** — the vendor's HDMI TX has no HDCP key, so each boot logs about
  twelve HDCP lines. Harmless for a framebuffer console; see
  [`time.md`](time.md) and the release note's "not fixed" section.

---

## Last verified

**2026-10-23**, on the eMMC system (`/dev/mmcblk0p2`):

- 10/10 reboots returned with a new boot ID, 0 failed units;
- HDMI unplug/replug at 86 s/94 s: HPD LOW/HIGH seen, driver re-initialised,
  console still on the TV without intervention;
- `poweroff` stops the box and the front button powers it on (reported, not
  metered).
