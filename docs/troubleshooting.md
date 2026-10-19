# Troubleshooting

Every entry here is a fault that actually happened on this hardware. They are
ordered roughly by how much time they cost.

---

## Boot reaches U-Boot but the kernel produces **no output at all**

Not a kernel panic — *nothing*. No `Linux version`, no earlycon stamps. U-Boot
prints `Starting kernel ... boot 64bit kernel` and then silence.

### Cause 1: wrong DTB variant (most likely)

The vendor tree ships `sc2_s905x4_ah212.dtb` (Android) and
`sc2_s905x4_ah212_linux.dtb`. The **Android** one has no DRM include at all and
aborts before console init.

Use `sc2_s905x4_ah212_linux.dtb`.

### Cause 2: memory node larger than the hardware

A DTB declaring 4 GB on a 2 GB box makes the kernel die before `printk`. Check
`/memory@0` `reg` against the real size.

### Cause 3: the kernel image on the storage is corrupt

Check this **before** diagnosing anything else. See the next entry.

> Absence of console output is not evidence about the kernel. It may never have
> started.

---

## `sha256sum` of a file on eMMC returns **Input/output error**

and `dmesg` shows:

```
attempt to access beyond end of device mmcblk0p1: rw=..., want=..., limit=98304
```

### Cause: the filesystem is larger than its partition

Decode the FAT32 BPB and compare against the partition:

```sh
dd if=/dev/mmcblk0p1 bs=1 skip=32 count=4 2>/dev/null | od -A none -t u4 --endian=little
blockdev --getsz /dev/mmcblk0p1
```

BPB offset 32–35 is `total_sectors32` little-endian. If it exceeds
`blockdev --getsz`, the filesystem overruns the partition and any file whose
cluster allocation lands in the overhang cannot be read or written.

This happened here: BPB said **102400** sectors, the partition was **98304**.

### Fix

Reformat the partition so the filesystem matches. **Use ext4.** This box has no
FAT tooling at all — `mkfs.vfat` is absent and there is no `busybox` — and U-Boot
loads ext4 with `ext4load` anyway.

```sh
umount /mnt/p1
mkfs.ext4 -F -L BOOT /dev/mmcblk0p1
```

### How it presented, and why it was nearly missed

The corrupted file had the **correct size**, and the copy looked successful. It
differed from the good copy only from byte ~1.2 MB onward, and reads behaved
confusingly: OK to 13 MB, fail 14–16 MB, fine again after 16 MB — fragmented
cluster allocation, some clusters in the dead zone and some not.

The failure was: **a silent kernel that cost a whole session**, during which the
eMMC boot path was wrongly blamed on the bootloader.

---

## A hash taken after `cp` matches, but the file is still wrong

### Cause: page cache

```sh
cp /mnt/u1/d/Image /mnt/p1/Image
sync
sha256sum /mnt/p1/Image        # MATCHES — but only in the page cache
```

The bytes may never have reached storage. The failure above looked clean here.

### Fix: always verify from storage

```sh
umount /mnt/p1
mount -o ro /dev/mmcblk0p1 /mnt/p1
sha256sum /mnt/p1/Image
```

This is the single most useful habit in this project. Every installer must do
it.

---

## `booti` from a U-Boot script **resets the CPU** (`bl31 reboot reason: 0xd`)

### Cause: escaped double quotes in `bootargs`

```sh
setenv bootcmd "...; setenv bootargs \"root=/dev/mmcblk0p2 ...\"; booti ..."
```

The outer `setenv` stores the backslashes literally. The kernel receives a
mangled command line and dies before console init.

### Fix: single quotes

```sh
setenv bootcmd "mmc dev 1; mmc rescan; \
  ext4load mmc 1:1 0x2000000 Image; \
  ext4load mmc 1:1 0x5000000 sc2_s905x4_ah212_linux.dtb; \
  setenv bootargs 'root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw \
    console=ttyS0,921600 earlycon=amlogic,meson-uart,0xfe07a000 no_console_suspend \
    nowatchdog pd_ignore_unused clk_ignore_unused TERM=vt220 maxcpus=4 \
    init=/root/rescue-init.sh'; \
  booti 0x2000000 - 0x5000000"
```

Single quotes inside the outer double-quoted string work correctly as delimiters
for the inner `setenv`.

> This is why the old note "bootargs does not reach the kernel on an unattended
> boot" is misleading — that test used the broken escaped-quote form.

### `printenv` will mislead you

`printenv bootcmd` displays the working string with the inner single quotes
**absent**. They are present in the value; the display drops them. Check the
kernel's `Kernel command line:` line, not `printenv`.

---

## `bootcmd` runs but the box comes up silent, and power cycling repeats it

### Cause: `bootargs` did not reach the kernel

With `bootdelay=0`, `bootcmd` re-runs on every power cycle. A silent kernel is an
**unrecoverable loop** — there is no window to interrupt into.

### Prevention

Embed `bootargs` inside `bootcmd` (single quotes, above) rather than relying on
a separate saved variable. Then the only remaining failure is
`Bad Linux ARM64 Image magic!`, which returns to the prompt.

### If you are already in that loop

Button + USB A–A for DNL mode, then `adnl reboot bootloader` → `fastboot` →
`fastboot flashing unlock` → `fastboot erase env` → `fastboot reboot`. See
[`recovery.md`](recovery.md).

---

## `apt-get update` hangs forever with an empty `/var/lib/apt/lists/`

It looks like "no packages available". It is three unrelated faults stacked.

| Check | Symptom | Fix |
|---|---|---|
| `/etc/resolv.conf` | **does not exist** — `dhclient` never writes one | ship a `resolv.conf` |
| DNS answers | **AAAA only**, and there is no IPv6 route → apt stalls on v6 | `Acquire::ForceIPv4 "true";` |
| Clock | reads **1970**, so every repo `Release` (dated 2026) looks future-dated | set the clock |

Verify the layers separately:

```sh
ip route                       # default route present?
ping -c1 -W2 1.1.1.1           # IP connectivity?
cat /etc/resolv.conf            # exists?
getent hosts deb.debian.org     # resolves?
date                            # sane?
```

Note `Acquire::ForceIPv4 "true";` is the **config file** form. The
`-o Acquire::ForceIPv4=true` form is command-line only and is a syntax error in a
config file.

---

## Everything returns empty — `ps`, `cat /proc/partitions`, `netstat`

### Cause: `/proc` is not mounted

Booting with `init=/bin/sh` gives a bare shell. Nothing mounts the pseudo
filesystems, and every `/proc` read returns nothing or fails. This makes devices
look absent when they are not — it briefly looked like the eMMC had vanished.

```sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev 2>/dev/null
```

---

## `fatload usb` from U-Boot resets the box

```
BUG at ../drivers/usb/host/xhci-ring.c:496/abort_td()!
resetting ...
```

A ~34 MB USB read into a high address trips an xHCI bug in this U-Boot.

- Large USB reads into high addresses: **avoid**. `0x2000000` is proven fine.
- `fatload mmc 1:1` is unaffected and fast (≈138 MiB/s).
- This is U-Boot-only. Linux USB mass storage works normally.

---

## U-Boot notes worth knowing

- **`ext4load`, not `fatload`, against p1** — the provisioning filesystem is ext4.
- **No `sleep` command.** To let the eMMC settle between `mmc dev` and `booti`,
  use `mmc rescan`, which re-runs the tuning sequence cleanly.
- **`;` separates commands** inside a variable run by `run`. It does *not* work
  when typed interactively.
- **`mmc dev 1` prints `resp timeout, cmd8`** every time. That is normal on this
  box, not an error.
- **U-Boot prints block numbers in decimal while parsing hex.** Cross-check.
- **`printenv` and `fatls` are not always trustworthy** — see above.

---

## Kernel build traps

- **PE/ZBOOT**: if `Image` starts with `MZ`, `booti` cannot load it. Check with
  `xxd -l 64 Image`.
- **Config edits may not stick** — `syncconfig` can silently re-enable a symbol.
  Verify after every change.
- **Wrong DTB variant** gives a `Synchronous Abort` with no output.
- See [`build-the-kernel.md`](build-the-kernel.md) for the full procedure.