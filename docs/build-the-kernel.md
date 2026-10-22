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
| Local patches | [`../patches/`](../patches/) — eight source patches (0001, 0003, 0005–0008, 0010) and one config delta (0002); see the table below. A ninth, `0009`, was dropped on 2026-10-23 — its justification did not survive testing |
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
     KBUILD_BUILD_TIMESTAMP="$STAMP" \
     KCFLAGS="-ffile-prefix-map=$PWD=/build/linux" \
     KAFLAGS="-ffile-prefix-map=$PWD=/build/linux" \
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

#### Two flags that make the build reproducible

`KBUILD_BUILD_TIMESTAMP` (or `SOURCE_DATE_EPOCH`, which the project's build
script turns into it) pins the build date that the kernel prints in
`uname -v`. Without it, `Image` differs on every build.

`-ffile-prefix-map` is the one that is easy to miss. The kernel embeds
`__FILE__` in a few places — `arch/arm64/kernel/entry.S` is one — so
without a map the `Image` carries the absolute path of the build
directory. That has two consequences, and both are bad for a release:

- **it is not reproducible across machines.** Two people building the same
  tree in different directories get different images, which is exactly
  what a reproducible build is supposed to rule out;
- **it publishes the packager's directory layout.** The first published
  `Image` contained `/home/dim20/amlogic/build/linux/arch/arm64/kernel/entry.S`.

The map rewrites that prefix — here to `/build/linux` — so the image is
build-directory independent. It is passed both as `KCFLAGS` and `KAFLAGS`
because assembly goes through `KAFLAGS` (`Makefile`: `KBUILD_AFLAGS +=
$(KAFLAGS)`), and `entry.S` is where the string comes from.

After building, check it:

```sh
grep -a "$PWD" out/arch/arm64/boot/Image && echo "leak - the map did not take"
```

The project's own build script (`host/build-kernel.sh`) sets both flags
and fails the build if the path is still in the image.

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
| `0010-fbdev-console-owns-the-mapping.patch` | a user closing `/dev/fb0` must not clear `screen_base`: the console holds its own reference and keeps drawing through it | proven, 2026-10-23 (P0-1) |

**There were nine source patches; there are eight.** A patch that stopped
the vendor's OSD driver freeing 8 MB of CMA a minute after boot (`0009`)
was removed on 2026-10-23. Its stated reason — that the free pulls the
memory out from under the display and the box dies every minute — did not
reproduce: a kernel *without* it ran for two hours past the free with the
console on the display, and `0005` had already stopped the OSD
framebuffers being registered, so nothing in the image scans that memory.
Its real reason for existing was never established, so by this project's
rule — a patch needs a true, tested justification — it was dropped rather
than kept on a story.

If the desktop work later shows the free matters (X allocating the region
the display scans), the patch can come back with that evidence attached.
Its text is in the git history.

For the record, and because the method matters more than the outcome: the
series was proved to reproduce the build tree with `scripts/check-patches.sh`
after every change. That check is what turned up that `0003` had been
setting `FBINFO_PRIMARY` after `register_framebuffer()`, which is too
late; it is repaired here.

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
45a677435e2af01c5c77dd60692f60ce9482eaa51725fd983717e552d873c0d0  Image
d1e2267f5e945acff73f7a8973af9fcbb2d777faf26771e2a7e75687537ffda8  sc2_s905x4_ah212_linux.dtb
```

These are the current hashes in [`../kernel/SHA256SUMS`](../kernel/SHA256SUMS),
which tracks **the kernel this repository ships** — the one v0.7 will use.
**They are not the hashes of any released image.** Each release note under
[`releases/`](releases/) records its own, and those are frozen: the
v0.6-desktop `Image` is `39b91fd0…`, the v0.5.x `Image` is `93420f6a…`.
The mismatch used to confuse people, and it is worth stating plainly: a
release note describes a release, `kernel/SHA256SUMS` describes the tree.

With `KBUILD_BUILD_TIMESTAMP` and `-ffile-prefix-map` set (above), and the
same toolchain and patch set, `Image` should reproduce **byte for byte**,
wherever the tree is checked out. The DTB is independent of all of it. If
your `Image` differs, check the two flags before anything else — a plain
build carries the build path and cannot match. What always matters is that
it is **non-PE** and boots:

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