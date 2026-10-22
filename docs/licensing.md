# Licensing

This project ships three different kinds of thing, with three different
licences. They are listed separately here because blending them is the
actual risk: a reader who assumes "MIT" for the whole repository would be
wrong about the largest part of it.

| What | Licence | Where |
|---|---|---|
| The scripts, documentation and notes in this repository | **MIT** | `LICENSE` |
| The kernel `Image` and the device tree `sc2_s905x4_ah212_linux.dtb` | **GPL-2.0** | `kernel/GPL-2.0-NOTICE.md` |
| The Debian rootfs inside the stick image | **GPL-2.0** (and the licences of the Debian packages it contains) | below |

## The rootfs is not MIT

The stick image's root filesystem is derived from
[devmfc/debian-on-amlogic](https://github.com/devmfc/debian-on-amlogic),
which is **GPL-2.0**. It also contains the ordinary Debian packages, which
carry their own licences — the GPL-2.0 ones among them impose the
corresponding-source obligations on the image as a whole.

Two obligations follow, and both are met by pointing at upstream rather
than by repackaging anything:

- **The corresponding source for the rootfs is upstream.** The image is
  built from devmfc's published Debian images and their build scripts, and
  the GPL-2.0 obligations are satisfied by distributing that source
  alongside. See the [devmfc repository](https://github.com/devmfc/debian-on-amlogic)
  for the build scripts and image sources.
- **The kernel's corresponding source is published here**, in
  [`docs/build-the-kernel.md`](build-the-kernel.md), naming the exact
  upstream tree, branch, commit, our config and our patches, and the
  toolchain used. See also `kernel/GPL-2.0-NOTICE.md` and `patches/`.

We are **not** relicensing anyone else's work. The MIT licence covers only
the scripts, docs and notes written for this project.

## Credits

This project stands on the work of others, and says so:

- **[devmfc/debian-on-amlogic](https://github.com/devmfc/debian-on-amlogic)**
  — the Debian/Ubuntu images for Amlogic boxes that this rootfs is built
  from, along with the boot scripts, box configurations and device trees
  that made the project possible. GPL-2.0. The `aml_autoscript`,
  `aml-multiboot-setup.sh`, `aml-part.sh` and `aml-install-to-emmc.sh`
  scripts in the rootfs are devmfc's.
- **[CoreELEC/linux-amlogic](https://github.com/CoreELEC/linux-amlogic)** —
  the `amlogic-5.4.210` branch the vendor kernel is built from. GPL-2.0.
- **Debian** — the base distribution in the rootfs, under the licences of
  its individual packages.

The devmfc images are the origin of the base system, and this project
would not exist without them. The changes made on top are recorded in
`notes/journal.md`.
