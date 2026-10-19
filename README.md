# eon-s905x4-linux

Linux on the **EON SDSTB02** (Greek EON / NOVA set-top box, built by SDMC) —
an Amlogic **S905X4 / SC2** box with 2 GB LPDDR4 and 14.6 GB eMMC.

The box ships with a locked Android bootloader and no way to boot anything else.
This project gets it to boot Debian Linux from eMMC, unattended, with nothing
plugged in.

```
UNMODIFIED BOX + USB STICK  →  POWER CYCLE  →  LINUX, NOBODY TOUCHES IT
```

---

## Status

**v0.1-testbox** — works on the development box. Not yet validated across a fleet.

| | |
|---|---|
| Boots unattended from eMMC | ✅ power cycle only, ~2.3 s to login |
| 4 cores | ✅ |
| Ethernet 100 Mbps | ✅ internal RMII PHY |
| HDMI | negotiated 1080p60 over EDID, DRM initialises — **picture never confirmed on a screen** |
| Audio | ASoC card + SPDIF register — **never confirmed audible** |
| USB 2.0 / 3.0 | ✅ |
| Bluetooth | present |
| DVB tuner | ❌ not populated on this variant |
| WiFi | ❌ RTL8812CS, no open driver (you supply a closed one) |
| Network after boot | ❌ **not yet automatic** — see below |
| systemd | ❌ rescue init only |

### Known gaps in v0.1

These are real and will bite you:

1. **No network after boot.** `rescue-init.sh` does not run `dhclient`, so the
   box comes up with no IP address and no SSH. You get a login prompt on HDMI
   and serial, nothing else. Work in progress — this is the next thing being
   fixed.
2. **Clock reads 1970** and there is no `/etc/resolv.conf`, so `apt` cannot
   work until both are fixed. See [`docs/install-image-requirements.md`](docs/install-image-requirements.md).
3. **Booting the saved `bootcmd` currently needs a UART console** once, to run
   `setenv` + `saveenv`. Automating that is in progress.
4. **No automated installer is published yet.** The manual procedure is in
   [`docs/install-image-requirements.md`](docs/install-image-requirements.md).

If you need a working box today, follow that document. If you want to help
finish it, see the roadmap below.

---

## Read this first if you have some other S905X4 box

**You may not need any of this.**

A lot of the difficulty here is specific to *this* board and *this* bootloader:

- the vendor bootloader here cannot `booti` a PE/ZBOOT-wrapped kernel, which is
  what essentially every distro ships — so a custom kernel has to be built
- the internal Ethernet PHY lives on a private MDIO bus that mainline's device
  tree does not describe, so mainline `stmmac` cannot drive it
- the device tree shipped with the vendor kernel has two variants and the wrong
  one aborts before the kernel prints anything

If your box already boots mainline Linux from a USB stick, you need none of
this and should stop reading. If you are hitting one of those specific walls,
this repo may save you a week.

The kernel here is built from **CoreELEC's `amlogic-5.4.210`** tree, which
already supports this SoC properly. That is the single biggest reason this
project is tractable.

---

## What the box ends up doing

On power cycle, with nothing connected:

```
BL2 → BL31 → U-Boot
  bootcmd (saved in U-Boot environment)
    mmc dev 1; mmc rescan
    ext4load mmc 1:1 0x2000000 Image
    ext4load mmc 1:1 0x5000000 sc2_s905x4_ah212_linux.dtb
    setenv bootargs 'root=/dev/mmcblk0p2 ... init=/root/rescue-init.sh'
    booti 0x2000000 - 0x5000000
      → Linux 5.4.210, root on eMMC, login prompt on ttyS0 and HDMI
```

---

## Layout

```
docs/
  install-image-requirements.md   what the image must fix, and why
  build-the-kernel.md             how the kernel was built; required for GPL compliance
  recovery.md                     unlock / ADNL / fastboot, and how to get back in
  troubleshooting.md              the traps, written down so you can avoid them
  lessons.md                      engineering lessons from this project
scripts/
  install-to-emmc.sh              provision eMMC from a running box
  rescue-init.sh                  fast init used instead of systemd
  uart/                           serial console tooling
kernel/
  sc2_s905x4_ah212_linux.dtb
  SHA256SUMS
patches/                          local patches applied to the vendor tree
notes/journal.md                  chronological project log
```

The kernel `Image` is a **release asset**, not in the repo — it is 34 MB.
Download it from the Releases page and check it against `kernel/SHA256SUMS`.

---

## Roadmap

| | Phase |
|---|---|
| P0 | boot chain, unattended eMMC boot — **done** |
| P1 | networking, clock, SSH after boot |
| P2 | automated installer: stick → box → standalone |
| P3 | recovery `bootcmd`: stick present means "re-provision me" |
| P4 | systemd — a real OS rather than a rescue shell |
| P5 | confirm HDMI and audio on real hardware; WiFi driver |
| P6 | packaging that assumes nothing about *this* box |
| P7 | optional boot menu via `sysboot`/extlinux |
| P8 | fleet rollout |

---

## Licence

Licensed by component, because they are not the same work:

| | |
|---|---|
| `scripts/`, `docs/`, `notes/`, `patches/` | **MIT** — see [LICENSE](LICENSE) |
| `kernel/Image`, `kernel/*.dtb` | **GPL-2.0** — built from CoreELEC / Amlogic sources |

The kernel and DTB are **not ours**. They are built from GPL-2.0 sources and are
redistributed under those terms, with full source provenance in
[`docs/build-the-kernel.md`](docs/build-the-kernel.md) as GPL-2.0 requires.

---

## Safety

- **Read `docs/recovery.md` before writing anything to a box.** There is a
  documented way back in, and it needs the box in a known state.
- If a box has had an OTA update, its bootloader has changed. A bootloader
  image from an un-updated unit is what the recovery path expects.
- Back up anything you care about. Provisioning overwrites the eMMC user area.