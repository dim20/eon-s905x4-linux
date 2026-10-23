# Storage

What is on the storage, how it is mounted, how the free space is
managed, and what the eMMC's own wear counters say. Everything here was
read from the box on **2026-10-23**; the numbers change, the arrangement
does not.

---

## The partitions

The eMMC is 14.6 GiB. The installer makes two partitions and gives the
root filesystem all the rest:

| Device | Size | Filesystem | What it holds |
|---|---|---|---|
| `/dev/mmcblk0p1` | 48 MiB | ext4 | `Image`, the DTB — the boot artefacts U-Boot loads |
| `/dev/mmcblk0p2` | 14.5 GiB | ext4 | the root filesystem |
| `/dev/mmcblk0boot0`, `boot1` | 4 MiB each | raw | the bootloader's own areas; do not touch |

The USB stick the same image is written to has the same two-partition
shape, but **64 MiB** for p1 and **800 MiB** for p2. The stick's p2 is
small on purpose: it is the install source, and its size sets the install
time. `scripts/grow-stick.sh` extends it into the stick's leftover space
if you want to use the stick as a live system.

**Why p1 is a different filesystem type on the two devices.** U-Boot's
`fatload` reads only FAT, so the stick's p1 must be FAT32; the eMMC's p1
must be ext4 for `ext4load`. The kernel is loaded from a different
filesystem type than the one the OS runs from, and that asymmetry is
required by the vendor's bootloader.

## Mount options

`/etc/fstab` mounts the root filesystem as:

```
/dev/mmcblk0p2   /   ext4   defaults,noatime   0   1
```

`noatime` means reading a file does not write a timestamp for it. On
flash storage that is the difference between "the system is idle" and
"the system writes a little on every read". There is **no `discard`
option**: continuous TRIM is not enabled. See the next section for why.

The boot partition is not mounted in normal operation. The kernel
package mounts it when it writes a kernel, and the smoke test mounts it
read-only to verify the hashes.

## TRIM and `fstrim.timer`

`fstrim.timer` is enabled and runs weekly. It is the right arrangement
in principle: a periodic batch discard costs less than continuous
`discard` and gives the flash controller a chance to erase blocks
properly.

**On this eMMC, discard is not supported.** The kernel reports:

```
/sys/block/mmcblk0/queue/discard_granularity   0
/sys/block/mmcblk0/queue/discard_max_bytes     0
```

and `fstrim -v /` says:

```
fstrim: /: the discard operation is not supported
```

The timer still runs, but the service's command line includes
`--quiet-unsupported`, so "not supported" is not treated as a failure and
the service exits 0 without logging anything. That is why `fstrim.service`
is inactive and never appears as a failed unit. **Leave the timer
enabled.** Disabling it would change nothing on this hardware and would
lose the behaviour on hardware that does support discard.

Do not add `discard` to the mount options: on a device with no discard
support it is a no-op at best, and it costs a queue round-trip on every
delete at worst.

## eMMC wear

The eMMC exposes its own life-time estimate in sysfs. These are the
vendor's numbers, not a guess:

```
$ cat /sys/block/mmcblk0/device/life_time
0x01 0x00
$ cat /sys/block/mmcblk0/device/pre_eol_info
0x01
```

- `life_time` is two values, one per life-time estimate. `0x01` means
  0–10% of the rated write endurance has been used. The scale runs
  `0x01`…`0x0A` for 0–100% in 10% steps; `0x0B` means the estimate is
  exceeded. The second value is `0x00`, meaning the device does not
  define that estimate.
- `pre_eol_info` is `0x01` = normal. `0x02` = warning (80% used),
  `0x03` = urgent (90% used).

The device is healthy. Re-read those two files when you want to know
whether it still is; no extra tool is needed. `mmc-utils` (`mmc extcsd
read /dev/mmcblk0`) gives the same numbers plus more detail, but it is
not installed and not required for this check.

**What writes to the eMMC.** The root filesystem, the journal, package
updates, logs. `noatime` removes the read-triggered writes. The journal
is **persistent** (`/var/log/journal` exists), which is the right choice
for a box you may have to diagnose after a crash; the cost is small. If
you ever need to minimise writes at the expense of losing logs across
reboots, make the journal volatile — but do it knowing what you lose.

## Free space

At the time of writing the eMMC root filesystem is **809 MiB used of
15 GiB, 13 GiB free**. The stick's p2 starts at 800 MiB and grows to fill
whatever stick it is written to.

The ext4 reserved-block count is the default 5% (190,092 blocks of
3,801,856). That is ~760 MiB held back for root's use on this filesystem.
It is not a problem at 6% used; if the filesystem ever gets tight,
`tune2fs -m 1 /dev/mmcblk0p2` drops the reserve to 1% and releases about
600 MiB. Do that deliberately, not by default.

## The vendor's stick-growing script is gone

The vendor's image grew its own root filesystem on first boot by
rewriting the partition table. That is why a stick written from a vendor
image "grows" on first boot. This image **removes** the script and masks
the unit that ran it: the stick stays the size it was written, and the
eMMC's size is set by the installer. See
[`../manifest/vendor-leftovers.txt`](../manifest/vendor-leftovers.txt).

---

## Last verified

**2026-10-23**, on the eMMC system (`/dev/mmcblk0p2`), with the USB stick
removed:

- `fstrim.timer` enabled and active, weekly schedule;
- `fstrim -v /` → "the discard operation is not supported", rc=1, and
  `fstrim.service` uses `--quiet-unsupported`, so the timer does not
  produce a failed unit;
- `discard_granularity` and `discard_max_bytes` are both 0;
- `life_time` `0x01 0x00`, `pre_eol_info` `0x01` — healthy, 0–10% used;
- 809 MiB used of 15 GiB, 13 GiB free;
- root mounted `defaults,noatime`, no `discard`;
- `/var/log/journal` exists (persistent journal).
