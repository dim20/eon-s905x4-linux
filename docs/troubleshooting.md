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
    console=ttyS0,921600 console=tty0 earlycon=amlogic,meson-uart,0xfe07a000 no_console_suspend \
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

---

## `dhclient` runs but no address appears

### Cause: passing `-t`

ISC dhclient 4.4.3 has **no `-t` flag** — that belongs to `udhcpc`. It exits
with a usage error and no lease:

```
Unknown command: -t
Usage: dhclient [-4|-6] [-SNTPRI1dvrxi] ...
```

This looks exactly like "DHCP is broken". Drop the flag and bound the wait by
polling for an address instead:

```sh
dhclient -q eth0
for i in $(seq 20); do
    ip -4 addr show eth0 | grep -q 'inet ' && break
    sleep 1
done
```

---

## `apt-get install <pkg>` says **"no installation candidate"**

for a package that plainly exists in the repo. Do not reach for
`--allow-unauthenticated` yet — **check the clock first.**

### Cause: the clock is at 1970

Every repository signature is dated 2026, so to a box that thinks it is 1970
every signature is in the future and **all repositories are rejected**:

```
W: OpenPGP signature verification failed: http://deb.debian.org/debian trixie/InRelease:
   error message is: Verifying signature: Not live until 2026-10-18T17:16:39Z
E: The repository 'http://deb.debian.org/debian trixie/InRelease' is not signed.
```

That produces "no installation candidate" — a message that reads like a
repository or architecture problem and is neither.

### Fix

```sh
date                                  # is it 1970?
date -s "$(date -u)"                  # from a host with the right time
apt-get update                        # now succeeds
```

### And do not let it happen on a fresh box

This creates a chicken-and-egg: wrong clock -> `apt` rejects all repos -> cannot
install `chrony` -> clock stays wrong. Ship `chrony` **pre-installed**;
`chronyd -q` needs only a network and DNS, not `apt`.

---

## Box boots but never gets an IP

`rescue-init.sh` brings networking up in the background. If it does not, check in
order:

```sh
cat /sys/class/net/eth0/carrier       # 1 = link up
ip -br addr show eth0                 # address?
cat /var/log/dhclient.log             # lease detail
cat /etc/resolv.conf                  # exists?
```

The DHCP client on this image does not write `resolv.conf` (`resolvconf` is not
installed), so a static one is shipped rather than relying on the lease.

---
## The network never comes up, even though the cable is plugged in

### Cause: the carrier check runs before the link is up

`rescue-init.sh` originally waited for carrier *before* bringing the interface
up:

```sh
# WRONG
while [ "$(cat /sys/class/net/eth0/carrier)" != "1" ]; do sleep 1; done
ip link set eth0 up
```

On a **down** interface, reading `carrier` does not return `0` — it returns
`EINVAL`:

```
# cat /sys/class/net/eth0/carrier
cat: /sys/class/net/eth0/carrier: Invalid argument
```

So the test could never succeed, the loop ran to its timeout, and the
interface was still down when `dhclient` started. And even after
`ip link set eth0 up`, the PHY needs about 1.5 s to report ready
(`ip link` at 146.12 s, `Link is Up` at 147.61 s), so a fixed one-second sleep
is not enough either.

### Fix: bring the link up FIRST, then poll for carrier

```sh
ip link set eth0 up
while [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" != "1" ]; do sleep 1; done
```

This is a **race**, not a hard failure: the same buggy script sometimes worked,
because the link happened to come up on its own during the 20-second wait.
Do not treat a working boot as proof the code is right.

---

## `fw_setenv` says "Cannot initialize environment"

### Cause: `/etc/fw_env.config` names the wrong device and the wrong offset

The stock config on this board points at `/dev/mmcblk1` — which does not exist
(only `mmcblk0` and its partitions do) — and at an offset that is not where
the environment actually lives.

### Fix: discover the environment, do not guess

`scripts/find-env.sh` locates it read-only: scan for `bootcmd=`, round down to
a 64 KiB boundary, then **functionally verify** by pointing a temporary
`fw_env.config` at the candidate and requiring `fw_printenv` to return a
plausible set of variables. If nothing verifies, it exits non-zero and the
installer refuses to touch the environment.

Two false positives to be aware of, both found the hard way:

- **A byte-identical copy of the environment passes every content check.**
  Because the installer `dd`s p2 wholesale, another partition can contain a
  full copy, and `fw_printenv` parses it happily. A variable *count* proves
  nothing, and neither does checking variable *names* — the copy has the same
  names. Only *position* discriminates.
- **A glob meant to match a partition can also match the whole device.**
  A pattern of `*[0-9]*` matches `/dev/mmcblk0` on its trailing digit.

The offset is a property of the board's U-Boot build, so it must be
discovered per box, never hardcoded.

---

## `fw_setenv` succeeded but the bootcmd is now `bootcmd=bootcmd=...`

### Cause: you passed `fw_printenv` output straight back into `fw_setenv`

`fw_printenv` prints `bootcmd=<value>`. `fw_setenv` wants the **bare value**.
Feeding one into the other stores the name twice, and the variable is broken.

### Fix

```sh
V=$(fw_printenv bootcmd | sed 's/^bootcmd=//')
fw_setenv bootcmd "$V"
```

Then **verify by reading back and comparing**, not by trusting the exit code:

```sh
fw_printenv bootcmd | sed 's/^bootcmd=//' | cmp - <(printf '%s' "$V")
```

Take a copy of the environment block before any write, so you can restore it:

```sh
dd if=/dev/mmcblk0 bs=512 skip=237568 count=1024 of=env-block.bin
```

---

## The U-Boot prompt shows `>` instead of running your command

### Cause: the line arrived truncated, leaving a quote unclosed

The serial link at 1 Mbaud cannot reliably carry a long line in one write. A
~900-character `bootcmd` was silently truncated, and U-Boot's parser sat in its
continuation prompt.

`Ctrl-C` does **not** escape it — you must send a lone `"` to close the open
quote.

### Fix: build long strings from short pieces

U-Boot's hush expands `${var}` inside `setenv`, so you can assemble a long
value from several short commands:

```sh
setenv p1 "usb start 0; if fatload usb 0:1 0x2000000 Image; then "
setenv p2 "setenv bootargs 'root=/dev/sda2 ...'; booti 0x2000000 - 0x5000000; "
setenv testcmd "${p1}${p2}"
```

Also: do **not** `printenv` a long value immediately before `saveenv`. Long
output over this link gets dropped, and `saveenv` can land mid-stream and
reset the board.

---

## A `dd`d filesystem is only as big as the source

### Cause: `dd` with no `count=` copies the whole source partition

```sh
dd if="$USB_ROOT" of="$P2" bs=4M conv=fsync
```

The destination partition is 14.9 GB, but only the source partition's bytes
are copied — about 773 MiB. The filesystem stays that size and the rest sits
unallocated, which looks exactly like a hardware fault from `df`.

### Fix: grow the filesystem after the copy

```sh
e2fsck -fp "$P2"
resize2fs "$P2"
```

And report the result rather than trusting the exit code:

```sh
dumpe2fs -h "$P2" | awk '
    /^Block count:/ { bc=$3 }
    /^Block size:/  { bs=$3 }
    END { if (bc && bs) print int(bc*bs/1048576) }'
```

Note the block size is **4096**, not the 512-byte sector size — assuming 512
reports a size 8× too small. And `Block count:` splits into fields 2 and 3;
the number is `$3`.

---

## A file exists, has the right name, and is still wrong

### Cause: a copy that failed partway leaves a zero-length file

Copying into a full filesystem can leave a 0-byte file that is indistinguishable
from a good one until you hash it. This happened to the kernel `Image` during
image preparation.

### Fix: hash every artefact after every copy

```sh
sha256sum Image sc2_s905x4_ah212_linux.dtb
```

Compare against `kernel/SHA256SUMS`. Do not trust "the file is there".

---

## The U-Boot environment disappears after re-running the installer

### Cause: the environment lives inside p2

On this hardware the U-Boot environment is 28 MiB into p2, so the installer's
`dd` of the rootfs **overwrites it** — including any `bootcmd` that makes the
box bootable.

### Fix: back the environment up before writing, and restore it after

`scripts/install-to-emmc.sh` does this automatically: it discovers the
environment, saves a 512 KiB copy, restores it after the `dd`, verifies the
restore from the device, and only then sets the new `bootcmd`.

If you do it by hand, the order matters:

```sh
dd if=/dev/mmcblk0 bs=512 skip=237568 count=1024 of=env-block.bin   # backup FIRST
# ... do the partition/format/dd ...
dd if=env-block.bin of=/dev/mmcblk0 bs=512 seek=237568 count=1024 conv=fsync
```

Note `seek` is in **sectors** when `bs=512` — the byte offset 121634816
divided by 512, not the byte offset itself.

---

## The stick is ignored and the box boots the eMMC anyway

### Cause: the bootcmd points at a path that does not exist on the stick

The installer reads the kernel from whichever directory it finds it in, but
the `bootcmd` it writes must load from **that same directory**. If the script
reads from the boot-partition root and writes `d/Image`, the `fatload` fails
**silently**, the `if` takes the else branch, and the box boots the eMMC as if
the stick were not there at all.

### Fix: derive the path in the bootcmd from the path you actually read

The published image keeps the artefacts at the boot-partition root, and the
installer derives the prefix from where it found them — so both the automatic
and the manual instructions agree.
