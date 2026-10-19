# Install Image Requirements

Changes that must be baked into the image shipped to each box. Each one is a
fault found on the test box on 2026-10-19 — none of them are theoretical.

## 1. Clock (BLOCKING)

Box boots with `Thu Jan 1 1970`. Causes:
- `hwclock` binary absent from the rootfs
- meson-vrtc RTC reads back invalid, so nothing sets the time

Consequences: PAM refuses logins (`account root has password changed in future`),
apt treats every repo `Release` as future-dated, TLS breaks, log timestamps are
meaningless.

Options — pick one:
- **NTP** in `rescue-init.sh` (needs DNS working, so do #2 first), or
- ship `hwclock` and have the boot path write the clock back, or
- accept 1970 and have the *installer* set the date over SSH at provision time

NTP is cleanest but has a chicken-and-egg with DNS. Doing both in `rescue-init.sh`
in the right order resolves it.

## 2. `/etc/resolv.conf` (BLOCKING)

The file **does not exist** on a fresh boot. `dhclient` obtains the lease but
never writes a resolver — `resolvconf` is not installed.

Result: no DNS. `apt-get update` hangs indefinitely with an empty
`/var/lib/apt/lists/`, which reads exactly like "no packages available".

Fix: ship `/etc/resolv.conf` with `nameserver 8.8.8.8` / `nameserver 1.1.1.1`.
Do not rely on DHCP to create it.

## 3. Force IPv4 for apt

DNS returns **AAAA only** for `deb.debian.org`, and the box has no IPv6 route,
so apt stalls trying to fetch over v6.

Ship `/etc/apt/apt.conf.d/99force-ipv4`:
```
Acquire::ForceIPv4 "true";
```
(note: the `-o Acquire::ForceIPv4=true` form is command-line only and is a
**syntax error** inside a config file.)

## 4. Networking in `rescue-init.sh` (BLOCKING for headless)

`rescue-init.sh` currently brings up **no networking**. `dhclient eth0` has to be
run by hand after every boot. An unattended box therefore gets no lease, no IP,
and no SSH.

Must add to `rescue-init.sh`, in this order:
1. `ip link set eth0 up`
2. wait for link (up to a few seconds)
3. `dhclient eth0`
4. write `/etc/resolv.conf`
5. set the clock
6. start `sshd` (`mkdir -p /run/sshd; ssh-keygen -A; /usr/sbin/sshd &`)

Do this **in the background** so it never blocks the serial console — the
console is the recovery path and must stay usable.

## 5. Root filesystem sanity

Verified good on the test box and should stay that way:
- `e2fsck -fn` clean on both p1 and p2
- boot partition p1 **ext4**, labelled `BOOT`, holds `Image` + DTB
- root p2 ext4, labelled `ROOTFS`

`ext4load` is the correct U-Boot loader for p1. Do **not** format p1 as FAT32:
the box has no FAT tooling at all (`mkfs.vfat` absent, no `busybox`), and a FAT
filesystem whose geometry disagrees with the partition caused a silent,
undetectable kernel corruption — see notes.

## 6. Post-write verification (the omission that cost a day)

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

Known-good:
```
Image  5adbc4cc53cc3633cf44a07f0d61cc2937af41ed3c717846f253526b46c52dc9  (34551816 B)
DTB    176ddf27b9e392175dbbbd057449d023c7ddd8bda68210d54c71fccf585d2043  (78956 B)
```

## 7. Installer bugs to fix

From the 2026-10-19 audit:

1. `fleet-install.sh` **dd's into a mounted filesystem** (mounts p2 at L54, then
   `dd`s over the block device at L90). Raw block write under a live ext4 mount.
2. `install-to-emmc.sh` has literal `EOF` and `chmod` lines baked into the file
   (L150–151) and dies under `set -eu`.
3. Filesystem/script mismatch: `install-to-emmc.sh` formats FAT32 but its
   `aml_autoscript` uses `ext4load`.
4. Both installers copy the rootfs from `/dev/sda2` — the **modified live
   stick** — rather than the sha256-verified pristine `dl/devmfc-trixie.img` p2.
5. The USB stick's own `aml_autoscript` is broken: the kernel name resolves as
   `vmlinuz-` with an empty release suffix, so nothing loads and `booti` fails
   **in an infinite loop** (60 runs in 30 s, 0 U-Boot prompts). The USB autoboot
   path has therefore never worked unattended — every earlier "USB boot works"
   was a manual `fatload`+`booti` at the prompt.