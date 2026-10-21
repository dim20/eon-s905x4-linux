# The kernel package

The kernel for this box, as a Debian package, so that `apt` can
install it and switch between versions.

```
apt install ./linux-image-eon_5.4.210-eon1_arm64.deb
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
| `eon-kernel-list` | what is installed, and what is active |
| `eon-kernel-select` | choose which kernel boots |

**There are no modules.** The kernel is built with everything built in,
so the package has no `/lib/modules` tree, and it is small.

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
into `/var/lib/eon-kernel/archive/<its hash>/` on the root filesystem
of the installation. It is archived under **its own hash**, so putting
a newer kernel on and then going back to the older one does not
overwrite the older one with the newer one.

The archive holds whole kernels, so it is kept to the last five.

### Putting a kernel back

The box is unreachable, so it is reached the way
[`recovery.md`](recovery.md) describes — with the USB stick, or at the
U-Boot prompt over the serial console. From there:

```sh
eon-kernel-select list          # what is there
eon-kernel-select <hash>        # put one back
reboot
```

With the stick, the archive is on the eMMC's root filesystem, so the
command finds it even though the running system is the stick.

## The commands

| | |
|---|---|
| `eon-kernel-list` | the installed kernels, the archived ones, and which is active |
| `eon-kernel-select list` | the same thing |
| `eon-kernel-select <version>` | make that kernel the one that boots |

A version is a directory under `/usr/lib/eon-kernel`; a hash is a
directory in the archive. Either can be abbreviated to a prefix.

## Installing a kernel

The package installs itself and writes the kernel to the boot
partition, archiving whatever was there. Nothing else is required.

To be clear about what "installing" means here: the kernel on the boot
partition is replaced, and the one that was there is archived. The box
boots the new kernel on the next power cycle.

## Building it

```sh
scripts/build-kernel-package.sh --kernel kernel/Image \
                                --dtb kernel/sc2_s905x4_ah212_linux.dtb \
                                --version 5.4.210-eon1
```

`SOURCE_DATE_EPOCH` must be set, or the package is not reproducible —
the same as for the kernel itself. The result is byte-identical
between two runs with the same epoch.

The manifest rule is in
[`manifest/kernel-package.txt`](../manifest/kernel-package.txt), and
[`scripts/check-image.sh`](../scripts/check-image.sh) checks the built
package against it.
