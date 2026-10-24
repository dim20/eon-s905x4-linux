# The kernel package

Last verified: **2026-10-23** against `kernel/VERSION`,
`manifest/kernel-package.txt` and `scripts/build-kernel-package.sh`.
No package was built during the documentation pass.

The kernel for this box, as a Debian package, so that `apt` can
install it and switch between versions.

```
apt install ./linux-image-sc2_5.4.210-sc2_arm64.deb
```

---

## Why a package at all

The kernel is not a file in the root filesystem. It is on the **boot
partition**, because the vendor's U-Boot loads it from there before
the root filesystem is even mounted. `/boot` on the running system is
empty, and it stays empty.

That makes a kernel update something `apt` cannot do by itself. It is
not a file copy into `/boot`:

- the kernel has to be written to **another filesystem**, and getting
  that wrong leaves a box that does not boot;
- the file that the bootloader reads has to be **the one that is
  wanted**, not the one that was there;
- and if the new kernel does not boot, there has to be a way **back**.

The package does all three.

## What is in it

| | |
|---|---|
| The kernel | 34.5 MB, `Image` |
| The device tree | 79 KB, `sc2_s905x4_ah212_linux.dtb` |
| The hashes | `SHA256SUMS`, so what was installed can be checked |
| `activate` | the shared logic: write, archive, verify |
| `sc2-kernel-list` | what is installed, and what is active |
| `sc2-kernel-select` | choose which kernel boots |

**There are no modules.** The kernel is built with everything built in,
so the package has no `/lib/modules` tree, and it is small.

## The version label, and `uname -r`

Two strings appear in this project and they are **not the same thing**:

| | value | what it is |
|---|---|---|
| `kernel/VERSION` | `5.4.210-sc2` | the release label for the package — the version apt sees |
| `uname -r` | `5.4.210-ga3aaaa5b0e64-dirty` | what the kernel reports — the vendor tree's `git describe` output |

The package is versioned with the label, so the file is
`linux-image-sc2_5.4.210-sc2_arm64.deb`. The running kernel keeps the
vendor string, because changing it would mean rebuilding the `Image` to
change a string — and the published `Image` has been reproduced and
tested. The label is the **package's** identity, not the kernel's.

`sc2-kernel-list` shows both, so there is no need to guess which is which.
Do not hand-edit the `Image` to make the strings match.

## What it does not do

It does not install the kernel into the root filesystem's `/boot`. That
directory is empty on purpose: the kernel is not there, it is on the
partition the bootloader reads. A second copy in `/boot` would be a
second thing to keep in step with the first.

It does not rewrite the U-Boot environment. The boot command names two
**fixed** files on the boot partition — `Image` and
`sc2_s905x4_ah212_linux.dtb` — so switching kernels is a file copy.
The environment lives *inside* the root partition, and a careless write
to the root partition destroys it. This package never writes it.

## The archive, and why it is the important part

A kernel that does not boot cannot be undone from the running system,
because there is no running system.

So before the kernel on the boot partition is replaced, it is copied
into `/var/lib/sc2-kernel/archive/<its hash>/` on the root filesystem
of the installation. It is archived under **its own hash**, so putting
a newer kernel on and then going back to the older one does not
overwrite the older one with the newer one.

The archive holds whole kernels, so it is kept to the last five.

### Putting a kernel back

The box is unreachable, so it is reached the way
[`recovery.md`](recovery.md) describes — with the USB stick, or at the
U-Boot prompt over the serial console. From there:

```sh
sc2-kernel-select list          # what is there
sc2-kernel-select <hash>        # put one back
reboot
```

With the stick, the archive is on the eMMC's root filesystem, so the
command finds it even though the running system is the stick.

## The commands

| | |
|---|---|
| `sc2-kernel-list` | the installed kernels, the archived ones, and which is active |
| `sc2-kernel-select list` | the same thing |
| `sc2-kernel-select <version>` | make that kernel the one that boots |

A version is a directory under `/usr/lib/sc2-kernel`; a hash is a
directory in the archive. Either can be abbreviated to a prefix.

## Installing a kernel

The package installs itself and writes the kernel to the boot
partition, archiving whatever was there. Nothing else is required.

To be clear about what "installing" means here: the kernel on the boot
partition is replaced, and the one that was there is archived. The box
boots the new kernel on the next power cycle.

### Getting the package onto the box

The package is about 35 MB. On 2026-10-22 a transfer over the box's
100 Mbps link stalled at about 6.4 MB, so do not assume a single `scp`
succeeded: check the hash at the other end.

If the transfer is unreliable, copy the `.deb` onto the USB stick and
install it from there. It is a single self-contained file; nothing needs
to be fetched at install time.

## Building it

```sh
scripts/build-kernel-package.sh --kernel kernel/Image \
                                --dtb kernel/sc2_s905x4_ah212_linux.dtb \
                                --version 5.4.210-sc2
```

`SOURCE_DATE_EPOCH` must be set, or the package is not reproducible —
the same as for the kernel itself. The result is byte-identical
between two runs with the same epoch.

The manifest rule is in
[`manifest/kernel-package.txt`](../manifest/kernel-package.txt), and
[`scripts/check-image.sh`](../scripts/check-image.sh) checks the built
package against it.
