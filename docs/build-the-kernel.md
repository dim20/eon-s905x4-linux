# Building the kernel

Last verified: **2026-10-23** against `kernel/VERSION`,
`kernel/SHA256SUMS` and `patches/`. No build was run during the
documentation pass, so the build log below is the 2026-10-21 one.

Required for two reasons: to rebuild the `Image` this project ships, and to
satisfy GPL-2.0 §3, which requires that anyone given the binary is also given
the Corresponding Source.

If you only want to *use* the box, download the release `Image` and verify it
against `kernel/SHA256SUMS`. You do not need to build anything.

---

## Provenance

| | |
|---|---|
| Upstream | https://github.com/CoreELEC/linux-amlogic |
| Branch | `amlogic-5.4.210` |
| Commit | `a3aaaa5b0` |
| Licence | GPL-2.0 |
| Config | `arch/arm64/configs/meson64_a64_P_defconfig` + `patches/0002-option-D.config.delta` |
| Local patches | [`../patches/`](../patches/) — nine files: eight source patches (0001, 0003, 0005–0009) and one config delta (0002); see the table below |
| Produced | `Image` (34,551,816 bytes) and `sc2_s905x4_ah212_linux.dtb` (78,952 bytes) |

Everything below is what was actually done. Where something was a workaround
rather than a clean fix, it says so.

---

## Why this kernel

Every mainstream arm64 kernel distribution we checked ships a **PE/ZBOOT
wrapped** kernel — Armbian/ophub, and Debian's own `linux-image-*-arm64`. That
wrapper breaks `booti` on this board's U-Boot, and `bootefi` is broken in the
same U-Boot too.

The vendor tree is the practical answer: it is a real Linux kernel for this
SoC, and its defconfig sets `# CONFIG_EFI is not set`, so the output is a plain
arm64 image that `booti` can load.

---

## Build

### 1. Toolchain

Bootlin **`aarch64--glibc--stable-2024.05-1`** (gcc 13.3.0, Buildroot 2021.11).

Chosen deliberately as an old stable gcc: the 5.4 tree is from 2022 and newer
compilers trip it. Note gcc 13.3 against a 5.4 tree is an unusual pairing and
was the main build risk; see patch 1.

No cross toolchain was available on the host and `sudo` required a password, so
a self-contained tarball was the no-friction route.

Host-side tools (kconfig, `fixdep`, etc.) build fine with a much newer host
compiler.

### 2. Configure

```sh
git clone --depth 1 -b amlogic-5.4.210 https://github.com/CoreELEC/linux-amlogic
cd linux-amlogic
git rev-parse HEAD     # confirm a3aaaa5b0

export CROSS_COMPILE=/path/to/bootlin/bin/aarch64-
make ARCH=arm64 CROSS_COMPILE=$CROSS_COMPILE O=out meson64_a64_P_defconfig
```

### 3. Config delta — [`0002-option-D.config.delta`](../patches/0002-option-D.config.delta)

Apply **every** `=y` line in the file, not a hand-copied list:

```sh
grep '^CONFIG_[A-Z0-9_]*=y' ../patches/0002-option-D.config.delta |
while IFS='=' read -r sym value; do
    ./scripts/config --file out/.config --enable "${sym#CONFIG_}"
done
```

| Symbol | Why |
|---|---|
| `AMLOGIC_MEDIA_VIDEOCAPTURE` | `video_hw.c` uses `vd_layer[].capture_use_cnt`, `.capture_frame_req` and `CAPTURE_STATE_*` unconditionally, but they are inside `#ifdef CONFIG_AMLOGIC_MEDIA_VIDEOCAPTURE` in `video_priv.h`. The defconfig does not enable it, so **the tree does not compile as shipped**. |
| `DRM_MESON_EMULATE_FBDEV` | the vendor DRM's framebuffer emulation is behind this option. Without it there is no `/dev/fb0` from the DRM driver — only the OSD overlays, which have no usable weights. |
| `FRAMEBUFFER_CONSOLE` | this kernel has `CONFIG_VT_CONSOLE=y` but no framebuffer console, so nothing scans the VT out to HDMI. |
| `FRAMEBUFFER_CONSOLE_DETECT_PRIMARY` | lets fbcon choose the real framebuffer rather than the first one it finds. |
| `FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER` | waits for the display pipeline before taking the console over, instead of taking it over at 0.7 s and dying. |

Verified to survive `syncconfig`.

> **Trap:** this tree does not let you simply switch a symbol off. Writing
> `# CONFIG_SYSTEM_TRUSTED_KEYRING is not set` into `out/.config` and running
> `syncconfig` silently turns it back on, and the build then dies in
> `scripts/extract-cert.c` for want of `openssl/engine.h`. The cause was never
> found. The fix used was to satisfy OpenSSL instead of fighting kconfig — see
> step 5. **Verify config changes with a `syncconfig` afterwards.**

### 4. Source patches — [`0001-option-D-local-build-fixes.patch`](../patches/0001-option-D-local-build-fixes.patch)

```sh
git apply ../patches/0001-option-D-local-build-fixes.patch
```

Two hunks:

**a) `Makefile`** — adds `-Wno-error`.

Amlogic's tree already suppresses a set of warnings gcc 13 raises
(`array-compare`, `address`, `dangling-pointer`, `enum-int-mismatch`), but not
`-Wunused-function`, which gcc 13 reports on static helpers this tree leaves
unreferenced (`khadas-mcu.c:mcu_i2c_read_regs`,
`vout2_serve.c:get_vout2_init_mode`). The `-Werror` here is unconditional apart
from `ifndef CONFIG_KASAN`, so there is no config lever — opt out wholesale
rather than chase warnings one at a time.

**Revert this hunk if you build with the compiler the tree was written for.**

**b) `arch/arm64/boot/dts/amlogic/Makefile`** — adds our two boards to `dtb-y`:

```
dtb-y += sc2_s905x4_ah212.dtb
dtb-y += sc2_s905x4_ah212_linux.dtb
```

The `.dts` sources are present in the tree (`amlogic-dt-id = "sc2_s905x4_ah212"`)
but CoreELEC's fork trimmed `dtb-y` down to the boards it ships, so ours was
never built.

### 5. OpenSSL headers

The host had no OpenSSL headers, so `extract-cert` could not build. Headers came
from Debian's `libssl-dev` package, extracted rather than installed:

```sh
dpkg-deb -x libssl-dev_3.5.7-1~deb13u3_amd64.deb build/sslprefix
ln -s /usr/lib64/libcrypto.so.3 build/sslprefix/lib/libcrypto.so   # host runtime
```

Then pass these **on the `make` command line**:

```sh
P=$PWD/build/sslprefix
make ARCH=arm64 CROSS_COMPILE=$CROSS_COMPILE O=out \
     CRYPTO_CFLAGS="-I$P/usr/include" \
     CRYPTO_LIBS="-L$P/lib -lcrypto" \
     Image dtbs
```

> They must be on the `make` line, not in the environment.
> `scripts/Makefile` assigns `HOSTCFLAGS_extract-cert.o` and
> `HOSTLDLIBS_extract-cert` per-object, so a global `HOSTCFLAGS` would be
> overridden for exactly the object that needs them.

### 6. Build

```sh
make ARCH=arm64 CROSS_COMPILE=$CROSS_COMPILE O=out \
     CRYPTO_CFLAGS="-I$P/usr/include" CRYPTO_LIBS="-L$P/lib -lcrypto" \
     Image dtbs
```

Outputs:

```
out/arch/arm64/boot/Image                              34,551,816 bytes
out/arch/arm64/boot/dts/amlogic/sc2_s905x4_ah212_linux.dtb   78,952 bytes
```

The DTB size is exact and reproducible. The earlier revision of this
document said 78,956; that was a different build of the same tree, and the
published DTB is 78,952 bytes.

### The rest of the patch series

`0001` and `0002` above are about making the tree build. The rest are about
the display, and each one is explained where it matters — in
[`framebuffer.md`](framebuffer.md) and in the patch itself:

| Patch | What it does | Status |
|---|---|---|
| `0003-console-bind-to-display.patch` | binds the framebuffer console to the display and gives it a size, so text reaches the television | proven on hardware |
| `0005-no-osd-framebuffers.patch` | stops the DRM and media drivers exposing the OSD overlay planes as framebuffers — they are not CPU-accessible, and they register first | proven |
| `0006-fbdev-pan-ioctl.patch` | implements the standard `FBIO_PAN_DISPLAY` (0x4619), which this tree's trimmed `fb.h` does not define | proven |
| `0007-fbdev-buffer-lifetime.patch` | unmaps on close without freeing, retires a replaced buffer, frees when the framebuffer goes away | proven |
| `0008-fbdev-smem-start.patch` | leaves `fix.smem_start` at zero instead of the physical address, which the X server treats as an offset into its own mapping | proven |
| `0009-osd-overlay-cma-is-the-display.patch` | stops the vendor driver freeing the overlay's CMA memory a minute after boot | **unproven**: the box survived the release in the last test, so the patch may be unnecessary. It stays in the tree until the `/dev/fb0` test decides it. |

Patch 0009's own comment states a theory (the overlay is the display, and
freeing its CMA kills the box) that the last measurement did not reproduce.
It is kept, labelled, so the decision can be made from evidence rather than
from the comment.

---

## Use the `_linux` DTB variant

The tree ships two device trees for this board and **they are not
interchangeable**:

| | `sc2_s905x4_ah212.dtb` | `sc2_s905x4_ah212_linux.dtb` |
|---|---|---|
| partitions | `partition_mbox_ab.dtsi` (Android A/B) | `partition_normal_linux.dtsi` |
| display | **no DRM include at all** | `mesonsc2_drm.dtsi`, 28 hdmi/drm nodes |
| reserved-memory | 100 MB | 128 MB |
| `di_cma` pool | present | commented out |

Booting the **Android** variant on Linux produced a `Synchronous Abort` with
**zero console output** — it jumps into a device tree with no display subsystem
and dies before `console_init`. Switching to `_linux` turned that into a clean
boot to login.

If you build this kernel, use `sc2_s905x4_ah212_linux.dtb`.

---

## Verify your build

```
c1d0d6d440eb4efa62872404ed8f90cc083ed89425e2a65e2fe0788c8bddc8fa  Image
d1e2267f5e945acff73f7a8973af9fcbb2d777faf26771e2a7e75687537ffda8  sc2_s905x4_ah212_linux.dtb
```

These are the published hashes in [`../kernel/SHA256SUMS`](../kernel/SHA256SUMS).
Byte-for-byte reproduction of `Image` is not guaranteed — the build embeds a
timestamp and the host toolchain differs — but the DTB should match exactly,
and the `Image` should differ only in build metadata. What matters is that it
is **non-PE** and boots:

```sh
xxd -l 64 Image | head -2     # 'ARMd' at 0x38, NO MZ header
grep -c "CONFIG_EFI" out/.config   # "# CONFIG_EFI is not set"
```

If `Image` starts with `MZ`, it is ZBOOT-wrapped and this U-Boot cannot `booti`
it.

---

## Memory sizing — a trap worth knowing

The generic mainline DTB for this SoC family declares **4 GB**
(`memory@0 reg = ... 0xffffffff`). On a 2 GB box the kernel is told memory exists
that does not, initialises allocators over it, and dies before the first
`printk` — no console output at all.

The vendor DTBs declare 2 GB correctly. If you write your own DTB, check this
first when you get total silence.