# Recovery

How to get back into a box that will not boot, and what to do **before** you
write anything to one.

Read this before provisioning hardware. Most of the difficulty described in this
project came from not having this written down.

---

## The recovery ladder

Try these in order. Each is less invasive than the next.

| | Method | Needs | Risk |
|---|---|---|---|
| 1 | **UART console** | CP210x adapter on the UART pads, 1 Mbaud | none |
| 2 | **The USB stick** | a stick flashed with the published image | none |
| 3 | **Button + USB A–A** → DNL → fastboot | USB A–A cable | low |
| 4 | **Reflash the bootloader** | DNL/fastboot write access | moderate |

### The environment is reachable from Linux

`fw_printenv` and `fw_setenv` **do work** on this board, but the stock
`/etc/fw_env.config` is wrong in two ways: it names `/dev/mmcblk1` (which does
not exist — only `mmcblk0` does) and the wrong offset. The environment lives
**inside p2**, 28 MiB in, at offset `0x7400000`:

```sh
printf '/dev/mmcblk0 0x7400000 0x10000 0x200\n' > /etc/fw_env.config
fw_printenv bootcmd
```

`scripts/find-env.sh` does this for you: it locates the environment read-only
by scanning for `bootcmd=` and verifying the candidate with `fw_printenv`. If
it cannot positively verify it, it exits non-zero rather than guessing.

**The environment is inside p2, so anything that rewrites p2 destroys it** —
including the installer, which is why the installer backs it up and restores
it. If you `dd` over p2 by hand, expect `bootcmd` to revert to the vendor
default and the box to boot the wrong thing.

---

## 1. UART console (preferred — read-only, always safe)

The development box has exposed UART pads and a CP210x adapter works reliably.

- **1,000,000 baud**, 8N1, no flow control. Requesting 1.5 Mbaud silently
  settles at 1 Mbaud, and 1 Mbaud is what produces clean text.
- The node `/dev/ttyUSB0` **re-enumerates** between sessions — re-check
  `ls /dev/ttyUSB*` before driving the console.
- U-Boot's prompt is **`sc2_ah212#`**, not `=>`. Grepping for `=>` misses it.
- **`bootdelay` is 3**, so there is a three-second window with
  `Hit any key to stop autoboot`. Press a key during it to get the prompt.
  Set it to 0 for a faster boot: `fw_setenv bootdelay 0`.
- **The window only exists when no USB stick is attached.** The vendor's own
  pre-boot chain scans the USB for `aml_autoscript` and runs it *before* the
  countdown, so with a stick plugged in the stick boots and the countdown
  never appears. Unplug the stick first if you want the prompt.
- Capture with a **single file descriptor held for read and write**. Re-opening
  the port between write and read resets termios and drops the reply.
- Long outputs (`crc32` over megabytes, long command echoes) are frequently
  **dropped entirely** over this link. Do not conclude a command did nothing
  because its output is missing — capture passively and re-read.
- **The serial link also drops long *input* lines.** A ~900-character command
  arrives truncated and U-Boot sits at a `>` continuation prompt. `Ctrl-C`
  does not escape it — send a lone `"`. Build long values from short pieces
  with hush expansion instead: `setenv y ${x}DEF` expands.

With a console you can always boot by hand:

```
mmc dev 1
ext4load mmc 1:1 0x2000000 Image
ext4load mmc 1:1 0x5000000 sc2_s905x4_ah212_linux.dtb
setenv bootargs 'root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw console=ttyS0,921600 earlycon=amlogic,meson-uart,0xfe07a000 no_console_suspend nowatchdog pd_ignore_unused clk_ignore_unused TERM=vt220 maxcpus=4 init=/lib/systemd/systemd'
booti 0x2000000 - 0x5000000
```

Use `init=/lib/systemd/systemd` for the normal system, or
`init=/root/rescue-init.sh` for the minimal rescue shell. **Both are in the
rootfs**, so this is a choice at the prompt, not a rebuild.

---

## 2. The USB stick (the fastest recovery)

If you have a stick flashed with the published image, plug it in and power
cycle. The box boots the stick, not the eMMC, and you get a working Linux
system with SSH regardless of what state the eMMC is in. The stick's
`aml_autoscript` wins over the saved `bootcmd`, because the vendor's pre-boot
chain runs it first.

This is why the stick is a **recovery key** and not just an installer: it
always boots, even if the eMMC is completely unusable.

---

## 3. ADNL / fastboot (when there is no usable console)

This is the escape hatch from a boot loop that cannot be interrupted — for
example one with `bootdelay=0` **and** a stick attached, where the vendor's
autoscript path takes over before the countdown.

### Enter DNL mode

Hold the **reset/pinhole button** while applying power, with a **USB A–A cable**
connected. The box enumerates as `1b8e:c004` "Amlogic, Inc. DNL".

A plain A–A cable works. No cable modification is needed.

Boot order **latches** on a warm reboot — only a full power cycle resets it.

### Sequence

```sh
export LD_LIBRARY_PATH=./usb_flow        # adnl bundles its own liblua
adnl devices                             # confirm the box is seen
adnl reboot bootloader                   # DNL -> fastboot
fastboot flashing unlock                 # -> "unlocked: yes"
fastboot erase env                       # clears the poisoned environment
fastboot reboot
```

`fastboot erase env` is the step that kills a bad `bootcmd` loop. The box comes
back with default environment, so `bootcmd` reverts to `run storeboot` and drops
to a prompt.

### Constraints

- **DNL partition read/write is blocked by secure boot** — `upload` returns
  `upload not allowed as secure boot enabled`. DNL mode is not a data-transfer
  path.
- **`oem/cmd`, `getvar`, `unlocked`, `secure` are unimplemented** in this
  stripped-down U-Boot.
- `oem/cmd '<shell command>'` is present in the binary but unsupported on this
  box; it was tried and did not work.
- Fastboot writes **do** work once unlocked.

### About the bootloader image

There is **no** original bootloader backup. If you need to restore one, it should
come from **a box that has not received an OTA update** — an updated box has a
different, signed bootloader. Community XDA threads are the usual alternative
source.

**No bootloader binary is redistributed with this project.** Vendor-signed
Amlogic bootloader stages are not ours to license, and a backup is only needed
for reflash recovery — not for any procedure documented here.

---

## 4. What to do *before* provisioning

1. **Confirm you have a UART console working.** Everything else depends on it.
2. **Confirm `ext4load mmc 1:1` reads your kernel and DTB.** If it does, a
   failed provision is always recoverable by hand.
3. **Note the expected hashes** of what you are about to write
   (`kernel/SHA256SUMS`).
4. **Do not `saveenv` an untested `bootcmd`.** `bootcmd` re-runs on every power
   cycle, so a failing one is a loop. Test in a scratch variable first — see
   [`troubleshooting.md`](troubleshooting.md).
5. **Back up the U-Boot environment before writing anything.** It lives inside
   p2, so anything that rewrites p2 destroys it. The installer does this for
   you (`/root/env-backup/`), but if you `dd` by hand, take your own copy:
   ```sh
   dd if=/dev/mmcblk0 bs=512 skip=237568 count=1024 of=env-block.bin
   ```

---

## If a boot loop is already in progress

1. Power cycle. With `bootdelay=3` you get a three-second window to press a
   key — **unplug the USB stick first**, or the vendor's autoscript path boots
   the stick before the countdown appears.
2. If you get the prompt, set `bootcmd` properly (or just boot by hand — see
   section 1).
3. If you cannot interrupt it, plug in a stick with the published image and
   let it boot; then fix `bootcmd` from there over SSH.
4. If neither works, use **DNL → fastboot → erase env**.
5. The bootloader itself lives in the eMMC **hardware boot partitions**
   (`mmcblk0boot0` / `boot1`, 4 MB each), not in the user area that
   provisioning writes. A failed provision does not touch it.