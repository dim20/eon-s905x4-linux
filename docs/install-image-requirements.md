# Install Image Requirements

Changes that must be baked into the image shipped to each box. Each one is a
fault found on the test box on 2026-10-19 — none of them are theoretical.

> **Status.** All of these were originally requirements on the image. They are
> now baked into the published image, and the reasoning is kept below because
> it is the part worth having: every one of these faults is invisible from the
> boot log and shows up as something else entirely.

## 1. Clock (BLOCKING — and it blocks apt in a way that is easy to misdiagnose) — DONE

Box boots with `Thu Jan 1 1970`. Causes:
- `hwclock` binary absent from the rootfs
- meson-vrtc RTC reads back invalid, so nothing sets the time

### The failure mode looks nothing like a clock problem

With the clock at epoch, `apt-get update` reports:

```
W: OpenPGP signature verification failed: http://deb.debian.org/debian trixie/InRelease:
   Sub-process /usr/bin/sqv returned an error code (1),
   error message is: Verifying signature: Not live until 2026-10-18T17:16:39Z
E: The repository '...' is not signed.
```

`Not live until 2026-10-…` — the repository signature is dated 2026 and the box
thinks it is 1970, so every signature is in the future and **all repositories are
rejected as unsigned**. `apt-get install` then says a perfectly available package
"has no installation candidate".

**If you see "no installation candidate" for a package you know exists, check
`date` before anything else.**

Other consequences:
- PAM refuses logins: `account root has password changed in future`
- TLS breaks
- log timestamps are meaningless

### The chicken-and-egg, and how to break it

The obvious fix is NTP — but NTP normally arrives via `apt`, and `apt` is exactly
what the broken clock prevents:

```
clock wrong  →  apt refuses all repos  →  cannot install chrony  →  clock stays wrong
```

Break it **either** way:

- **(a) Ship `chrony` pre-installed in the image.** Preferred. `chronyd` does not
  need `apt`, only a network and DNS, and `rescue-init.sh` runs it as soon as
  `eth0` has an address.
- **(b) Have the installer set the clock over the network first** (from the host
  that is provisioning, or from any host with `ntpdate`/`chronyc`). Then `apt`
  works and `chrony` can be installed normally.

Do **not** reach for `Acquire::AllowInsecureRepositories` or
`--allow-unauthenticated`. That converts a fixable clock problem into a permanent
supply-chain hole.

### Once the clock is right

```sh
date -s "$(date -u)"          # from a host with the correct time
apt-get update                 # now succeeds
```

## 2. `/etc/resolv.conf` (BLOCKING) — DONE

The file **does not exist** on a fresh boot. `dhclient` obtains the lease but
never writes a resolver — `resolvconf` is not installed.

Result: no DNS. `apt-get update` hangs indefinitely with an empty
`/var/lib/apt/lists/`, which reads exactly like "no packages available".

Fix: ship `/etc/resolv.conf` with `nameserver 8.8.8.8` / `nameserver 1.1.1.1`.
Do not rely on DHCP to create it.

## 3. Force IPv4 for apt — DONE

DNS returns **AAAA only** for `deb.debian.org`, and the box has no IPv6 route,
so apt stalls trying to fetch over v6.

Ship `/etc/apt/apt.conf.d/99force-ipv4`:
```
Acquire::ForceIPv4 "true";
```
(note: the `-o Acquire::ForceIPv4=true` form is command-line only and is a
**syntax error** inside a config file.)

## 4. Networking in `rescue-init.sh` (BLOCKING for headless) — DONE

`rescue-init.sh` now brings up networking unattended. The order matters, and
getting it wrong produces a **race** rather than an obvious failure:

1. `ip link set eth0 up` — **first**
2. wait for carrier (poll, up to ~20 s)
3. `dhclient eth0`
4. write `/etc/resolv.conf`
5. set the clock (chrony, with the persisted last-known-good fallback)
6. start `sshd` (`mkdir -p /run/sshd; ssh-keygen -A; /usr/sbin/sshd &`)

Step 1 must come before step 2: reading
`/sys/class/net/eth0/carrier` on a **down** interface returns `EINVAL`, not
`0`, so a poll that runs first can never succeed. And the PHY needs ~1.5 s
after the link goes up, so a fixed one-second sleep is not enough either.

This runs **in the background** so it never blocks the serial console — the
console is the recovery path and must stay usable.

## 5. The image must be loggable-into — DONE, but it nearly was not

Two faults, found only by actually trying to log in. Both are invisible from
the boot log, and both are the kind of thing a "the file is there" check
misses.

**`/etc/shadow` must exist and be readable.** The image was originally built
by copying a mounted rootfs as an unprivileged user, and `cp -a` cannot
preserve ownership without root — so mode-0640 files were **silently
skipped**. The result had a `root` entry in `/etc/passwd` and no shadow file
at all, and the box booted perfectly and refused every login.

**`/run` must be a tmpfs, and the whole tree must be root-owned.** The image
ships a `/run` tree owned by the uid that built it, and `sshd` refuses to
start when `/run/sshd` is not root-owned:

```
/run/sshd must be owned by root and not group or world-writable.
```

Worse, the init script ran `sshd 2>/dev/null`, discarding the only clue, and
then printed `network ready: <ip> (ssh)` — **a success message that was a
lie**. The box announced SSH and then refused every connection.

So:

- `rescue-init.sh` mounts `/run` as a tmpfs, `chown`s `/run/sshd`, and
  reports sshd's first error line if it still refuses to start
- the image build fixes ownership across the whole tree, and refuses to
  build from a tree that is not root-owned
- the build script verifies its output by extracting the filesystem back out
  and diffing it against the source, which is what catches a skipped file

## 6. Root filesystem sanity

Verified good on the test box and should stay that way:
- `e2fsck -fn` clean on both p1 and p2
- boot partition p1 **ext4**, labelled `BOOT`, holds `Image` + DTB
- root p2 ext4, labelled `ROOTFS`

`ext4load` is the correct U-Boot loader for p1. Do **not** format p1 as FAT32:
the box has no FAT tooling at all (`mkfs.vfat` absent, no `busybox`), and a FAT
filesystem whose geometry disagrees with the partition caused a silent,
undetectable kernel corruption — see notes.

## 7. Post-write verification (the omission that cost a day)

No install script has ever hashed what it wrote. That is why a corrupt kernel sat
on the box through an entire session of "eMMC boot doesn't work".

Every installer must, after writing:
```
umount <target>
mount -o ro <target> <mnt>
sha256sum <mnt>/Image
e2fsck -fn <target>
```
and compare against a known-good hash. **The unmount/remount is essential** — a
hash taken while the filesystem is still mounted can be a page-cache artefact
and will report a corrupt write as clean.

Known-good (this section is the **2026-10-19 record**; the current hashes
are in [`../kernel/SHA256SUMS`](../kernel/SHA256SUMS) — Image
`45a67743…`, DTB `d1e2267f…`, 78,952 bytes):

```
Image  5adbc4cc53cc3633cf44a07f0d61cc2937af41ed3c717846f253526b46c52dc9  (34551816 B)
DTB    176ddf27b9e392175dbbbd057449d023c7ddd8bda68210d54c71fccf585d2043  (78956 B)
```

> **SUPERSEDED 2026-10-23** — these are not the hashes to verify a current
> image against. The kernel and DTB were rebuilt for v0.6-desktop; the
> hashes above remain here as the record of what the installer test used.
> Use `kernel/SHA256SUMS`.

## 8. Installer bugs — status

From the 2026-10-19 audit. All of these are now fixed in
`scripts/install-to-emmc.sh`, which has since been run end-to-end on real
hardware:

1. ~~`install-to-emmc.sh` **dd's into a mounted filesystem**~~ — fixed. The
   rootfs is copied with the target **unmounted**, and the filesystem is grown
   with `resize2fs` afterwards.
2. ~~`install-to-emmc.sh` has literal `EOF` and `chmod` lines baked into the
   file~~ — fixed.
3. ~~Filesystem/script mismatch: formats FAT32 but the `aml_autoscript` uses
   `ext4load`~~ — fixed by making the two sides explicit. The **stick's** boot
   partition is FAT, because U-Boot's `fatload` reads only FAT. The **eMMC's**
   boot partition is ext4, because the box has no FAT tooling at all. The
   kernel is loaded from a different filesystem type than the one the OS runs
   from; that asymmetry is required, not a mistake.
4. ~~Both installers copy the rootfs from the modified live stick rather than
   a verified source~~ — the artefacts are hash-checked before anything is
   written, and the source is the published image.
5. ~~The USB stick's own `aml_autoscript` is broken~~ — fixed. It is rebuilt
   from `scripts/stick/aml_autoscript.src` and loads the kernel and DTB
   directly. The old one resolved the kernel name as `vmlinuz-` with an empty
   release suffix and looped forever.

### Bugs found since that audit

6. **`dd` with no `count=` leaves the rootfs at the source's size.** The
   destination partition is 14.9 GB but only the source partition's ~773 MiB
   are copied, so the filesystem stayed tiny and the rest of the eMMC was
   unallocated. Fixed with `resize2fs` after the copy, plus a report of the
   filesystem size against the partition size.

7. **The U-Boot environment lives inside p2**, 28 MiB in, so the installer's own
   `dd` destroyed it — including the `bootcmd` that makes the box bootable.
   The environment is now discovered read-only, backed up before any write, and
   restored afterwards, with the restore verified from the device.

8. **`fw_setenv` needs a bare value.** Passing `fw_printenv` output back into
   it stores `bootcmd=bootcmd=...`. The installer strips the name and verifies
   the write by reading back and comparing.

9. **The stock `/etc/fw_env.config` is wrong twice** — it names `/dev/mmcblk1`
   (which does not exist) and the wrong offset. `scripts/find-env.sh` discovers
   the real location, and the installer refuses to touch the environment if it
   cannot positively verify it.

10. **The bootcmd written must load from the path the kernel was read from.**
    It used to hardcode `d/` while reading from an auto-detected directory, so
    on a flat stick the USB branch would fail silently and the box would boot
    the eMMC as if the stick were absent.

11. **`rescue-init.sh` could never bring the network up.** It polled
    `carrier` before `ip link set eth0 up`, and reading `carrier` on a down
    interface returns `EINVAL` rather than `0`. This was a race, not a hard
    failure — the same code sometimes worked, which is why it went unnoticed.

12. **The clock had no fallback.** `chronyd -q` sets the time once and exits;
    a boot with no network stayed at 1970, which breaks `apt`. A last-known-good
    time is now persisted and restored when chrony cannot sync.


## 9. The published stick image

| | size | filesystem | contents |
|---|---|---|---|
| p1 | 64 MB | FAT32 (LBA), LBA 32768 | `Image`, DTB, `aml_autoscript`, vendor multi-boot scripts |
| p2 | 800 MB | ext4, LBA 163840 | the Debian rootfs — the live system |

Total 880 MB, so it fits on a 1 GB stick.

**Why so small, when the eMMC is 14.9 GB?** Because the stick is the *install
source*: the installer `dd`s p2 onto the eMMC, so p2's size directly sets the
install time (measured: 773 MB → 39 s, 7 GB → 109 s). The eMMC takes all the
space anyway — the installer partitions it to 100 % and then grows the
filesystem to fill. This is the same relationship an ISO has to the disk it
is installed onto: a fixed-size image that fits any medium, with the target
taking the rest.

If you write the image to a larger stick, `scripts/grow-stick.sh` extends p2
into the leftover space.

### The boot artefacts are at the boot-partition root

Not in a `d/` subdirectory. U-Boot's `fatload` reads only FAT, so the stick's
boot partition must be FAT; the eMMC's boot partition must be ext4, because
the box has no FAT tooling at all. The kernel is loaded from a **different
filesystem type** than the one the OS runs from — that asymmetry is required.

The consequence that matters: anything that loads from the stick must use the
same path the installer used when it read the kernel. A bootcmd that points at
`d/Image` on a stick where the kernel is at the root fails **silently** — the
`fatload` returns an error, the conditional falls through to the eMMC branch,
and the box boots as if the stick were not there.

### The stick's `aml_autoscript` must boot the stick

It is the first-boot entry vector for a box with no saved `bootcmd`: the
vendor bootloader scans the USB stick, finds `aml_autoscript`, and runs it.
It must therefore set `root=/dev/sda2` — the **stick**. Pointing it at the
eMMC would boot the very thing you are trying to replace.

The payload is executed by U-Boot's hush parser, so it must not contain
quotes in comments: an unbalanced quote drops the parser into its `>`
continuation prompt and the script never runs. The source is kept as
`scripts/stick/aml_autoscript.src` for documentation; the built uImage is
made from a comment-stripped copy.

### Building the image

`scripts/build-stick-image.sh <rootfs-tree> [output.img.gz]` builds the
published image from a prepared rootfs tree:

```sh
./scripts/build-stick-image.sh ./rootfs-tree dist/eon-s905x4-linux-stick.img.gz
```

It needs `mke2fs`, `mkfs.vfat`, `mtools`, `debugfs`, `sfdisk` and `gzip` —
and **no loop device**, because `mke2fs -d` populates the ext4 filesystem
from a directory at creation time and `mtools` writes FAT images directly.
That matters, because the loop module often cannot be loaded in containers
and VMs, and the build should not depend on it.

The script verifies its own output: it extracts the ext4 filesystem back
out with `debugfs` and `diff -r`s it against the source tree, and refuses
to finish if they differ. That check is not decoration — an unprivileged
copy silently skips mode-0640 files, and a rootfs missing `/etc/shadow`
produces an image that boots perfectly and cannot be logged into.
