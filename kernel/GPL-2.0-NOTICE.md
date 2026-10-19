# Licensing of the files in this directory

`Image` and `sc2_s905x4_ah212_linux.dtb` are **not** covered by the MIT licence
at the repository root.

They are built from GPL-2.0 sources:

| | |
|---|---|
| Source | https://github.com/CoreELEC/linux-amlogic |
| Branch | `amlogic-5.4.210` |
| Commit | `a3aaaa5b0` |
| Licence | GNU General Public License version 2 |

They are redistributed under the **GNU General Public License version 2**.

GPL-2.0 §3 requires that the Corresponding Source accompany any binary
distribution. It does, via
[`../docs/build-the-kernel.md`](../docs/build-the-kernel.md), which gives:

- the exact upstream source, branch and commit
- the build configuration (`meson64_a64_P_defconfig`) and the config delta
- the local patches ([`../patches/`](../patches/))
- the complete build procedure
- the toolchain used (Bootlin `aarch64--glibc--stable-2024.05-1`, gcc 13.3.0)
- which build artefacts are outputs

The DTB is compiled from Amlogic's GPL-2.0 `.dts` sources in the same tree.
