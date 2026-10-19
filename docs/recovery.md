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
| 2 | **Button + USB A–A** → DNL → fastboot | USB A–A cable | low |
| 3 | **Reflash the bootloader** | DNL/fastboot write access | moderate |

`fw_printenv` from Linux is **not** an option on this board — the offsets do not
match and it returns `Cannot initialize environment`. U-Boot environment changes
must be made at the U-Boot prompt or via fastboot.

---

## 1. UART console (preferred — read-only, always safe)

The development box has exposed UART pads and a CP210x adapter works reliably.

- **1,000,000 baud**, 8N1, no flow control. Requesting 1.5 Mbaud silently
  settles at 1 Mbaud, and 1 Mbaud is what produces clean text.
- The node `/dev/ttyUSB0` **re-enumerates** between sessions — re-check
  `ls /dev/ttyUSB*` before driving the console.
- U-Boot's prompt is **`sc2_ah212#`**, not `=>`. Grepping for `=>` misses it.
- `bootdelay` is **0**, so there is no countdown window to interrupt. Send a key
  during power-up, or attach the catcher first.
- Capture with a **single file descriptor held for read and write**. Re-opening
  the port between write and read resets termios and drops the reply.
- Long outputs (`crc32` over megabytes, long command echoes) are frequently
  **dropped entirely** over this link. Do not conclude a command did nothing
  because its output is missing — capture passively and re-read.

With a console you can always boot by hand:

```
mmc dev 1
ext4load mmc 1:1 0x2000000 Image
ext4load mmc 1:1 0x5000000 sc2_s905x4_ah212_linux.dtb
setenv bootargs "root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw console=ttyS0,921600 earlycon=amlogic,meson-uart,0xfe07a000 no_console_suspend nowatchdog pd_ignore_unused clk_ignore_unused TERM=vt220 maxcpus=4 init=/root/rescue-init.sh"
booti 0x2000000 - 0x5000000
```

---

## 2. ADNL / fastboot (when there is no usable console)

This is the escape hatch from a boot loop that `bootdelay=0` has made
uninterruptible.

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

## 3. What to do *before* provisioning

1. **Confirm you have a UART console working.** Everything else depends on it.
2. **Confirm `ext4load mmc 1:1` reads your kernel and DTB.** If it does, a
   failed provision is always recoverable by hand.
3. **Note the expected hashes** of what you are about to write
   (`kernel/SHA256SUMS`).
4. **Do not `saveenv` an untested `bootcmd`.** `bootcmd` re-runs on every power
   cycle; a failing one with `bootdelay=0` is a hard loop. Test in a scratch
   variable first — see [`troubleshooting.md`](troubleshooting.md).

---

## If a boot loop is already in progress

1. Power cycle. If U-Boot prints a prompt, you are fine — set `bootcmd` properly.
2. If it goes straight into the silent kernel, use **DNL → fastboot → erase env**.
3. The bootloader itself lives in the eMMC **hardware boot partitions**
   (`mmcblk0boot0` / `boot1`, 4 MB each), not in the user area that
   provisioning writes. A failed provision does not touch it.