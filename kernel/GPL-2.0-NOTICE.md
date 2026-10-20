# Licensing of the files in this directory

`Image` and `sc2_s905x4_ah212_linux.dtb` are **not** covered by the MIT licence
at the repository root. They are built from GPL-2.0 sources:

| | |
|---|---|
| Source | https://github.com/CoreELEC/linux-amlogic |
| Branch | `amlogic-5.4.210` |
| Commit | `a3aaaa5b0` |

Our configuration and local patches are published in `patches/`, and the
exact build steps — including the toolchain — are in
[`docs/build-the-kernel.md`](../docs/build-the-kernel.md). That is what
satisfies the GPL-2.0 requirement to offer the corresponding source.

Note that `sc2_s905x4_ah212_linux.dtb` differs from the upstream device
tree by one property: the vendor's `fb` node ships with `status =
"disabled"`, and it is set to `"okay"` here so that the framebuffer driver
binds and the HDMI output can be enabled. The full diff is one line.

For the licensing of the rootfs inside the stick image, and for credits,
see [`docs/licensing.md`](../docs/licensing.md).
