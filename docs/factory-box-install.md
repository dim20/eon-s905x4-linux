# Starting from an untouched or OTA-upgraded box

This is the path for a box that still has its **factory bootloader and a
working Android** on the eMMC, with no prior modification. It is the box
you get from the supplier or after an OTA update. A box in that state does
**not** boot the USB stick automatically. You need the serial console
once, but you do **not** need a fastboot bootloader unlock to boot the
stick or to install Debian.

If your box **does** boot the stick on its own, its eMMC boot is already
failing and the vendor's fallback is doing it — see "Why one box
autoboots the stick and another does not" below. The install path is the
same.

The end state is the same as any other EON Linux box: Debian on the
eMMC, booting unattended with nothing plugged in.

---

## What the vendor bootloader actually does

Every tested box — factory, OTA-upgraded and "unlocked" — carries the
same stock environment (`sc2_ah212`):

```text
bootcmd=run storeboot
bootdelay=0
preboot=run bcb_cmd; run upgrade_check; run init_display; run storeargs;
        run upgrade_key; run recovery_key; bcb uboot-command;
        run switch_bootmode
```

- `switch_bootmode` falls through to `storeboot`.
- `storeboot` reads the eMMC's `boot_a` partition and boots Android.
- **If that succeeds, USB is never touched.**
- **If it fails, the vendor's fallback takes over.** `storeboot` ends
  with `echo try upgrade as booting failure; run update`, and:

  ```text
  update=run usb_burning; run recovery_from_sdcard;
         run recovery_from_udisk; run recovery_from_flash;
  ```

  `usb_burning=adnl 1200` offers Amlogic's ADNL burning mode (it times
  out if no host is running the burning tool), then the SD card is
  tried, then `recovery_from_udisk`, which starts USB and runs
  `aml_autoscript` from the stick's FAT partition. That last step is why
  a box with a broken eMMC boot **boots our stick automatically**.

  This is the vendor's emergency fallback. It is **not** an unlock and
  **not** a `bootcmd` change.

The `factory_update_param.aml` message in the boot log is the vendor's
factory-update check looking for an INI file. Our Linux stick does not
carry it, so the check fails with:

```text
fail in cmd [fatsize usb 0 factory_update_param.aml], rcode 1
ERR ... File factory_update_param.aml not exist in sdcard??
```

That message is expected and harmless.

### Why one box autoboots the stick and another does not

| Box state | What happens on power-on |
|---|---|
| eMMC boots Android normally | `storeboot` boots Android; the stick is ignored |
| eMMC boot fails — for example an edited `vbmeta` failing AVB verification | `storeboot` falls to `update` → `recovery_from_udisk` → **the stick boots automatically** |
| eMMC boot fails and no stick is inserted | the fallback chain runs out and the box stops at the U-Boot prompt |

A box that autoboots the stick is therefore telling you its eMMC boot is
broken, not that it was "unlocked to prefer USB". Installing EON Linux to
the eMMC fixes that, because the installer replaces the boot command and
the boot partition.

### The USB recovery path in the environment

The environment also names the recovery path directly:

```text
recovery_from_udisk=setenv bootargs ${bootargs} androidboot.selinux=permissive;
  setenv fatload_dev usb; if usb start 0; then run recovery_from_fat_dev; fi;
recovery_from_fat_dev=setenv loadaddr ${loadaddr_kernel};
  if fatload ${fatload_dev} 0 ${loadaddr} aml_autoscript; then
    autoscr ${loadaddr}; fi; ...
```

So the stick is reachable; the vendor's default boot order just does not
choose it while the eMMC boots.

### No unlock required

The prompt is open, and `forUpgrade_secureBoot=false`. The board accepts
commands at the U-Boot prompt without a fastboot unlock. **No tested box
has a modified `bootcmd`:** the factory box, the OTA-upgraded box and the
"unlocked" experiment box all report `bootcmd=run storeboot`. The box
that autoboots the stick does so because its eMMC boot fails and the
vendor fallback picks USB — see the table above. The factory box needs
one command, described below.

---

## What you need

| Item | Notes |
|---|---|
| CP210x USB-UART adapter | Wired to the board's UART pads: GND, TX, RX. Opening the case is a hardware step. |
| USB stick | Flashed with the published `v0.7.1-tty` image (1 GB or more). |
| Serial terminal | `screen`, `picocom`, `minicom`, or the scripts in the project's development repository. |

### Serial speed

The rates differ by board and by stage:

- the development box's U-Boot is at **1,000,000** baud;
- the tested factory box's console was readable at **1,500,000** baud in
  the capture used;
- the published image's `aml_autoscript` requests
  `console=ttyS0,921600` for the Linux kernel.

Match the rate at which your board prints. If the text is garbled, try
the other rates. U-Boot and Linux can end up at different rates on the
same board; if the boot log is readable but the login prompt is not,
reconnect at the rate the kernel is using.

---

## Step 1 — connect and stop at U-Boot

1. Wire the adapter to the UART pads and open the port at the board's
   rate.
2. Power on. U-Boot prints its boot log. On the tested factory box it
   stopped at `sc2_ah212#` after the factory-update check failed.
3. If your box boots Android instead, power-cycle it and send Enter (or
   any key) during the early boot. If `bootdelay=0` leaves no window,
   see [`recovery.md`](recovery.md) for the upgrade-key and DNL/fastboot
   paths; those are the invasive fallbacks.
4. Confirm the prompt answers `printenv`.

**Back up the environment before changing anything.** Save your own
`printenv` output somewhere you can find it:

```text
printenv
```

If you later change `bootcmd`, the original values are your way back. The
environment from the boxes used to write this guide is kept in the
project's development repository, not in this one.

---

## Step 2 — boot the stick manually

At the U-Boot prompt:

```text
run recovery_from_udisk
```

What it does:

1. `usb start 0` — starts the USB controller.
2. `fatload usb 0 ... aml_autoscript` — loads the stick's boot script
   from its FAT boot partition.
3. `autoscr` — runs it. The script loads `Image` and the DTB from the
   stick's p1 and boots Linux with `root=/dev/sda2`.

You should see the kernel boot, `fbcon: Taking over console`, and the
EON Linux banner and login on the serial console. If the USB stick is
present and the script is intact, this is a **non-destructive** boot:
nothing is written to the eMMC.

If it does not boot, the serial output names the failing step. Check
that `usb start 0` finds the stick and that p1 contains
`aml_autoscript`, `Image` and the DTB. The exact error is more useful
than a retry.

### Verified on the tested factory box

- `run recovery_from_udisk` booted the v0.7.1-tty stick.
- Root was `/dev/sda2`; `dmesg | grep -c "Taking over console"` was `1`.
- `/root/smoke-test.sh` passed **24/24 checks, exit 0**.
- The box booted **without** a fastboot unlock.

The serial evidence is kept in the project's development repository, not
in this one.

---

## Step 3 — install Debian on the eMMC

From the booted stick, run the installer:

```sh
/root/install-to-emmc.sh
```

It writes the kernel, DTB and `aml_autoscript` to p1 and the rootfs to
p2, backs up and restores the U-Boot environment, and sets `bootcmd` to
try USB first and fall back to the eMMC. After installation:

1. Power off.
2. Remove the stick.
3. Cold-boot with nothing plugged in.
4. Confirm `findmnt -n -o SOURCE /` prints `/dev/mmcblk0p2`, and run
   `/root/smoke-test.sh`.

The install step is the same one verified on the development box. At the
time of writing it had **not yet been exercised on a factory box**; the
factory box had only been booted from the stick. Treat that as the
remaining check, not as a proven step.

### What you lose

The eMMC is overwritten. There is no dual-boot with the factory Android
after the install. Back up anything you care about first. The installer
backs up the U-Boot environment, not Android's data.

### Making the stick boot automatic

The installer's `bootcmd` tries USB first and then the eMMC. That means
the installed box boots the stick when one is present and the eMMC when
none is. If you want a different order, change `bootcmd` after the
install and keep the backed-up environment as the way back. See
[`recovery.md`](recovery.md) for `find-env.sh`, `fw_printenv` and
`fw_setenv`.

---

## Caveats and findings

- **The serial console is required** for a factory box. There is no
  network in U-Boot on this board: its Ethernet uses the wrong MAC
  (`ff3f0000` instead of `fdc00000`), so `dhcp` and `tftp` fail. Do not
  spend a session on netboot.
- **The factory update check is not our boot path.** It looks for
  `factory_update_param.aml`; our stick deliberately does not carry it.
  The "file not exist" message is expected.
- **The environment lives inside p2** at offset `0x7400000`. Anything
  that rewrites p2 destroys it. The installer backs it up and restores
  it; a manual `dd` over p2 does not. See [`recovery.md`](recovery.md).
- **The board's Android bootargs are not our bootargs.** Our
  `aml_autoscript` sets its own `root=`, console and init. Do not reuse
  the vendor's `bootargs` for Linux.
- **Fastboot/DNL is not needed for this path.** It is only for
  reflashing the bootloader or a recovery image. If the prompt is
  reachable, the stick path above is enough.

---

## See also

- [`recovery.md`](recovery.md) — the recovery ladder, the UART console,
  the environment location, and the invasive fallbacks.
- [`install-image-requirements.md`](install-image-requirements.md) — what
  the stick image must contain.
- [`troubleshooting.md`](troubleshooting.md) — traps already hit.
