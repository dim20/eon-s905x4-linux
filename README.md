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

**v0.3-image** — a stick image you can `dd` and boot. Works on the development
box. Not yet validated on other hardware.

| | |
|---|---|
| Boots unattended from eMMC | ✅ power cycle only, ~7 s to a systemd login |
| Boots unattended from the stick | ✅ 1 boot / 1 booti / 0 prompts |
| systemd | ✅ running as PID 1 — 0 failed units, `apt` works |
| 4 cores | ✅ |
| Ethernet 100 Mbps | ✅ internal RMII PHY |
| HDMI | negotiated 1080p60 over EDID, DRM initialises — **picture never confirmed on a screen** |
| Audio | ASoC card + SPDIF register — **never confirmed audible** |
| USB 2.0 / 3.0 | ✅ |
| Bluetooth | present |
| DVB tuner | ❌ not populated on this variant |
| WiFi | ❌ RTL8812CS, no open driver (you supply a closed one) |
| Network after boot | ✅ DHCP, DNS, SSH — verified from a cold power cycle |
| Clock after boot | ✅ chrony, with a persisted last-known-good fallback |
| Automated eMMC install | ✅ runs end-to-end, verifies every write from storage |
| Bootcmd installed automatically | ✅ the installer discovers the U-Boot env and sets it |
| U-Boot recovery window | ✅ `bootdelay=3` — a "hit any key" prompt on every boot |
| Root filesystem size | ✅ 15 GB on the eMMC, not the 744 MB it started as |

### Quick start

Download `eon-s905x4-linux-stick.img.gz` from the Releases page and write it
to a USB stick of 1 GB or more:

```sh
gunzip -c eon-s905x4-linux-stick.img.gz | sudo dd of=/dev/sdX bs=4M status=progress
sync
```

Plug it into the box and power cycle. The box boots the stick, brings up
networking and SSH, and gives you a login (`root` / `tvbox`):

```sh
ssh root@<the address the box says on the serial console>
```

From there, provision the eMMC:

```sh
/root/install-to-emmc.sh
```

It verifies every artefact before and after writing, grows the filesystem to
fill the eMMC, and sets the boot command so the box boots on its own
afterwards. **Remove the stick and power cycle** to confirm.

If your stick is larger than 1 GB and you want the extra space in the live
system, run `scripts/grow-stick.sh` against it first.

### Known gaps in v0.3

These are real and will bite you:

1. **HDMI and audio have never been seen working.** DRM negotiates a mode and
   the ASoC card registers, but nobody has looked at a screen or heard a
   speaker. Treat both as untested.
2. **The clock fallback is only unit-tested.** The chrony success path is
   proven on hardware; the "no network at boot" path has not been exercised on
   a real box.
3. **The default root password is `tvbox`.** Change it, or do not put the box
   on an untrusted network.
4. **Only one box has been tested.** Everything below was proven on one
   development box. It has not been tested on any other hardware.
5. **The first boot may need the vendor's own update path.** If your box does
   not find `aml_autoscript` on the stick by itself, see
   [`docs/recovery.md`](docs/recovery.md) — you will need a UART console once.

If you want to help finish it, see the roadmap below.

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
  "Hit any key to stop autoboot:  3  2  1  0"     ← 3 s to reach the U-Boot prompt
  bootcmd (saved in the U-Boot environment, set by the installer)
    usb start 0
    if fatload usb 0:1 0x2000000 Image; then
        → boot from the USB stick, root on /dev/sda2
    else
        mmc dev 1; mmc rescan
        ext4load mmc 1:1 0x2000000 Image
        ext4load mmc 1:1 0x5000000 sc2_s905x4_ah212_linux.dtb
        setenv bootargs 'root=/dev/mmcblk0p2 ... init=/lib/systemd/systemd'
        booti 0x2000000 - 0x5000000
        → Linux 5.4.210, root on eMMC, systemd as PID 1
```

The stick is a **recovery key**, not a dependency: plug it in and the box
boots the stick, unplug it and the box boots the eMMC. No menu, no countdown
apart from the three-second U-Boot window.

### If something goes wrong

There are three ways back in, in increasing order of effort:

1. **Plug the stick in.** It boots a complete Linux system with SSH, whether
   or not the eMMC works. This is why the stick is a recovery key.
2. **Interrupt the boot at the U-Boot prompt.** `bootdelay` is set to 3, so
   there is a three-second window with "Hit any key to stop autoboot". With
   nothing but a serial adapter you can then boot a different `init=` — the
   rootfs carries both `systemd` and a minimal `rescue-init.sh`:

   ```
   setenv bootargs 'root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw console=ttyS0,921600 init=/root/rescue-init.sh'
   ext4load mmc 1:1 0x2000000 Image
   ext4load mmc 1:1 0x5000000 sc2_s905x4_ah212_linux.dtb
   booti 0x2000000 - 0x5000000
   ```

   To change the delay, `fw_setenv bootdelay 0` (faster boot, no window) or
   any other value in seconds. The installer sets it to 3.
3. **Unlocking the bootloader** — ADNL and fastboot. See
   [`docs/recovery.md`](docs/recovery.md).

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
  rescue-init.sh                  minimal init — the fallback if systemd fails
  find-env.sh                     locate the U-Boot environment (read-only)
  prepare-stick.sh                make a stick a self-contained live system
  grow-stick.sh                   extend a stick's rootfs into leftover space
  build-stick-image.sh            build the published .img.gz from a rootfs tree
  write-stick-image.sh            write it to a stick and verify it byte-for-byte
  stick/                          the aml_autoscript uImage and its source
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
| P1 | networking, clock, SSH after boot — **done** |
| P2 | automated installer: stick → box → standalone — **done** |
| P3 | recovery `bootcmd`: stick present means "re-provision me" — **done** |
| P4 | systemd — a real OS rather than a rescue shell — **done** |
| P5 | confirm HDMI and audio on real hardware; WiFi driver |
| P6 | packaging that assumes nothing about *this* box — **mostly done** |
| P7 | optional boot menu via `sysboot`/extlinux — deferred |
| P8 | rollout to other hardware, once validated |

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