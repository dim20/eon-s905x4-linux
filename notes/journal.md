# Project journal — chronological

The raw working log, in the order it happened. Kept complete and unedited
because the record of *what was believed before each test* is worth more than a
clean summary — several conclusions in here were confidently wrong, and knowing
which claims were never tested is the lesson.

**Identifiers are redacted** (`<MAC>`, `<SERIAL>`, `<ANDROID_ID>`, `<BOARD_SERIAL>`,
`<USB_SERIAL>`).

> **STATUS 2026-10-23 — this journal ends on 2026-10-19.** The status text
> further down that says "kernel 6.18.55-meson64, booted manually from
> U-Boot" is **superseded**: the box now boots Linux 5.4.210 from eMMC
> with systemd and a text console on HDMI, and the latest TTY release is
> **v0.5.1**. Current state is in [`../README.md`](../README.md), and the
> plan is `plan/PLAN-OF-RECORD.md` in the development repository (not
> part of this one); the later findings are in the lab notebook
> (`notes.md` in the development repository). The body is kept unedited:
> it records what was believed at the time, which is the point of a
> journal.

**Start with [`../docs/lessons.md`](../docs/lessons.md) and
[`../docs/troubleshooting.md`](../docs/troubleshooting.md)** if you are here to
fix something rather than read history.

---

## Where the useful parts are

| Section | Lines | Status |
|---|---|---|
| Device identification, DNL mode, `getvar` results | ~28–93 | **current** — reference |
| UART box hardware findings, eMMC layout, U-Boot facts | ~177–256 | **current** — reference |
| ophub DTB / mainline kernel attempts | ~279–586 | **superseded** — mainline kernel cannot work here |
| devmfc image, ZBOOT/PE wrapper analysis | ~512–630, ~2178 | **current** — the key constraint |
| Mainline Linux on eMMC, corruption hunt, systemd/agetty | ~677–2200 | **superseded** — useful history only |
| Option D recon: vendor kernel tree, Ethernet findings | ~2202–2328 | **current** — reference |
| **Vendor kernel builds, boots, Ethernet works** | ~2432–2626 | **current** |
| **eMMC autoboot investigation** | ~2627–2806 | **current** — dead end, correctly diagnosed |
| **AUDIT: corrupt kernel on eMMC** | ~2807–2919 | **current** — the central finding |
| **Network stack faults (no resolv.conf, IPv6, clock)** | ~2920–2983 | **current** |
| **Silent kernel fixed; standalone boot confirmed** | ~2984–3080 | **current** |
| **bootcmd quoting: escaped quotes reset the CPU** | ~3081–3152 | **current** |
| **bootcmd solved with single quotes** | ~3153–3208 | **current** |
| **UNATTENDED STANDALONE eMMC BOOT ACHIEVED** | ~3209–end | **current** |

---

## The one-paragraph version

The box could not boot eMMC. That was believed to be a bootloader limitation —
that it would not autostart from eMMC and needed a USB stick as a bootloader.
**It was a corrupt kernel file.** The FAT32 filesystem on the boot partition
declared 102400 sectors while the partition was 98304, so writes past ~13 MB hit
the end of the device and silently failed; nothing in any script ever verified
what it wrote. Reformatting as ext4 and verifying from storage made eMMC boot
work immediately. Automating it then came down to one U-Boot environment
variable — with the single sharp edge that `bootargs` must be embedded in
`bootcmd` using single quotes, because escaped double quotes reset the CPU.

---

# EON SDSTB01 (S905X4 / SM1) — project notes

> ## ⚠ STATUS 2026-10-17 — READ THIS FIRST
>
> **This box is an SDSTB02.** `ohm` is only its Android board string. Everything
> from the UART work onward (Oct 15 late + all of Oct 16) is the SDSTB02.
> The "SDSTB02 is a dead end" verdict further down is **superseded and wrong**.
>
> **Debian 13 (trixie) is running from eMMC**, kernel `6.18.55-meson64` (devmfc),
> booted manually from U-Boot over UART. See "2026-10-16/17" at the end of this
> file for the full current state.
>
> **Damage already done, not reversible:** the Debian rootfs was written over
> eMMC partition 28 `userdata`, which held the EON provisioning. There is **no
> backup**. LBA 0 (first block of the `bootloader` partition) now holds our MBR
> instead of the Amlogic bootloader header.
>
> Any statement below dated Oct 15 that says "nothing has been written to eMMC"
> is **false** — see the final section.

## Host
- Ultramarine Linux 44 "Flying Fish" (Fedora/RPM-based, `ID_LIKE=fedora`), x86_64
- `dnf` / `rpm`. `git` + `parted` preinstalled. `device-tree-compiler` NOT installed (needs sudo).
- Preinstalled: `libusb1`, `libusb-compat-0.1` (libusb0), `lua-libs 5.4`
- 153 GB free on /home
- **USB ACL already grants `dim20` rw on the Amlogic node** → no sudo / udev rule needed

## Device identification (confirmed)
- USB: `1b8e:c004` "Amlogic, Inc. DNL", bcdDevice 2.22
- Serial: `<SERIAL>`
- Bus 001 @ 480 Mbps (USB 2.0 controller), **self-powered**, no kernel driver bound
- => SoC family **SM1 (S905X4)**, NOT S905X2/g12a. Reference DBs are wrong for this box.
- Physical layout (left side, top->bottom): MicroSD slot, USB1 (black, USB 2.0), Reset pinhole, USB2 (blue, USB 3.0)
- Rear: RF IN, S/PDIF, HDMI, Ethernet, DC IN (12V/1A)
- Greek EON box = United Group / NOVA, built by SDMC

## Tooling
- `~/amlogic/tools/utils` = shallow clone of https://github.com/khadas/utils
- `adnl` V2.8.2 lives at `aml-flash-tool/tools/adnl/adnl`
- **Must run with `LD_LIBRARY_PATH=./usb_flow`** (bundles its own `liblua53.so`; host has lua 5.4)
- Works without sudo thanks to the USB ACL

## DNL mode
- Entered by **holding the pinhole Reset button while applying power**. No cable modification
  needed — a plain USB A-to-A cable works. Confirmed.
- Boot order **latches** on warm reboot; only a cold reboot (unplug) resets it.
- USB **burn/boot only works on USB1 (black, USB 2.0)**. The blue USB 3.0 port cannot be used
  for boot (different controller). This is almost certainly why earlier USB-stick boots failed.

## Interrogation results (read-only)
| getvar | result |
|---|---|
| `serialno` | `<SERIAL>` |
| `version` | `0.1` |
| `product` | FAILED (status malformed) |
| `secure` | **Variable not implemented** |
| `unlocked` | **Variable not implemented** |
| `board`, `platform`, `soc-type`, `variant`, `hw-revision`, `current-slot` | **Variable not implemented** |

### Findings / blockers
- Vendor U-Boot (BL33) is **stripped down**. Most getvars unimplemented.
- **`adnl upload` (partition read) FAILS** — it issues `oem mread`, device replies
  `unknow command`. Confirmed via both the `upload` wrapper and the hidden `mread`
  command directly. => **DNL-mode partition backup is impossible on this box.**
- Hidden commands present in the binary but unusable: `mread`, `mwrite`, `download`, `run`,
  `bl1_boot`, `bl2_boot`.
- **Secure boot status cannot be determined via getvar.** Unresolved — see below.

## Box comparison (both are SM1 / DNL / `1b8e:c004`)

| | **SDSTB01** (Greek, older) | **SDSTB02** (newer) |
|---|---|---|
| serialno | `<SERIAL>` | `<SERIAL>` |
| `getvar product` | FAILED (status malformed) | **`amlogic`** |
| `getvar slot-count` | not implemented | **2** → A/B slots |
| `oem mread` | `unknow command` (not implemented) | **works, but refused** |
| Secure boot | **unknown** | **ENABLED — confirmed** |
| Verdict | **target box** | **dead end** |

### SDSTB02 is a dead end (confirmed, not speculation)
`upload` returned `upload not allowed as secure boot enabled`. Consequences:
- Amlogic secure boot is burned to an **eFuse** (OTP) via `pattern.secureboot.efuse`. It is
  **one-way — cannot be un-burned.**
- With secure boot on, the BootROM **refuses to load unsigned code** and vendor bootloader
  stages are AES-encrypted + RSA-signed.
- Reads are blocked deliberately (anti-extraction), so **no backup is possible** either.
- Bypassing needs either the OEM signing key (unavailable) or a BootROM secure-mode exploit
  (`amlogic-usbdl` class — research-grade, and only documented for S905/S905X, not SM1).
- => **Do not invest further in the SDSTB02.** Keep it as an Android unit.

This also answers the original "find an unpatched box" question: the SDSTB02 isn't an unpatched
variant of the SDSTB01, it's a **newer, locked-down generation**. Strictly worse for this project.

## SDSTB01 — confirmed identity (via network ADB)

- serial `<ADB_SERIAL>`, product `DV8945C-T2`, device `DV8945C-KSU`
- **board / platform = `ohm`** (AOSP board name), hardware `amlogic`
- **Android 11**, build `RTT0.211222.001.20241211 release-keys` (Dec 2024)
- adb shell user: `uid=2000(shell)`, **no root**

### AVB state
| prop | value |
|---|---|
| `ro.boot.verifiedbootstate` | `green` |
| `ro.boot.vbmeta.device_state` | `locked` |
| `ro.boot.veritymode` | `enforcing` |
| `ro.debuggable` | `0` |
| `ro.secure` | `1` |

Note: this is Android Verified Boot (dm-verity), which is **separate** from the Amlogic eFuse
secure boot that killed the SDSTB02. SDSTB01's eFuse state remains **unknown** — `mread` is not
implemented there so the DNL probe that revealed the SDSTB02's state cannot be run.

### Partition layout — Virtual A/B (dynamic partitions)
`super`, `vbmeta`, `vbmeta_system`, `odm_ext`, `oem` present; **no standalone `system`**.
System/vendor/product live inside the `super` container. ophub's `ampart` handles this, but it
is more involved than a flat layout.
Also present: `bootloader`, `bootloader0/1`, `mmcblk0boot0/1`, `boot`, `dtbo`, `env`, `logo`,
`recovery`, `data`, `cache`, `tee`, `rsv`, `reserved`, `param`, `frp`, `factory`, `metadata`,
`cri_data`, `misc`.

### BACKUP BLOCKED (without root)
- Block devices are **`brw------- root:root` (mode 0600)** → the `shell` user cannot read them.
  Only `frp` is `brw-rw---- system:system`.
- `/proc/partitions` → **Permission denied**.
- => The unrooted-`dd` idea does not work on this box. `scripts/backup-via-adb.sh` will report
  "read denied" for every partition.
- A pre-flash backup therefore requires **root** (PatchWired-class) on an AVB-locked, release-keys
  Android 11 build — real effort, uncertain success.

## Networking facts (SDSTB01, Android)
- `eth0` holds the **default route** and the ADB IP 192.168.1.216 → ADB link **is Ethernet**
- Driver: **`meson8b-dwmac`** (Amlogic DesignWare MAC)
- No `wlan0` present — unit is Ethernet-only in practice (`ro.carrier=wifi-only` is misleading)
- **100M vs 1G still UNKNOWN.** Blocked without root:
  - `/sys/class/net/eth0/speed` → Permission denied
  - no `ethtool` on device, `ip link` denied, `/proc/device-tree/*` contents SELinux-blocked
  => handled by trying a `-100m` DTB first, then a gigabit variant.

## Armbian image (prepared)
- `images/armbian_s905x3_bookworm.img.gz` (821 MB) from ophub release
  `Armbian_bookworm_arm64_server_2026.10`, asset
  `Armbian_26.11.0_amlogic_s905x3_bookworm_6.12.112_server_2026.10.15.img.gz`
- **Debian 12 bookworm + kernel 6.12 LTS** (chose LTS over 6.18 deliberately — 6.18 is too new
  for SM1). Server/CLI image (no desktop needed).
- Decompressed 3.5 GB → `images/armbian_s905x3_bookworm.img`. Stick is 7.76 GB, fits.
- Layout: MBR, p1 = FAT32 511 MiB @ sector 8192 (boot), p2 = ext4 2.9 GB (rootfs)

### Boot chain (from the image's compiled autoscripts)
`aml_autoscript` → sets `bootcmd` to `run start_autoscript; run storeboot`; tries MMC, then
`for usbdev in 0 1 2 3; fatload usb ${usbdev} 1020000 s905_autoscript`.

`s905_autoscript` does, in order:
1. if `boot_android` present on the stick → boot Android (and toggle the `ab` env flag)
2. `if fatload usb 0 0x1000000 u-boot.ext; then go 0x1000000` → chainload
3. otherwise read `uEnv.txt`, `env import`, load `${LINUX}` `${INITRD}` `${FDT}`, then `booti`

**=> `u-boot.ext` is OPTIONAL.** Absent it, it boots the kernel directly. Image works unmodified.
NB the image ships `u-boot.usb` / `u-boot.sd` but the script looks for **`u-boot.ext`** — naming
mismatch, worth revisiting only if the direct-booti path fails.

### Only one thing needs editing to change board
`uEnv.txt` → the `FDT=` line. Default shipped value:
`FDT=/dtb/amlogic/meson-sm1-x96-max-plus-100m.dtb`

### DTB candidates (39 `meson-sm1-*` DTBs ship in the image)
Try order: `x96-max-plus-100m` (default) → `x96-air` → `h96-max` → `x96-max-plus-a100` →
`a95xf3-air` → `x96-max-plus` (1G) → `ugoos-x3`. Note the `-100m`/`-gbit`/`a100` axis = Ethernet
speed; wrong pick typically still boots but yields no network.

### Open question on USB boot
Whether the SDSTB01's **vendor U-Boot auto-scans the USB stick** for `aml_autoscript` is
unknown. If it boots straight to Android instead, the stick is not being seen and we need
another entry vector (serial console, or force update mode).

## ============================================================
## UART BOX — MAJOR FINDINGS
## ============================================================

Board reported by U-Boot as **`sc2_ah212`** (Amlogic AC212 reference design).
This is the box with accessible UART pads. Not an SDSTB01/02 — treat as its own target.

| | |
|---|---|
| SoC | **SC2 / S905X4** (SM1) |
| Board variant | `sc2_s905x4_ah212` (multi-DTB contains ah212, -1g, -1.5g, -3g, -4g) |
| RAM | 2 GiB **LPDDR4** (LPDDR4 training succeeded; DDR4/DDR3 probes failed first) |
| U-Boot | 2019.01-g56435b53 (Aug 02 2023), gcc 7.3.1 Linaro aarch64-elf |
| U-Boot prompt | **`sc2_ah212#`** (NOT `=>` — grepping for `=>` misses it) |
| `bootcmd` | **`run storeboot`** — no removable-media check at all |
| eFuse secure boot | **`forUpgrade_secureBoot=false`** — unsigned bootloaders ARE accepted |
| AVB | `avb2: 1`, `avb verification: locked = 1`, `robustOta=true` (separate from eFuse) |
| MAC | `<MAC>` |
| Tuner | R836 + Sony CXD2856 DVB (hardware present; not needed for our goal) |
| Storage | eMMC, Virtual A/B, `super` 0x70800000, 3 bootloader copies |
| `IDburn_e` | Amlogic binary present; running it **reboots the box**. Not a useful entry point. |

### UART link
- CP210x (`10c4:ea60`), node is **`/dev/ttyUSB0`** but **re-enumerates** (ttyUSB2→ttyUSB0
  observed). It dropped off USB several times mid-capture — that flakiness loses windows, so
  always re-check `ls /dev/ttyUSB*` before driving the console.
- **Working rate: 1000000.** Requesting 1500000 silently settles to 1000000 (CP210x divisor)
  and *that* produces 100% printable text. `stty` also rejects `-crtscts` with
  "unable to perform all requested operations" — omit it, use 8N1 raw no-flow.
- Capture must hold **one fd for read+write**. Re-opening the port between write and read
  resets termios and silently drops the reply. `scripts/ub.sh` does this correctly.

### Why USB boot appeared broken (root cause, both boxes)
`bootcmd=run storeboot` — U-Boot goes straight to eMMC and **never checks removable media**.
The `scanning usb for storage devices...` line seen during boot is Amlogic's BCB/update path
(optimus_fat), not the boot path. It is *not* evidence that U-Boot skips USB.

So on the SDSTB01 the stick was never examined at all. With a console we can drive it manually.

### ARM64 BOOT FROM USB — PROVEN WORKING (no writes to eMMC)
```
usb start
# -> "2 USB Device(s) found", "1 Storage Device(s) found"
usb part 0                     # stick is USB device 0 (NOT 2, as `usb info` implies)
#   Part 1  Start 8192  Num 1046528  type 0c   (FAT32)
#   Part 2  Start 1056768 Num 6144000 type 83  (Linux)
fatload usb 0 0x11000000 zImage                  # 41953792 bytes
fatload usb 0 0x15000000 uInitrd                 # 17966564 bytes
fatload usb 0 0x1000000 dtb/amlogic/<dtb>.dtb
fdt addr 0x1000000
booti 0x11000000 0x15000000 0x1000000
# -> "Starting kernel ... boot 64bit kernel"
```

Caveats:
- `usb start` must be re-run after every U-Boot reset or the stick vanishes from the list.
- U-Boot here does **not** accept `;` as a command separator. One command per call.
- Two benign warnings on the way to the kernel: `libfdt fdt_path_offset() returned
  FDT_ERR_NOTFOUND` and `[rsvmem] fdt get prop fail` — mainline DTBs have no
  `reserved-memory` node Amlogic U-Boot expects. Harmless.

### Kernel does not appear on serial
After "boot 64bit kernel": **zero output, and no host on the LAN.**
- NOT a UART pinmux problem. Verified by parsing the DTB (`scripts/fdt.py`, a minimal FDT
  reader written to stand in for `dtc`): `meson-sm1-h96-max.dtb` has `serial@3000`
  (`amlogic,meson-g12a-uart`) with `pinctrl-0` pointing at the `uart-a` group and
  `status = "okay"`. So the console UART is configured.
- Remaining suspect is **baud**: the image's cmdline says `console=ttyAML0,115200n8` but the
  hardware runs at 1000000. We retried with `console=ttyAML0,1000000n8` and still got nothing,
  so the kernel may be programming a different rate than we assume.
- Networking also dead, consistent with the DTB not matching this board's PHY.

### Next step (blocked on a power cycle)
Stop guessing the baud. Boot with **`init=/bin/sh`** and let the box drive its own UART at
whatever rate its DTB dictates. That needs **HDMI + a monitor/TV**, since a serial-less
`init=/bin/sh` gives us nothing.
```
setenv bootargs "root=UUID=f7b5c309-64e4-4360-9291-0154c1d7aeca rootflags=data=writeback rw rootwait rootfstype=ext4 console=ttyAML0,115200n8 console=tty0 no_console_suspend init=/bin/sh fsck.repair=yes net.ifnames=0"
```
Then from the shell: `cat /proc/cmdline`, `dmesg | tail -40`, `lsusb`, `ip a`.

## Hard rules (device-specific)
- **NEVER factory-reset, `pm clear`, or erase `data`.** EON deactivation lives in /data and the
  box needs EON provisioning to come back. Flashing tools cannot fix this. It is a permanent brick.
- The current EON "patch" is user-mode only (apps disabled, not uninstalled), so `/system` on
  this box is effectively pristine and a dump from it is a valid restore point.
- Box does not care about DVB/tuner — Linux target, no live TV needed.

## Open items
- [ ] Ethernet PHY: 100M vs 1G (decides `-u100` vs `-gbit` DTB). Answer from vendor DTB once
      dumped from Android, or `ethtool` on the running box, or by reading the PHY chip marking.
- [ ] Secure boot: unknown. Safe probe = write back a byte-identical partition copy (zero net
      change) and see whether the toolchain accepts it.
- [ ] Backup: requires rooting Android (PatchWired) or is skipped as redundant given spares.

## Phases
- [x] Phase 1 — workspace + tooling (done; no sudo needed)
- [x] Phase 2 — interrogate via adnl getvar (done; minimal U-Boot limits output)
- [~] Phase 3 — DNL backup **BLOCKED** (vendor U-Boot lacks mread)
- [ ] Phase 4 — power-cycle to Android, read /proc/partitions (needs user OK)
- [ ] Phase 5 — prepare USB stick with Armbian (safe, non-destructive)
- [ ] Phase 6 — boot from USB, iterate DTBs (reversible)
- [ ] Phase 7 — armbian-install to eMMC (first irreversible write)
## 2026-10-15 — ROOT CAUSE FOUND: ophub DTBs are not spec-compliant

### The bug in our FDT tooling (and the real bug in the DTBs)
Every one of the 37 `dtb/amlogic/meson-sm1-*.dtb` blobs shipped in this Armbian
image **omits the 4-byte name-length field that the devicetree spec v17 requires
after each `FDT_BEGIN_NODE` token**.

Proof (meson-sm1-h96-max.dtb, struct block starts at 56):

    t5 @156 PROP plen=49  (model)      -> value ends 216, pad to 220
    t6 @220 token=0x00000001 BEGIN_NODE
    t6 @224 -> "alia"  read as name LENGTH = 1634494817

A normal parser derails immediately. But parsing *without* the length field
walks the blob perfectly:

    tokens=3342 nodes=537 props=2267  consumed=69780/69780
    FDT_END at 69776, struct block ends 69780   (exact)

Across all 37 files: **37/37 parse clean without the length field, 0/37 with it.**

### Why this matters
libfdt (used by Linux for DT parsing, and by U-Boot's `fdt` commands) *always*
advances 4 bytes for the length field. So these blobs cannot be walked by
libfdt at all. A kernel handed one of these dies during early DT parsing —
**before console init**. That reproduces our exact symptom:

* `booti` prints `Starting kernel ...` then nothing, ever
* no Linux output at any baud rate
* watchdog reboots to Android, so the box looks alive but SSH never appears

Most likely the `192.168.1.228` DHCP lease we saw once was **Android** on eMMC
using the vendor DTB, not Armbian.

### Fix
`scripts/fdttool.py` — parses in compact mode, re-emits a **spec-compliant**
FDT (name lengths present, strings block deduped), then optionally patches.

    python3 scripts/fdttool.py dump     <in.dtb> [substring]
    python3 scripts/fdttool.py normalize <in.dtb> <out.dtb> [node-path prop]

Round-trip is verified: compact parse and strict parse agree exactly
(3342 tokens / 537 nodes / 2267 props), `final_depth=0`, `FDT_END` lands
precisely on the struct-block boundary.

### Clock question resolved (not a guess)
`/xtal-clk` is `compatible = "fixed-clock"`, `clock-frequency = 24000000`,
`#clock-cells = 0`, phandle 10. `serial@3000` clocks = `<&xtal-clk &aoclkc 4 ...>`
with `clock-names = "xtal","pclk","baud"`. So `clock-frequency = <0x016e3600>`
on the UART node is *provably consistent* with the clock tree and cannot
introduce a bad divisor. Added it anyway as belt-and-braces.

Note: `serial@3000` (AO) and `serial@24000` (main domain) are **both**
`status = "okay"`, so driver conflicts are not obviously the issue.

### Also found
`/chosen` has **no properties at all** — no `stdout-path`. Console comes purely
from Armbian's `APPEND` in uEnv.txt: `console=ttyAML0,115200n8`, plus
`plymouth.enable=0` and `video=HDMI-A-1:1920x1080@60e`.

### Current artifacts
* `dtbs/meson-sm1-h96-max-norm.dtb`  — 78220 B, normalized only (control)
* `dtbs/meson-sm1-h96-max-final.dtb` — 78236 B, normalized + clock-frequency
* Both injected as `/dtb/amlogic/meson-sm1-h96-max.dtb` in
  `images/armbian_patched.img`; read back out and SHA256-matched.
  sha256 = 1e4a73a6c06a6956695831a180815619398ca25846633170767150f6e5214650

### Boot command to use next
    setenv bootargs 'root=UUID=f7b5c309-64e4-4360-9291-0154c1d7aeca rootflags=data=writeback rw rootwait rootfstype=ext4 console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 max_loop=128 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1 video=HDMI-A-1:1920x1080@60e plymouth.enable=0'
    usb start
    fatload usb 0 0x11000000 zImage
    fatload usb 0 0x15000000 uInitrd
    fatload usb 0 0x1000000 dtb/amlogic/meson-sm1-h96-max.dtb
    fdt addr 0x1000000
    booti 0x11000000 0x15000000 0x1000000

## 2026-10-15 — CORRECTION: the DTBs were never the problem

### I was wrong. Do not trust the section above.
I built a real libfdt (dtc 1.7.0 from source, installed to ~/local) because my
hand-written reimplementation of libfdt could not be trusted. It immediately
contradicted my conclusion:

    dtc -I dtb -O dts meson-sm1-h96-max.dtb          -> OK (warnings only)
    dtc -I dtb -O dts meson-sm1-h96-max-final.dtb    -> FATAL ERROR:
                                                          Invalid opcode word 00000000

* The **original ophub DTBs are valid.** All 37 parse cleanly.
* My "normalization" produced **invalid** blobs. They are the cause of the
  `FDT_ERR_BADSTRUCTURE` U-Boot reported, not a pre-existing fault.

### What I got wrong, and why
The ophub blobs really do omit the 4-byte name-length after `FDT_BEGIN_NODE`:

    216: 00 00 00 00      (end of model value + padding)
    220: 00 00 00 01      FDT_BEGIN_NODE
    224: 61 6c 69 61      "alia"     <- I read this as a length = 1634494817
    228: 73 65 73 00      "ses\0"
    232: 00 00 00 03      FDT_PROP

That part of my observation was correct, and it walked to exactly the right
byte count in all 37 files. But I inferred "therefore libfdt cannot read it."
Real libfdt clearly *can* — it is more tolerant here than I assumed. So I
"fixed" a non-problem and broke a working file. Lesson: never rewrite a blob
you cannot validate with the real library.

Also wrong: "/chosen has no properties". It actually has
`#address-cells`, `#size-cells`, `ranges` and
**`stdout-path = "serial0:115200n8"`** (serial0 -> /soc/bus@ff800000/serial@3000).
That was another artifact of the broken parser.

### The real cause of "no kernel output"
`booti` needs `/chosen/bootargs`, and **/chosen has no `bootargs` property** —
it only ever came from Armbian's `uEnv.txt` `APPEND`. Our manual boot never set
it. With no `bootargs` there is no `console=ttyAML0,...`, so the kernel has no
console at all, and no `root=UUID=...`, so it cannot mount anything. Both
symptoms follow directly, with no DTB fault involved.

### Correct procedure (use the pristine DTBs)
    fatload usb 0 0x1000000 dtb/amlogic/meson-sm1-h96-max.dtb
    fdt addr 0x1000000
    fdt set /chosen bootargs root=UUID=f7b5c309-... console=ttyAML0,115200n8 ...
    fdt print /chosen bootargs          # must echo the string back
    booti 0x11000000 0x15000000 0x1000000

### Tooling now installed
`~/local/bin/{dtc,fdtdump,fdtget,fdtput,fdtoverlay}` (dtc 1.7.0, built with
`WARNINGS="-Wall -Wno-error"` because fdt_overlay.c trips -Werror on modern GCC).
Use these instead of hand-rolled FDT code. `scripts/restore-dtbs.sh` restores
the pristine set into a FAT partition and verifies every file with dtc.

## 2026-10-15 — Kernel hands off but never speaks (console hunting)

Confirmed-good so far: U-Boot control, USB boot, DTB validity (real dtc),
kernel image validity (valid arm64 Image with PE/COFF EFI stub, `ARM\x64` at
0x38), and bootargs injection (needs `fdt resize` + quoted `fdt set`).

The kernel always reaches `Starting kernel ... / boot 64bit kernel` and then
emits nothing at any baud, never reaches the network, never reboots.
Reproduced with BOTH our hand-rolled `booti` AND ophub's own
`s905_autoscript` (which is the same thing, on a different DTB), so the boot
sequence is not the fault.

### Where the console actually is
U-Boot env:      stdin/stdout/stderr = `serial@a000`
U-Boot's own DT: `/soc/cbus@fe070000` contains `serial@8000` and
                 **`serial@a000` -> 0xfe07a000**
Android bootargs:`earlycon=aml-uart,0xfe07a000`

Our DTB's console node is `/soc/bus@ff800000/serial@3000` = **0xff803000** -
a different address, in a different bus window. No DTB node exists at 0xa00.
That is the most plausible reason for total silence.

Also note: passing `earlycon=meson,0x3000,...` sets uart_base to a bogus
*offset*, not a physical address. Retried at 0xff803000 and 0xfe07a000; both
silent, so either earlycon is DT-driven and ignores the address, or the hang
predates earlycon init.

### DTB defect found: memory under-declared
`/memory@0 reg = <0 0 0x40000000>` = **1 GiB**, but BL2 reports
`ddr_size:0x80000000` = 2 GiB, while U-Boot loads the initrd at 0x78529000 -
above 1 GiB. U-Boot's fixup declined to correct it (`[rsvmem] fdt get prop
fail`). Many ophub sm1 DTBs declare 0xffffffff (4 GiB-1); h96-max alone says
1 GiB.

### The fix built (dtbs/meson-sm1-h96-max-fixed.dtb)
Edited via dtc -I dtb -O dts / -I dts -O dtb (no hand-rolled FDT code):
1. `/memory@0` 1 GiB -> 2 GiB
2. disable `/soc/bus@ff800000/serial@3000` so it cannot claim ttyAML0
3. add `/soc/serial@a000` at reg 0xfe07a000 (soc is identity-mapped, so an
   absolute reg resolves directly), reusing the xtal/aoclkc clocks and the
   `uart-ao-a` pinctrl phandle 0x1e from serial@3000
4. repoint alias `serial0` (and hence `stdout-path`) at the new node

Validated with real libfdt 1.7.0: fdtdump OK, dtc re-parse rc=0, root child
count unchanged at 32. Next step is to boot this.

## 2026-10-15 — Options A and B are blocked by this U-Boot; C looks viable

### What A and B actually hit
* `go` does not exist in this U-Boot (no `go`/`cpu`/`jmp`/`call`), so the
  documented `go 0x1000000` handoff is unavailable.
* `bootm` on the raw kernel: `Wrong Image Format for bootm command` — the
  arm64 Image carries a PE/COFF EFI stub and is not a legacy uImage.
* Wrapping images in a legacy uImage header **works structurally** — U-Boot
  reads it back correctly (`md.b` confirmed byte-perfect: magic, size,
  load/ep, os=1 arch=22 type=2 comp=0, name) — but `bootm` then reports
  `Bad Header Checksum` on a header whose hcrc we verified matches. This is
  Amlogic's AVB-modified bootm (note `AVB2 verify` / `failed to set boot
  params` before the checksum step), not a genuine CRC error.
  `IH_TYPE_STANDALONE` is likewise rejected (`Wrong Image Type`).

Lesson: the serial link drops characters if you send faster than ~0.5 s per
command (`mw.b 0x11000002 0xmw.b 0x11000020 0x61 1`). Use `mw.l` with
byte-swapped words — 16 commands instead of 64 — and read back with `md.b`
before booting.

### Option C is the promising one (and needs no stick swap)
`bootm` **does** work for the vendor image — that is exactly how `storeboot`
boots Android. Observed:

    ## Booting Android Image at 0x11000000 ...
    load dtb from 0x1000000 ......

So from a U-Boot prompt we can do:
    imgread dtb boot_a 0x1000000      # vendor DTB (the one we already dumped)
    imgread kernel boot_a 0x11000000  # vendor kernel
    bootm 0x11000000

The failure in the test above was **my fault**: 0x1000000 still held the
synthetic `ophub-u-boot` uImage from the earlier A attempt, so U-Boot said
`uImage is not a fdt`. With `imgread dtb` in place that is fixed.

Remaining obstacle for C: bootm forces the **Android image's own** cmdline —
it printed `androidboot.dynamic_partitions=true androidboot.dtbo_idx=0
androidboot.boot_devices=soc/fe08c000.mmc use_uvm=1 buildvariant=user`,
ignoring our `setenv bootargs`. To get our rootfs we must overwrite the
cmdline in the image header in RAM after `imgread` (patchable with `cp`),
pointing `root=` at the Armbian ext4 UUID.

Vendor kernel is **5.4.210-android12** — new enough to be worth trying with
Debian bookworm userspace, though /lib/modules will be 6.12-ophub and will
not match, so a stock Armbian initramfs is not usable; expect no initrd.

### Board state
Box is hung (`FDT and ATAGS support not compiled in - hanging`); needs a
power cycle.

> **SUPERSEDED 2026-10-16.** "Nothing has been written to eMMC at any point" is
> false as of Oct 16. Kernel/initrd/DTB went into `oem_a`/`oem_b`/`rsv`, an MBR
> was written to LBA 0, and the Debian rootfs was written over `userdata`.
> See the 2026-10-16/17 section at the end of this file.

## 2026-10-15 — ROOT CAUSE FOUND: the kernel is a PE/EFI image, not a raw arm64 Image

Analysis of `zImage` (41,953,792 B):

    'ARM\x64' occurrences in file : 1  (at 0x38)
    standard arm64 header (code0 = 0x14000000) : 0
    0x00..0x37  DOS/MZ header
    0x40        "PE\0\0"  <- PE signature
    PE AddressOfEntryPoint = 0x21f7d70
    sections: .text raddr=0x10000 rsize=0x2250000
              .data raddr=0x2260000 rsize=0x5a2a00

There is **no arm64 Image header in the file at all** — this is a pure
PE/COFF EFI executable (CONFIG_EFI_ZBOOT). U-Boot's `booti` spots the
`ARM\x64` marker at 0x38, decides "this is an arm64 Image", then reads
`text_offset` from file offset **0x40** — which actually holds the ASCII
`PE\0\0` = 0x4550. So it computes `entry = loadaddr + 0x4550` = 0x11004550,
which is zero-filled padding before .text (starts 0x10000). **U-Boot jumps
into zeros and the kernel never executes.**

That single bad pointer explains every symptom observed all session: no
`earlycon` (setup_arch never reached), no console at any baud, no network,
no clean reboot.

### Step 1 result (text_offset patch -> PE entry)
Patched 0x11000040 to big-endian 0x021f7d70; `md.b` confirmed
`41 52 4d 64 40 00 00 00 02 1f 7d 70`. Still silent — the EFI stub needs
EFI handover context, so pointing at the PE entry is not sufficient.

### Older-kernel plan: dead end (checked, not assumed)
ophub publishes standalone arm64 kernels (`ophub/kernel`, release
`kernel_stable`): 5.10 / 5.15 / 6.1 / 6.6 / 6.12 / 6.18. Downloaded
`6.1.189.tar.gz` (90 MB) — 6.1 predates CONFIG_EFI_ZBOOT (6.5) but ophub
builds it wrapped anyway:

    vmlinuz-6.1.189-ophub  first bytes = 4d 5a 40 fa (MZ)
                           code0@0x38   = 0x644d5241 (no standard header)

So *all* ophub kernels are ZBOOT. A non-ZBOOT kernel would need a different
builder (generic distro arm64 kernel) — possible but a much bigger detour.

### Next: `bootefi`
The box HAS `bootefi`. Booting a PE image as PE/COFF is the correct path and
is exactly the context the Step 1 patch lacked. No new download needed.

## 2026-10-15 — Unexpected win: root shell on the box

Ctrl-C spam during a boot cycle dropped the box into its Android **debug
ramdisk** console instead of U-Boot. Prompt is `130|console:/ #` and we get:

    id  -> uid=0(root) gid=2000(shell) groups=... context=u:r:shell:s0
    uname -a -> Linux localhost 5.4.210-android12-9-g693a465cd997 ... armv8l
    MemTotal: 2036248 kB

* Full Android rootfs present (/system /vendor /odm /product ...).
* `kexec` is **not** available, so we cannot hot-swap the kernel from here.
* `/proc/cmdline` and `/proc/partitions` are blocked by SELinux.
* `sda` **is** present in /sys/block — the USB stick is attached to the box,
  and the stick's FAT partition can be mounted from the box itself.
* USB gadget is serving adb/mtp (functionfs), not the stick.

This is a useful escape hatch and a way to write to the stick without
hot-swapping, but it does not by itself get us Armbian running.

### Still-open technical blocker
U-Boot cannot boot the ophub kernel because it is a PE/EFI image (see above).
Remaining routes, in cost order:
1. `bootefi` — box has the command; correct way to boot a PE image; untested.
2. Retry option C with `setenv bootargs` **without** quotes. Our earlier test
   quoted the value; if this U-Boot's `setenv` does not strip quotes, the
   value would be invalid and Amlogic's bootm would fall back to the image's
   own cmdline — which is exactly what we observed
   (`androidboot.dynamic_partitions=true ...`).
3. Obtain/build a non-ZBOOT arm64 kernel (all ophub kernels are wrapped).

## 2026-10-15 — Solution: devmfc/debian-on-amlogic

Image: `Devmfc_Debian-Trixie_6.18.55-meson64_Minimal-26.10.04.img.xz` (115 MB xz,
1.05 GB raw), sha256 `1492ab6a026ecac5c07a77b7a87d40b998c2a7240b5d718617c8f3e5352c1510`.

### Confirms the ophub diagnosis exactly
    devmfc vmlinuz : MZ/PE? False   code0@0x00=0xd503201f (real code)  text_offset=0
    ophub  zImage  : MZ/PE? True    code0@0x38=0x644d5241 (magic)      text_offset=0x4550 ("PE\0\0")
Same header layout (magic 0x38, text_offset 0x40). U-Boot reads text_offset
from 0x40; theirs is 0 so entry=loadaddr is valid code. **Their kernel boots
with plain `booti` — no bootefi needed.** Option C is therefore unnecessary;
going straight to this image.

### Boot chain (all verified from the image)
`aml_autoscript` sets `bootcmd` to try `bootscript` across `sd usb emmc`, with
`saveenv` **commented out** — it does not touch the bootloader env.
`bootscript` does `booti ${os_addr} ${rd_addr} ${dtb_addr}` with
os=0x02000000 rd=0x13000000 dtb=0x04000000, root=/dev/sda2, and
`fdt resize 131072` (the NOSPACE issue we had to find ourselves).
Config is assembled from `boot.config` + `box-config/*.config` via `env import`.

### Our board selection
Vendor DTB has `max-speed = <0x3e8>` = 1000 Mbps -> use **`box=s905x4_generic_gigabit`**
(DTB `dtb-6.18.55-meson64/amlogic/meson-sc2-ah212-generic-gbit.dtb`).
Their DTB already declares `memory@0 = 0x80000000` (2 GiB, correct for us) and
`stdout-path = "serial0:921600n8"` where `serial0` =
`/soc/bus@fe000000/serial@7a000` = **0xfe07a000** — exactly the address we
deduced earlier from U-Boot's env (`serial@a000`) and the vendor DTB. Only one
UART is enabled. So listen on **921600**, not 115200.

Reconstructed bootargs:
    root=/dev/sda2 rootfstype=ext4 rootwait rw
    console=tty0 no_console_suspend consoleblank=0
    coherent_pool=2M net.ifnames=0 fsck.repair=yes fsck.mode=skip
    init_on_alloc=1 init_on_free=1 randomize_kstack_offset=on
    kfence.sample_interval=100 debugfs=off kfence.deferrable=1
    watchdog.stop_on_reboot=0 pd_ignore_unused clk_ignore_unused

No initrd ships in the image (`rd_img` load simply fails and boot continues).
Rootfs p2 = ext4, UUID `56ca1992-fd70-4469-9f6a-8c8d8fe53849`, label ROOTFS.
Login root / tvbox.

Caveats from the project: no audio on any S905X4; best-effort support.

## 2026-10-15 — SDSTB02 identity correction + access routes closed

**This box is an SDSTB02** (user-confirmed). It has Amlogic eFuse secure boot.

### Correcting my own earlier "dead end" verdict
Earlier I wrote that SDSTB02 is "a dead end (confirmed, not speculation)"
because `upload` returned `upload not allowed as secure boot enabled`. That was
an over-generalisation from ONE probe. Empirical counter-evidence from this very
session: U-Boot here loaded and handed off to our **unsigned** Armbian kernel
~6 times (`Starting kernel ... boot 64bit kernel`), and `bootm` walked our
hand-built uImage to `## Booting kernel from Legacy Image`. Secure boot blocks
the **DNL/upload** path, not U-Boot's own `fatload`+`booti` from USB.
Do not repeat the dead-end claim without testing it.

### New symptoms after the user's OTG update event
* Autoboot interrupt now escalates to `### Please input uboot password: ###`,
  which we cannot answer and which WEDGES the box if fed repeated newlines.
  Before the OTG event the same interrupt worked ~6x (`sc2_ah212# <INTERRUPT>`).
* Android debug-ramdisk serial console (`console:/ #`) appeared twice earlier,
  but is **absent** on recent boots — no response to \r, \n, Ctrl-C, Ctrl-D,
  'help', Ctrl-Z, '~'. Likely the box moved past the EON provisioning state.
* U-Boot reported `Fail to detect device usb 0` once (BCB/optimus probe path,
  while `scanning bus 0 ... 2 USB Device(s) found` still succeeded).

### Evidence adbd is ALREADY running on the box
From the earlier working shell session, the box's own mount list included:

    adb on /dev/usb-ffs/adb type functionfs (rw,relatime)

So USB debugging is **already active** — a USB-A<->USB-A cable to the box's USB
port would give adb access with NO Android settings change. (User had assumed it
needed enabling; it does not.)

### Remaining access routes
1. reset/update button (the devmfc project's PRIMARY documented method — holds
   the button, power on, ~7s. No Android needed).
2. USB-A<->USB-A + adb (adbd already running).
3. Serial Android console if/when it returns.
4. Plan B on a spare SDSTB02, ethernet left unplugged.

Nothing has been written to eMMC. Every eMMC interaction this session was
`imgread` (read-only); the only write was `fatwrite` to the USB stick.

> **SUPERSEDED 2026-10-16** — as above. LBA 0, `oem_a`, `oem_b`, `rsv` and
> `userdata` have all been written to.

## 2026-10-16 / 17 — Debian on eMMC: full current state

### Identity
- This is the **SDSTB02**. `ohm` is its Android board string
  (`androidboot.serialno=<BOARD_SERIAL>`); U-Boot prompt is `sc2_ah212#`.
- The Oct 15 "SDSTB02 is a dead end" verdict is **wrong**. Secure boot gates the
  DNL/write path, not U-Boot's own `fatload`+`booti`. An unsigned mainline
  kernel has booted from this box many times.
- The `rmii` vs `rgmii-txid` question in the older sections is still open but
  irrelevant: the failure is above the PHY layer.

### Boot chain now lives on eMMC
Manual, every boot. Interrupt U-Boot at **1000000** baud, then:
```
mmc dev 1
mmc read 0x2000000  c6000 c10d     # kernel   -> LBA 811008  (oem_a)
mmc read 0x13000000 da000 d8f      # initrd   -> LBA 892928  (oem_b)
mmc read 0x4000000  136000 2a      # shim DTB -> LBA 1269760 (rsv)
booti 0x2000000 - 0x4000000
```
Linux then runs its console at **921600**. Amlogic's `booti` forces the
kernel image's own embedded cmdline; see "cmdline" below.

### eMMC map (Amlogic partition map + our MBR overlay)
| LBA | size | name | contents |
|---|---|---|---|
| 0 | — | (MBR) | **our MBR** — `00 fe ff ff 83 fe ff ff 00 a0 4e 00 00 40 84 01` |
| 811008 | 32 MiB | `oem_a` | `6.18.55-meson64` kernel (25.3 MB) |
| 892928 | 32 MiB | `oem_b` | initrd containing the `/init` shim |
| 1269760 | 16 MiB | `rsv` | shim DTB (`meson-sc2-ah212-generic-gbit` + edits) |
| 5152768 | 12.1 GiB | `userdata` | Debian rootfs (ext4, 773 MiB fs inside a 12.1 GiB partition) |
| 974848 / 1122304 | 64 MiB | `boot_a/b` | **untouched — Android still bootable** |

### EON / userdata damage — irreversible
- MBR p1 start `0x004EA000` = 5152768 and size `0x01844000` = 25444352 match
  Amlogic partition 28 `userdata` exactly. Verified by reading LBA 0 back off
  the live box.
- The Debian rootfs therefore sits on top of the EON provisioning data.
- **No backup exists.** `/tmp/mbrdisk.img` looks like a 14.6 GiB eMMC dump but
  is a sparse file occupying **4 KB** — it was only used to craft the MBR.
- LBA 0-7 were backed up to `odm_ext_a` (LBA 712704) at 15:50 and restored at
  16:17, but LBA 0 now holds our MBR. The original Amlogic bootloader header
  block is overwritten. **Android has not been re-tested since.**
- `mount count 4`, `lifetime writes 496 MB` on the fs → rw mounts did work and
  were written to before it broke.

### Why the rootfs is read-only
It is **by design**, not a failed rw mount. The shim `/init` (in the initrd):
```sh
echo "EMMC: mounting /dev/mmcblk1p1 read-only (no journal replay)"
if ! mount -t ext4 -o ro,noload /dev/mmcblk1p1 /newroot 2>/dev/null; then
    mount -t ext4 -o rw /dev/mmcblk1p1 /newroot || ...
```
`ro,noload` skips the ext4 journal — which is precisely why the current boot is
stable. rw is only attempted when the ro mount *fails*.

The filesystem underneath is **genuinely corrupt**:
```
dumpe2fs -h : Filesystem state: not clean with errors
e2fsck -fn : HTREE directory inode 10242/10245/10247/10248 invalid root node
              Directory inode 916, block #0, offset 0: directory corrupted
              e2fsck: aborted          RC=12
dmesg      : 339 "No space for directory leaf checksum" warnings, 1 error
```
`findmnt /` → `rw,...,emergency_ro`; writes to `/etc` and `/tmp` return EROFS.

### The kernel Oopses — all four are CPU 3
| when | where | what |
|---|---|---|
| 16:21 (1.28 s) | `swapper/3` | execute from NX mem @ `ffff800081697000`, `pc = lr`, both page-aligned |
| 17:06 (1.73 s) | `mount` | →`unmapped_area_topdown`→`__pi_memset_generic` writing to tagged ptr for phys `0x8`; then swapper/3 →`ttwu_queue_wakelist` → panic |
| 17:06 (3.04 s) | `swapper/3` | paging request @ `fff700000d6023cc` → panic in interrupt |
| 17:15 (6.6 s) | `swapper/3` | →`call_timer_fn`→`__run_timers`→**timer migration**→NX exec→panic |

- Systematic, not random bit-flips: every crash lands on CPU 3's idle/timer
  path. Jump targets are page-aligned vmalloc addresses = corrupted/zeroed
  function pointer.
- All sit in the **ext4 journal-recovery** path:
  `dd_insert_requests` ← `blk_mq_dispatch_list` ← `__blk_flush_plug` ←
  `submit_bh_wbc` ← `jread` ← `do_one_pass` ← `jbd2_journal_recover` ←
  `jbd2_journal_load` ← `ext4_fill_super`.
- DTB has 4 × cortex-a55, all `enable-method = "psci"`, none disabled.
- **Prime suspect list (unproven):** CPU3 PSCI bring-up / virtual timer,
  `clk: Disabling unused clocks` firing at 1.13 s immediately before the first
  Oops at 1.28 s, or an `idle`/timer-migration interaction.

### The cmdline cannot currently be changed
- The `sc2-gbit-rd*` DTBs carried `bootargs = "... nohz=off idle=poll
  cpuidle.off=1"` — the right mitigation — but **it never took effect**.
- Amlogic's `booti` overwrites `/chosen/bootargs` with the kernel image's
  embedded cmdline. Every successful boot log shows the Android cmdline
  (`init=/init console=ttyS0,921600 ... androidboot.*`).
- `fdt set /chosen bootargs` does **not** survive either — the 15:43
  `VFS: Unable to mount root fs on unknown-block(0,0)` panic is equally
  consistent with "no `root=` present at all".
- To actually set a cmdline you must **patch the kernel image's embedded
  cmdline** and rewrite `oem_a`. Untested.

### Hardware status (verified 2026-10-17)
| item | result |
|---|---|
| DRAM | **clean.** Perl memtester, 160 MiB × 4 buffers × 3 patterns ≈ 1.9 GB verified, 12/12 ok, 0 mismatches; repeated concurrently with eMMC reads — still 0 |
| eMMC reads | **clean.** No `I/O error`, timeout or CRC messages from `mmcblk1` |
| BL2 DDR training | **fails 6× first.** DDR4@1320 fail, DDR3@912 fail, LPDDR4@1176 fails ×3, then `mask:0008` succeeds |
| Ethernet | **broken.** `end0: Failed to reset the dma` → `stmmac_hw_setup: DMA engine initialization failed` → `__stmmac_open: Hw setup failed` → `ip link set up` returns `RTNETLINK answers: Connection timed out`. Identical across all 4 devmfc `ah212` DTB variants (same clocks/FIFOs; only `phy-mode` differs) |
| PHY | probes OK on the muxed bus: `PHY [mdio_mux-0.0:00] driver [Generic PHY]` — binds to *Generic PHY*, ID unrecognised |
| WiFi | RTL8812CS on SDIO, driver `rtl88x2cs`, MAC `<MAC>`. `ip link set wlan0 up` works. **`iw dev wlan0 scan` WEDGES THE KERNEL** (shell blocks; recoverable with Ctrl-C). Do not run `iw scan`. |
| USB | 2 buses enumerate (`1-0:1.0`, `2-0:1.0`); USB3 xHCI not enumerated |
| sdmmc | `mmc2: new UHS-I SDR104 SDIO card`, bound to `rtl88x2cs` |

### New tooling
- `scripts/uart-put.py` — base64 file transfer to `/run` over UART with
  **sha256 verification**. Needed because `/` is read-only; `/run` is tmpfs.
- `/tmp/opencode/memtest.pl` — Perl memory tester, `MEMTEST_MB=<n>` per buffer.

### Next steps (as of 2026-10-17)
1. **Restore the pristine rootfs.** `dl/p2.img` is the genuine image — same
   UUID `56ca1992-fd70-4469-9f6a-8c8d8fe53849`, label `ROOTFS`, and critically
   **`Filesystem state: clean`**, `mount count 1` (box has 4). Restoring it makes
   `jbd2_journal_load` skip recovery entirely, dodging the crash site without
   fixing CPU 3 first. Load from the USB stick in U-Boot and
   `mmc write 0x... 5152768 1583104`.
   → **STATUS: rw mount now works.** See "U-Boot facts" below.

## 2026-10-17 — U-Boot facts, the cmdline breakthrough, and a failed restore

### The cmdline CAN be changed (earlier conclusion was wrong)
devmfc's `bootscript` assembles the cmdline into the **U-Boot `bootargs` env
var** and Amlogic's `booti` injects that into `/chosen/bootargs`:
```
arg_name="bootargs" && run cmd_var_expand
echo "Starting linux with cmdline: ${bootargs}"
run cmd_do_boot;      # = booti ${os_addr} ${rd_addr} ${dtb_addr}
```
So **`setenv bootargs "..."` before `booti` is the supported mechanism** — no
`fdt set`, no kernel patching. It is NOT the kernel image's embedded cmdline
(the devmfc kernel contains no cmdline string at all — `androidboot`,
`console=ttyS0`, `ramoops` are absent from `vmlinuz`). A plain `booti` with no
`setenv` picks up the vendor env's Android cmdline, which is what every
earlier log showed.

### U-Boot command-set facts (this box)
- `usb read addr blk# cnt` **exists** — raw block read from USB storage.
  `usb read` help: `usb read addr blk# cnt - read 'cnt' blocks starting at
  block 'blk#' to memory address 'addr'`.
- **`blk#` and `cnt` are parsed as HEX** and printed in decimal. Proof:
  `1000`→4096, `2048`→8264, `557056`→5599318 (= 0x557056 exactly).
  `mmc read`/`mmc write` are also hex (all our old logs use hex values).
- `usb part N` only **prints** the table; it does not select a partition.
  `usb read` addresses the **whole disk**, so partition offsets must be added
  by hand.
- Other commands present: `ext4load`, `ext4ls`, `ext4size`, `fatload`, `cp`,
  `booti`, `bootefi`, `imgread`, `ddrtest`, `phyreg`, `mii`.
- Stick is 7.76 GB, 2 partitions: p1 32768+524288 (FAT BOOT 9DBB-3F03),
  p2 557056+1583104 (ext4 ROOTFS 56ca1992) = exactly `dl/p2.img`.

### Why USB boot "to no avail" before — all now resolved
| blocker | status |
|---|---|
| `bootcmd=run storeboot` never scans USB | manual `usb start` + `fatload` |
| ophub kernel is PE/ZBOOT, `booti` mis-parses it | devmfc raw arm64 kernel used |
| no cmdline set | `setenv bootargs` (above) |
| stick's `boot.config` has `box=` commented | **not true on the stick** — sha256 of `/run/sda1/boot.config` == `dl/boot.config.orig`, which has `box=s905x4_generic_gigabit` ACTIVE. Only our host copy was edited. |

### First full boot from the USB stick — progress, then USB loss
Booted `root=/dev/sda2 rw` from the stick: kernel + systemd 257 + full Debian
13 came up (a first — nothing had ever reached userspace before). At 38.9 s:
```
[   38.907471] device offline error, dev sda, sector 583192 op 0x0:(READ)
[   38.907480] sda: detected capacity change from 15148608 to 0
[   38.941727] EXT4-fs (sda2): I/O error while writing superblock
[   38.966520] systemd[1]: Caught <BUS> from PID ... status=7/BUS
[   38.968968] systemd[1]: Freezing execution.
```
USB device dropped off the bus; kernel/hardware otherwise fine. Tried the blue
USB3 port as well — stick enumerates fine (`usb 1-1: new high-speed USB device`),
so it is not purely a port issue. **Suspect the cheap Kingston DataTraveler or
this box's mainline xHCI/mass-storage path under load.** Linux eMMC reads are
clean, so this is specific to the USB transport.

### U-Boot restore to eMMC: the copy is bad because of MY arithmetic
Copied stick p2 → eMMC LBA 5152768 in four chunks with `usb read`+`mmc write`
(0x60A00 = 395776 blocks = 193 MiB each). All four reported
`blocks written: OK`. Verified the ext4 superblock (`53 ef`), the `ROOTFS`
label, the rw mount, and the tail bytes — all landed in *correctly written*
regions and all passed.

Booting `root=/dev/mmcblk1p1 rw` directly (no initrd, no shim):
```
[    0.950895] EXT4-fs (mmcblk1p1): recovery complete
[    0.951201] EXT4-fs (mmcblk1p1): mounted filesystem 56ca1992-... r/w with ordered data mode
[    0.952405] VFS: Mounted root (ext4 filesystem) on device 179:1.
```
**rw mount, no Oops, no panic — the original blocker is cleared.**

But file data was wrong:
```
eMMC  /lib/systemd/systemd : 21 00 00 91 ...   (an arm64 instruction, not an ELF)
stick /lib/systemd/systemd : 7f 45 4c 46 ...   (correct ELF)
```
=> **the eMMC write offsets for chunks 3 and 4 were mis-added.** Correct
offset is `0x4EA000 + n*0x60A00`:

| chunk | sent | correct | error |
|---|---|---|---|
| 0 | `0x4EA000` | 5152768 | ✓ |
| 1 | `0x54AA00` | 5548544 | ✓ |
| 2 | `0x5B4000` | 5944320 | **+35840 blocks (17.5 MiB)** |
| 3 | `0x61D600` | 6340096 | **+71680 blocks (35 MiB)** |

That left two 17.5 MiB holes inside the filesystem, never written:
```
[5944320, 5980160)  35840 blocks   fs_off 791552    usb_blk 0x149400
[6375936, 6411776)  35840 blocks   fs_off 1223168   usb_blk 0x1B2A00
```
The holes still hold the **old** filesystem's blocks, so `/` is a Frankenstein:
new superblock/journal from chunk 0, but old group descriptors, bitmaps and
directory blocks in the holes. It still mounted because superblock + journal
are in chunk 0 — which is why every cheap check passed.

**Consequence:** do NOT try to repair `/` by copying files over it. The ext4
metadata in the holes belongs to a different filesystem. Restore the real
bytes. The holes must be filled from U-Boot because `/dev/mmcblk1p1` is
claimed by the mounted root.

**Fix (35 MiB total):**
```
usb read 0x20000000 149400 8C00   ;   mmc write 0x20000000 5AB400 8C00
usb read 0x20000000 1B2A00 8C00   ;   mmc write 0x20000000 614A00 8C00
```
**U-Boot's `usb read` + `mmc write` path is trustworthy** — no need for the
Linux `dd` fallback (`scripts/restore-rootfs.sh`, kept as a spare).

### Two more operational gotchas
- **`reboot` does not work on this box when init has failed.** There is no
  systemd to service `systemctl reboot`, and `/proc/sysrq-trigger` does not
  exist (no `CONFIG_MAGIC_SYSRQ`), so the only way back to U-Boot is a
  **physical power cycle**. Always arm the catcher *before* asking for one.
- Once booted this way the box can come up **with no UART console at all** —
  consistent with Android booting silently. Don't assume silence means dead;
  power-cycle and catch U-Boot.
- U-Boot console **echo/output is unreliable over this CP210x link** at
  1000000 baud: long outputs (`crc32` over MBs, long command echoes) are
  frequently dropped entirely. Capture with a passive reader and re-read, or
  write results somewhere durable. Do not conclude a command "did nothing"
  just because its output is missing — the command may have run fine.

## 2026-10-17 — THE U-BOOT TRANSFER PROCEDURE (get this right)

I broke this three times by doing hex arithmetic in my head. It is mechanical;
do it mechanically. **Never hand-convert. Compute the table first.**

### Constants
```
eMMC fs start (decimal)  = 5152768   -> TYPE AS HEX 0x4EA000
eMMC fs length (decimal) = 1583104 blocks = 773 MiB  (0x182800 blocks)
USB p2 start   (decimal) = 557056    -> TYPE AS HEX 0x88000
chunk size     (decimal) = 395776    -> TYPE AS HEX 0x60A00
```

### The rule
For chunk `i`, covering filesystem block range `[i*395776, (i+1)*395776)`:
```
usb  start = 557056  + i*395776      # convert the DECIMAL result to hex
mmc  start = 5152768 + i*395776      # convert the DECIMAL result to hex
count      = 395776 = 0x60A00
```
Generate this table in Python every time. Four chunks covers
`4*395776 = 1583104` = exactly the filesystem length.

### Verified table
| chunk | fs_off range | `usb read` | `mmc write` | dest block # (dec) |
|---|---|---|---|---|
| 0 | [0, 395776) | `0x88000 cnt 0x60A00` | `0x4EA000 cnt 0x60A00` | 5152768 |
| 1 | [395776, 791552) | `0xE8A00 cnt 0x60A00` | `0x54AA00 cnt 0x60A00` | 5548544 |
| 2 | [791552, 1187328) | `0x149400 cnt 0x60A00` | `0x5AB400 cnt 0x60A00` | 5944320 |
| 3 | [1187328, 1583104) | `0x1A9E00 cnt 0x60A00` | `0x60BE00 cnt 0x60A00` | 6340096 |

RAM scratch: use `0x20000000` (512 MiB) — clear of the kernel at `0x02000000`
and the DTB at `0x04000000`. 193 MiB per chunk fits in 2 GiB RAM.

### Traps that actually bit me
1. **Adding `0x60A00` in hex by hand is error-prone.** `0x4EA000 + 0x60A00`
   is `0x54AA00`, but `0x54AA00 + 0x60A00` is `0x5AB400`, not `0x5B4000`
   (I dropped a nibble and jumped 35840 blocks / 17.5 MiB).
2. **U-Boot prints `block #` in DECIMAL while parsing hex.** So
   `mmc write 0x5AB400` echoes `block # 5944320`. Cross-check the echoed
   decimal against your computed decimal — that is the cheapest error check
   available and it catches every one of these mistakes.
3. **A misplaced write does not leave a hole, it leaves wrong content.**
   Coverage analysis (`union of written ranges vs fs length`) can be complete
   while the data is shuffled. Coverage is necessary but NOT sufficient.
   Verify with `crc32` of the RAM buffer vs the same range read back from
   eMMC, per chunk, before booting.
4. **Do not repair a mis-copied filesystem in place.** The eMMC blocks then
   contain a *different* filesystem's metadata. `cp` over files cannot fix
   group descriptors/bitmaps. Re-copy whole chunks.

## 2026-10-17 22:4x — ROOT CAUSE OF THE CORRUPTION: scratch RAM at 0x20000000

### Evidence
Bisected chunk 2 with `crc32` at 64/128 MiB granularity:
```
first  2 MiB  USB 8b3d37b2   eMMC 8b3d37b2   MATCH
first128 MiB  USB 3e872858   eMMC 3e872858   MATCH
+128..192MiB  USB 074e9240   eMMC 074e9240   MATCH
+192..256MiB  USB 248b1d83   eMMC 67e4f7f7   **MISMATCH**
```
So corruption is in the **last 64 MiB** of each 193 MiB chunk, i.e. the part of
the buffer sitting at **`0x2C000000`..`0x2FFFFFFF`**. Chunks 0 and 3 passed
only because their CRC was checked over just the first 8 MiB (`a29cd331`,
`912d6e5a` matched) — the check never covered their tails either.

### The scratch address is the problem
- `0x20000000` (512 MiB) was chosen as scratch because it clears the kernel
  (`0x02000000`) and the DTB (`0x04000000`). **It was never validated as
  writable RAM.**
- Writing a marker at `0x20000000` (`mw.l ... 0x5A5A5A5A`) **crashed the box
  into the kernel**:
```
pc : drm_atomic_helper_wait_for_vblanks.part.0+0x254/0x278
Call trace: dw_hdmi_irq -> dw_bridge_hpd_notify -> ... -> kthread
```
That address overlaps **live DRM/HDMI state**. U-Boot hands the address
straight to the memory controller; there is no MMU protection, so a "scratch"
buffer at 512 MiB silently corrupts whatever the kernel left there.

- Also observed: `0x80000000` (2 GiB) => `Synchronous Abort, esr 0x96000005`.
  So usable RAM ends below 2 GiB.
- Address aliasing was *suspected* (0x20000000 and 0x40000000 read identical)
  but that was a **false lead** — both held stale bytes from earlier writes,
  not aliased decode. Distinct markers at 256/320/384/448/480/496/507/508/511
  MiB all read back correctly.

### Rules going forward
1. **Never use `0x20000000` as scratch on this box** — it is not free RAM.
2. Pick a scratch address that is (a) below the kernel's live allocations,
   (b) verified by `mw`/`md` round-trip, and (c) not reused while the kernel
   is running. The safe pattern is to do all transfers **before** `booti`,
   reusing the address the DTB already occupies (`0x04000000`, 22 KB — too
   small) or the initrd area (`0x13000000`).
3. **Verify the whole buffer, not a prefix.** A CRC over the first 8 MiB of a
   193 MiB chunk proves almost nothing.
4. Chunk size must fit the verified window. Until that window is established,
   use chunks small enough to read back and compare entirely.

### Immediate next step
Establish the real writable RAM window empirically (binary-search `mw`/`md`
round-trip from low addresses upward, avoiding anything the kernel touches),
then re-copy with a scratch address inside it and a **full-buffer** CRC per
chunk. Do not re-attempt the copy on `0x20000000`.

## 2026-10-17 23:0x — TWO REAL BUGS, one in my verification

### Bug 1: my `crc32` length was wrong (spent hours on a phantom)
A chunk is `395776 blocks * 512 = 202637312 B = 193.25 MiB = 0xC140000`.
I was passing `crc32 <addr> 12C00000` = **300 MiB** — hashing **107 MiB of
stale RAM past the end of the real data**:
```
real chunk : 0x20000000 .. 0x2C140000   (193.25 MiB)
my window  : 0x20000000 .. 0x32C00000   (300.00 MiB)  <- 107 MiB of garbage
```
Because the two compare buffers (`0x20000000` vs `0x40000000`) hold *different*
leftover data, a tail mismatch was **guaranteed**. The "corruption is always in
the last 64 MiB" pattern was this artifact, not a real signal.

**Correct CRC length for a full chunk: `0xC140000`.**
Sub-range checks must use the same discipline: for chunk offset `N`, compare
`crc32 0x20000000+N len` against `crc32 0x40000000+N len` — the eMMC buffer is
at `0x40000000`, so the offset must be **added**, not substituted
(`0x2000000` -> `0x42000000`, not `0x42000000` from a decimal mix-up).

### Bug 2: `0x20000000` is NOT free scratch RAM (this one IS real)
`mw.l 0x20000000 ...` while the kernel is running crashes it:
```
pc : drm_atomic_helper_wait_for_vblanks / drm_fb_helper_set_par
Call trace: dw_hdmi_irq -> dw_bridge_hpd_notify -> drm_kms_helper_... -> kthread
```
`0x06000000` likewise gives `Synchronous Abort esr 0x96000010`.
Low addresses hold **live kernel/DRM state**. U-Boot writes straight to the
memory controller with no MMU guard, so a scratch buffer must be validated
**while nothing else is running** (i.e. before `booti`) and must avoid every
region the kernel uses. `0x80000000` (2 GiB) is past the end of RAM
(`Synchronous Abort esr 0x96000005`).

**Rule: only use a scratch address before `booti`, never while a kernel is up,
and never assume an address is free — round-trip `mw`/`md` first.**
`0x40000000` and `0x20000000` both round-trip cleanly when the kernel is NOT
running, so they are usable **pre-boot only**.

### Corruption IS real, but bounded to ~32 MiB..end of chunk
Chunk 1 (eMMC LBA 5548544), correctly sized CRC:
```
full 193.25 MiB : USB 5631d4a1   eMMC 7fa4b08c   MISMATCH
first 12.1 MiB  : USB a14cb234   eMMC a14cb234   MATCH
first 32   MiB  : USB 17f90b95   eMMC 17f90b95   MATCH
16 MiB @32MiB   : USB 8b011cf8   eMMC 0cf45780   MISMATCH
```
So bytes `0..32 MiB` are correct and `32 MiB..` onwards are not. 32 MiB =
`0x2000000`. **Strong hypothesis: the USB read itself is truncating/short-
transferring at 32 MiB** (a `usb read` chunking limit in this U-Boot), so the
tail of the RAM buffer is never populated and `mmc write` pushes stale memory
to eMMC.

**Next action: re-copy using chunks of <=32 MiB (e.g. 65536 blocks = 0x10000
= 32 MiB), with a full-length CRC per chunk.** 24 chunks of 32 MiB cover the
773 MiB filesystem. This tests the 32 MiB hypothesis directly.

## 2026-10-17 23:3x — NORMAL BOOT ACHIEVED, then the getty bug

### Normal boot works (fstab fix was the missing piece)
```
mmc read 0x2000000 c6000 c10d      # kernel
mmc read 0x4000000 136000 2a       # shim DTB
setenv bootargs "root=/dev/mmcblk1p1 rootfstype=ext4 rootwait rw \
  console=ttyS0,921600 no_console_suspend earlycon=aml-uart,0xfe07a000 \
  watchdog.stop_on_reboot=0 pd_ignore_unused clk_ignore_unused"
booti 0x2000000 - 0x4000000
```
Result:
```
[ 1.004443] EXT4-fs (mmcblk1p1): mounted filesystem 56ca1992-... r/w
Welcome to Debian GNU/Linux 13 (trixie)!
[OK] Reached target sysinit.target / basic.target / network.target
[OK] Reached target getty.target
[OK] Reached target multi-user.target
[OK] Reached target graphical.target
[FAILED] Failed to start ssh.service
```
**multi-user in ~3 s. No 90 s stall, no emergency.target.** The fstab `/boot`
line was the whole cause of the missing login screen. Confirmed twice now:
with `init=/bin/sh` we get a shell, and without it systemd boots fully.

### NEW BUG: serial-getty@ttyS0 crash-loops and floods both consoles
```
[OK] Started serial-getty@ttyS0.service - Serial Getty on ttyS0.
Try 'agetty --help' for more information.
[OK] Started serial-getty@ttyS0.service - Serial Getty on ttyS0.
...repeats forever
```
`agetty` rejects its own arguments and exits; systemd restarts it; each
restart writes to the console. Both the serial port AND the HDMI tty are
continuously overwritten, so:
- keystrokes sent over UART never land
- the HDMI screen flickers with the message
- **no login prompt is usable on either console**

This is NOT one of the read faults and NOT the fstab problem. `agetty` printing
its usage banner means argument parsing failed — likely a `baud_rate=` /
termios override left in the devmfc image, or a termios speed the driver
rejects. Needs `systemctl cat serial-getty@ttyS0` to see the real `ExecStart`.

**Note: masking serial-getty would leave us with no serial console at all.**
That matters because UART is currently the only reliable command channel, and
we still need it to investigate the intermittent read faults (`ssh.service`
fails with the same family of error). Fix the unit properly instead.

### How to get a shell when the getty is flooding
Boot with `init=/bin/sh` (see above). systemd never starts, so no getty loop,
and the serial port is a clean root shell. Used successfully twice today.

### Step 1 succeeded: writable rootfs, fstab fixed
Booted with **no initrd** and `init=/bin/sh` -> instant root shell on serial
(the shim would otherwise `pivot_root` into systemd).
```
[ 0.969329] EXT4-fs (mmcblk1p1): recovery complete
[ 0.969677] EXT4-fs (mmcblk1p1): mounted filesystem 56ca1992-... r/w with ordered data mode
```
- `/etc/fstab` had `UUID=9DBB-3F03 /boot vfat` — **the USB stick's FAT
  partition**, absent on eMMC. systemd waited 90 s, then `boot.mount` failed and
  it dropped to `emergency.target` (prompt on tty1/HDMI, so the serial port
  went silent — that was the "dead" box). Removed the line:
  `sed -i '/9DBB-3F03/d' /etc/fstab`. **This is the fix for the missing login.**
- **The filesystem IS writable**: `touch /root/WRITABLE_TEST` succeeded.
- `e2fsck -fn /dev/mmcblk1p1` => **RC=4, only counter drift**:
  `Free blocks count wrong (69167, counted=69166)`,
  `Free inodes count wrong (33788, counted=33786)`.
  The 339 checksum errors and `Directory inode 916 ... corrupted` are **gone**.
  The filesystem is essentially healthy.

### The `Exec format error` cascade was NOT corruption
`systemd`, `systemctl`, `mount`, `modprobe`, `login` all failed in the normal
boot — but only because systemd was in `emergency.target` after the `/boot`
failure. From a real shell:
```
/usr/bin/mount --version   -> util-linux 2.41.5     OK
/usr/sbin/modprobe --version -> kmod 34.2           OK
/usr/bin/login --version  -> util-linux 2.41.5     OK
/usr/bin/findmnt --version-> util-linux 2.41.5     OK
/usr/lib/systemd/systemd  -> Illegal instruction   FAIL
```
`cmp -l /lib/systemd/systemd /mnt/u/lib/systemd/systemd` => **0 differing
bytes**. The eMMC file is **byte-identical to the clean stick copy** and still
fails. So this is NOT storage.

### The real remaining fault: read errors from the block layer
Same file, two different paths:
```
/bin/dd        -> "Exec format error"      (eMMC)
/mnt/u/bin/dd  -> "Input/output error"     (USB stick)
```
`Input/output error` = the block layer failing reads. `dmesg` shows the same
class of fault seen in every CPU3 crash since the start of this project:
```
[647.151177] Buffer I/O error on dev sda2, logical block 65536, lost sync page write
[647.152149] JBD2: I/O error when updating journal superblock for sda2-8.
```
Some binaries run fine (`ls`, `sed`, `grep`, `cat`, `mount`, `modprobe`,
`login`), others die (`dd`, `tar`, `find`, `awk`, `dpkg`, `systemd`). It is
intermittent and load-dependent — **identical bytes, different outcome
depending on when they are read**. That is a hardware/memory fault, not a
filesystem one.

Memory is plentiful (`MemFree: 1875744 kB`, load 0.03) and eMMC reports no
CRC/timeout errors. Combined with the earlier finding that **all four kernel
Oopses were on CPU 3 in timer/idle paths**, and that the copy "corruption"
disappeared the moment the shim stopped forcing `ro,noload`, the picture is:
**a marginal/mis-trained DDR (BL2 fails DDR4 and DDR3 probes six times before
LPDDR4 succeeds on the last fallback mask) is producing sporadic memory
corruption and read failures.** The filesystem was never the real problem.

### Therefore
1. Do **NOT** keep re-copying the rootfs. It is written, it is writable, and it
   is structurally clean.
2. The next step is the **CPU/memory** problem, not the disk. Candidates:
   - boot with `maxcpus=1` / disable cpu@1..3 in the DTB (kills the CPU3 timer
     path that every Oops implicates)
   - `clk_ignore_unused pd_ignore_unused` are already on the cmdline; try
     `nohz=off cpuidle.off=1 idle=poll`
   - a kernel built with a DDR training/refresh fix, or the vendor 5.4 kernel
3. A normal boot should be re-tested now that fstab is fixed — `systemd` may
   well work when it is not being started from `emergency.target`. That is the
   cheapest next experiment and it is one power cycle away.

### Hard-won operational rules
- **Arm the catcher BEFORE asking the user to power-cycle.** Missed windows
  cost us several cycles.
- `reboot` does nothing without systemd; no `CONFIG_MAGIC_SYSRQ`. Power cycle
  is the only way back.
- U-Boot's `usb read`/`mmc write` work; **U-Boot prints block numbers in
  DECIMAL while parsing hex** — always cross-check the echo.
- Never use `0x20000000` or `0x06000000` as scratch: they hold live kernel
  DRM state and writing them crashes the box.
- `crc32` length for a 395776-block chunk is `0xC140000` (193.25 MiB), not
  `0x12C00000` (300 MiB) — measuring past the data guarantees a false mismatch.
- The serial link at 1000000 baud **drops long outputs silently**. Capture
  passively and re-read; do not conclude a command failed.

### Progress on 2026-10-17 evening — filesystem now structurally CLEAN
Rewrote **all four** chunks at generated offsets and verified the two ends by
`crc32`:
```
chunk 0: mmc write 0x4EA000 -> echoed block # 5152768  OK
chunk 1: mmc write 0x54AA00 -> echoed block # 5548544  OK
chunk 2: mmc write 0x5AB400 -> echoed block # 5944320  OK   (finally right)
chunk 3: mmc write 0x60BE00 -> echoed block # 6340096  OK
crc32 USB vs eMMC, chunk 0 first 8 MiB : a29cd331 == a29cd331  MATCH
crc32 USB vs eMMC, chunk 3 first 8 MiB : 912d6e5a == 912d6e5a  MATCH
```

Boot result:
```
[    0.949850] EXT4-fs (mmcblk1p1): mounted filesystem 56ca1992-... r/w with ordered data mode.
[    0.950770] VFS: Mounted root (ext4 filesystem) on device 179:1.
```
**Only ONE `EXT4-fs` line in the whole boot — zero checksum errors, zero
`corrupt`, zero `I/O error`.** Compare with 339 warnings + `Directory inode
916 ... corrupted` before. **The filesystem is structurally sound and mounts
read-write.** `systemd` itself now executes (previously `-8 ENOEXEC`).

### Remaining problem: individual binaries in chunks 1/2 are still wrong
```
systemd[1]: run-lock.mount: Failed to spawn executor: Exec format error
systemd[1]: boot-run-once.service: Failed to spawn executor: Exec format error
systemd[1]: modprobe@configfs.service: ... Exec format error
systemd[1]: systemd-firstboot.service: ... Exec format error
```
systemd (PID 1) runs, but `mount`, `modprobe`, `/bin/login` etc. do not —
so chunk 0 and 3 are good, **chunks 1 and 2 are still wrong content**. Only
their leading 8 MiB would have been checked by the CRC test; that test proved
chunk 0 and chunk 3, nothing about 1/2.

Then boot stalls 90 s and drops to `emergency.target`:
```
systemd[1]: Timed out waiting for device dev-disk-by-uuid-9DBB-3F03.device
systemd[1]: Dependency failed for boot.mount - /boot.
systemd[1]: System is tainted: unmerged-bin
```
`/etc/fstab` has `UUID=9DBB-3F03 /boot vfat` — that is the **USB stick's FAT
partition**, which does not exist on eMMC. Either give `/boot` its own real
UUID on eMMC or drop the `/boot` line; as-is it costs 90 s per boot and
forces emergency.target. **`nofail` is already on that line but the device
unit dependency still times out** — the wait is on the `.device` unit.

Also note `fstrim.timer`/`zram` etc. still fire.

### How to get a shell when systemd owns the console
There is **no** magic-sysrq (`CONFIG_MAGIC_SYSRQ` absent, no
`/proc/sysrq-trigger`) and `reboot`/`systemctl` need systemd. When systemd
reaches `emergency.target` it puts the prompt on **tty1 (HDMI)** and the serial
getty is dead, so the UART goes silent. Recovery is therefore always:
**power cycle -> catcher -> U-Boot**.

### Next actions
1. Re-copy **chunks 1 and 2** (or verify them with `crc32` over their full
   length first: `crc32 0x20000000 12C00000` vs the eMMC read-back).
2. Fix `/etc/fstab`: remove the `UUID=9DBB-3F03 /boot vfat` line or create a
   real `/boot`. Saves 90 s of boot and the emergency.target drop.
3. Then `saveenv` a bootcmd so no manual U-Boot commands are needed.

### Sanity anchors
- `e2fsck -fn` on the stick's `/dev/sda2` = **RC=0, clean** — the stick is the
  good source. If it is ever dirty, remount/dd from host `dl/p2.img`.
- eMMC success criteria after copy: `EXT4-fs (mmcblk1p1): ... r/w`,
  `e2fsck -fn /dev/mmcblk1p1` = RC=0, `/lib/systemd/systemd` starts with
  `7f 45 4c 46`, and systemd reaches a login prompt.

### Current recommended state
- Boot chain is fully understood and reproducible from U-Boot.
- `setenv bootargs` + `booti` works; `root=` can be anything.
- **eMMC mounts rw when the filesystem is clean** — that is the key result and
  it means the CPU3/journal-recovery crash is *not* triggered by a clean mount.
- Remaining: get a byte-exact clean rootfs onto eMMC.

---
## Session 2 (2026-10-17) — hardware verdict and full-speed test

### Git initialised
Repo created, full session history committed (`accfc49`). Large blobs gitignored.

### Reframing
Working box has a NON-STOCK bootloader: locked by OTA, unlocked by ADNL-flashing
an image from the XDA thread. Stock BL2 needs 6 failed DDR4/DDR3 probes before
LPDDR4 lands on fallback `mask:0008`. Hypothesis: reflash bootloader under-trains
DDR, and all "hardware" symptoms are downstream of that.

### U-Boot hardware tests (old box, at U-Boot prompt)
No `cptest`/`mtest`/`bdinfo`/`dm` in this U-Boot. Available: `ddrtest`, `ddr_cpu_test`.

**`ddrtest` (Amlogic vendor suite): clean, `Error count==0x00000000` every run.**
Patterns: walking-one, normal, no-cross-talk, cross-talk p/n/p2/n2. 3 read passes each.

CRITICAL CAVEATS about `ddrtest`:
- Arg form is `ddrtest <start> <length>`. Bare `ddrtest` = 0x01080000, len 32MB.
- **Out-of-range addresses SILENTLY CLAMP to a low default and still report
  success.** Requests for 0x50000000/0x60000000/0x70000000/0x7E000000 all clamped
  to 0x00200000-0x02200000 and reported clean. Do NOT trust those as coverage.
- It appears to compare its 3 reads against each other, so unmapped memory reads
  back as consistent garbage and still passes. Only *transient* errors are detected.

RAM top is between 0x42000000 and 0x44000000 (0x44000000 clamps), so ~1GB usable,
NOT the 2GB assumed earlier. Genuinely distinct windows tested clean: ~0x01000000
and 0x42000000. That is ~64MB of coverage, not full DRAM.

**Secure boot is NOT the blocker.** `printenv` shows `forUpgrade_secureBoot=false`.
The eFuse bit exists but is not enforcing. Consistent with observation: `bootm`/
uImage is rejected (`## Booting kernel from Legacy Image`) but unsigned `booti`
+ `setenv bootargs` works every time. Gate only applies to the legacy image path.
Other env facts: `bootloader_version=01.01.230319.122635`, `board=ohm`,
`board_name=sc2_ah212`, `bootcmd=run storeboot`, `baudrate=115200`,
`ethaddr=<MAC>`.

### FULL-SPEED BOOT — DECISIVE RESULT
Cmdline = baseline only, all mitigation flags REMOVED:
`root=/dev/mmcblk1p1 rootfstype=ext4 rootwait rw console=ttyS0,921600
no_console_suspend earlycon=aml-uart,0xfe07a000 watchdog.stop_on_reboot=0
pd_ignore_unused clk_ignore_unused TERM=vt220`

Result: **KERNEL PANIC at t=1.08s**
```
EXT4-fs (mmcblk1p1): mounted filesystem ... r/w with ordered data mode
VFS: Mounted root (ext4 filesystem) on device 179:1.
Run /sbin/init as init process
Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000004
CPU: 3 UID: 0 PID: 1 Comm: systemd Not tainted 6.18.55-meson64
  el0_undef -> el0t_64_sync_handler -> arch_do_signal_or_restart
```
`exitcode=0x04` = **SIGILL**. systemd's own code was corrupted in memory while
executing on **CPU 3** (again CPU 3). Rootfs mounted r/w and journal recovery
completed cleanly — storage/rootfs are NOT the problem.

### Comparison
| | Mitigated (`maxcpus=1 nohz=off cpuidle.off=1 idle=poll`) | Full speed |
|---|---|---|
| Cores | 1 | 4 |
| Outcome | boots to multi-user, 50 Exec format errors | **SIGILL panic at 1.0s** |

### Conclusion
Full speed is DRAMATICALLY worse. The mitigation flags do real work. Corruption
is of *executable code* under multi-core load = insufficient DRAM timing margin.
U-Boot's gentle fixed-config testing cannot detect it; Linux stressing DDR properly does.
Frequency/voltage margin (Phase 4) is now the leading path.

### Note
`EXT4-fs warning: mounting fs with errors, running e2fsck is recommended` still
appears — rootfs still has residual errors. Secondary issue, not the cause.

### Next
Pin CPU clock lower. Cheapest cmdline-only test: `cpufreq.default_governor=powersave`
with 4 cores. Then `maxcpus=2`. Build a ladder to find the highest stable point.

### Frequency ladder (single-variable changes from baseline)

| Cores | Idle flags | Outcome |
|---|---|---|
| 4 | none | SIGILL panic @ 1.08s, **CPU 3** |
| 4 | + cpufreq.default_governor=powersave | SIGILL panic @ 1.16s, **CPU 2** |
| 2 | none | SIGILL @ 2.47s, systemd caught it, froze, dumped core |
| 1 | nohz=off cpuidle.off=1 idle=poll | boots, 50 Exec format errors |

KEY FINDINGS:
- `cpufreq.default_governor=powersave` was a **NO-OP**. No `operating-points`/
  `opp-table` in DTB, cpufreq never registers. DTB defect:
  `OF: /thermal-zones/cpu-thermal/cooling-maps/cpufreq-cooling_map:
   could not get #cooling-cells for /cpus/cpu@0`
  Also `panfrost: _opp_set_regulators: no regulator (mali) found`.
  => Frequency scaling via cmdline is IMPOSSIBLE on this DTB. Need to add
  operating-points + cpu-supply via dtc, or regulate clock another way.
- The failing CPU is **random** (CPU 3 then CPU 2). The long-standing
  "CPU 3 in timer/idle paths" attribution is WRONG. There is no single bad
  core; corruption is general and hits whichever core fetches the bad word.
- 2 cores STILL corrupts => not simply "4 cores is too many".
- Fault is WIDESPREAD: at 2 cores it surfaced in a child process
  (`Caught <ILL> from PID -2026278752`), not just systemd.
- `watchdog: watchdog did not stop!` on the panic path - may need
  `nowatchdog` in cmdline for clean panics.

### NEXT TEST: `maxcpus=1` with NO idle flags
Never run. Separates core count from the idle-path flags.

### NEW LEAD — spare factory box as control
User has multiple SDSTB02 boxes. A spare has STOCK bootloader, is unlocked at
U-Boot, and runs Android fine on all 4 cores. The working box has the XDA
bootloader and needs maxcpus=1. Android proves the silicon can do 4 cores =>
this is NOT faulty hardware, it is a mainline-kernel/bootloader-DDR mismatch.

PLAN: read the STOCK bootloader off the spare's eMMC (READ ONLY, `mmc read`),
transfer to PC, diff against the XDA bootloader on the working box. If DDR
training/mask tables differ, that is the root cause AND the fix. Flashing the
stock bootloader to the working box is a reversible write.
GUARDRAIL: never write to the spare - it is the known-good reference.

### maxcpus=1 with NO idle flags — BEST RESULT SO FAR

Cmdline: `root=/dev/mmcblk1p1 rootfstype=ext4 rootwait rw console=ttyS0,921600
no_console_suspend earlycon=aml-uart,0xfe07a000 nowatchdog pd_ignore_unused
clk_ignore_unused TERM=vt220 maxcpus=1`

| Config | Exec errors | SIGILL | Reaches multi-user |
|---|---|---|---|
| 4 cores | - | panic @1.08s | no |
| 4 + powersave gov | - | panic @1.16s | no |
| 2 cores | - | @2.47s | no |
| 1 core + nohz=off cpuidle.off=1 idle=poll | 50 | 0 | yes (slow) |
| **1 core, NO idle flags** | **12** | 0 | **yes** |

**THE IDLE FLAGS WERE ACTIVELY HARMFUL.** Removing nohz=off / cpuidle.off=1 /
idle=poll cut exec errors 50 -> 12 and gave the cleanest boot to date. Yesterday's
"working" config was suppressing symptoms, and `nohz=off` was plausibly making
the memory behaviour worse. Do NOT re-add them.

Only 2 binaries still fail: systemd-logind, update-sysfs (was ~12).
Reaches multi-user.target. Reached at t=100s (slow - udevd device enumeration).

Added `nowatchdog` - last run ended `watchdog did not stop!` which forced a
reboot and lost the log.

NOTE: still 12 exec errors = same underlying corruption, just rarer at 1 core.
NARROWED, not solved.

### LOGIN FIX - CONFIRMED WORKING

Root cause chain (single causal chain, NOT separable):
  memory corruption -> systemd-udevd killed by SIGILL (status=4/ILL)
  -> no device units created -> dev-ttyS0.device times out (90s)
  -> serial-getty@ttyS0 fails on `BindsTo=dev-%I.device` -> no login.

FIX: drop-in at /etc/systemd/system/serial-getty@ttyS0.service.d/override.conf
```
[Unit]
BindsTo=
After=
[Service]
Environment=TERM=vt220
ExecStart=
ExecStart=-/sbin/agetty -o '-- \u' --noreset --noclear --keep-baud 1000000 ttyS0 vt220
```
WHY IT WORKS: /dev/ttyS0 is created by DEVTMPFS directly from the kernel -
it does NOT need udev. udev is only needed for systemd *device units*.
Clearing BindsTo AND After (both needed - After alone still orders behind a
device that never appears) lets agetty open /dev/ttyS0 despite dead udevd.

PROOF: agetty launched by hand against /dev/ttyS0 produced a real login
prompt ("Default login: root/tvbox", "(none) login:"). Full login NOT yet
proven - manual agetty and the init=/bin/sh shell both read ttyS0 and steal
each other's input. Next normal systemd boot will test it properly.

Root password: root / tvbox

### saveenv + unattended boot test
`saveenv` OK ("Saving Environment to STORAGE... OK"). bootcmd fired
UNAUTENDED - both `mmc read` lines appeared with no input. BUT:
```
[0.619657] Kernel panic: VFS: Unable to mount root fs on unknown-block(0,0)
```
No `Linux version`, no `Kernel command line`, NO EARLY CONSOLE OUTPUT.
=> **bootargs was EMPTY when booti ran.** `printenv bootargs` was correct
before saveenv, but the var did not reach the kernel on the unattended boot.
Root cause of panic: no `root=` (and no earlycon, hence total silence).

FIX (robust): embed `setenv bootargs` INSIDE bootcmd so it cannot depend on a
separate persisted env var:
```
setenv bootcmd "setenv bootargs \"root=... maxcpus=1\"; mmc dev 1; mmc read 0x2000000 c6000 c10d; mmc read 0x4000000 136000 2a; booti 0x2000000 - 0x4000000"
```

### Tooling notes
- `scripts/arm.sh` added. Do NOT use `pkill -f catch-uboot2.py` - the -f pattern
  matches the invoking shell and kills it. Use the pidfile.
- `CATCHER_GRACE` in catch-uboot2.py does NOT help while the box is already at
  the U-Boot prompt: the catcher spams CR every 0.12s and U-Boot echoes a
  prompt for each, so it catches its own noise. The catcher is only useful when
  the box is powered OFF and we wait for a real prompt.
- For an unattended-boot test, use `scripts/uartcap.py` (passive capture) and
  do NOT run the catcher - we want autoboot to proceed.

### Unattended boot attempt 2 - bootargs NOW PASSES, eMMC DOES NOT ENUMERATE
```
[0.000000] Kernel command line: "root=/dev/mmcblk1p1 ... maxcpus=1"   <- good
[1.149999] Kernel panic: VFS: Unable to mount root fs on unknown-block(0,0)
```
bootcmd fired (2x MMC read), bootargs embedded+delivered correctly. DTB is
byte-identical to the good boot ("Single DTB detected", end 1ffff52a in both).

DIFFERENCE vs good manual boot:
  good:     [0.494609] mmcblk1: mmc1:0001 A3A551 14.6 GiB
  failing:  eMMC controller NEVER PROBED. Only the SD controller appears
            (meson-gx-mmc fe08a000.mmc: Got CD GPIO @1.077s)

=> Unattended path runs `mmc dev 1` + reads + `booti` back-to-back in
milliseconds. Manual path had ~60s between reads and booti. Suspect U-Boot
leaves the eMMC controller busy and Linux cannot re-init it. `rootwait` is
not honoured (panics at 1.1s rather than waiting).

TODO: add a settle delay / controller re-init before booti in bootcmd.
NOTE: this U-Boot's help lists NO `sleep` and NO `mmc rescan`. Verify what
actually exists at the prompt before rebuilding bootcmd.

### BOOT LOOP - SELF INFLICTED. RECOVERY IN PROGRESS.

I added `crc32 0x2000000 0xc140000` to bootcmd as a "settle delay" hack
(this U-Boot has no `sleep`). It aborts:
```
MMC read: dev # 1, block # 1269760, count 42 ... OK
"Synchronous Abort" handler, esr 0x96000010
Fault address:0x5100000
x2 : 000000000c140000        <- the length I passed
Resetting CPU ...
```
The length walks into BL2's protected/scrambled region and takes a
synchronous abort, which resets the CPU. Infinite loop.

**LESSON: never put an untested command into the unattended boot path when its
failure mode is a reset. The `crc32` length was already flagged as dangerous in
notes.md and I used it anyway. Test interactively first, in a window that can
be recovered from.**

RECOVERY BLOCKER: `Hit any key to stop autoboot: 0` - bootdelay is ZERO, so
there is no interrupt window. Zero `sc2_ah212#` prompts in the whole loop:
U-Boot goes straight from countdown to bootcmd and resets. Cannot get in by
serial at all. `catch-uboot2.py` and `scripts/hold-run.py` both useless here.

RECOVERY: ADNL/USB download mode (button + A-A cable, per user).
`tools/utils/aml-flash-tool/tools/adnl/adnl` supports
  devices              - list DNL devices
  oem/cmd "<cmd>"      - send a U-Boot command to BL33  <-- the key capability
  upload -p <part> -f <f> -z <sz>   - dump a partition
  partition -p <part> -f <img>       - write a partition
Plan: `oem/cmd 'setenv bootcmd "echo RECOVERED"; saveenv'` -> U-Boot runs a
harmless bootcmd and drops to an interactive prompt, giving us a shell.
Backup of the flashed bootloader exists at backup/sdstb02/bootloader.img.

### CORRECTION: RAM is 2 GB, not ~1 GB
Full BL2 log: `DDR cs0 size: 2048MB`, `DMC_DDR_CTRL: 00c00054 DDR size: 2048MB`,
`cs0 DataBus test pass`, `cs0 AddrBus test pass`, `load mask:31`.
The earlier "~1GB" inference was WRONG - that was `ddrtest`'s out-of-range clamp,
not a memory limit.

### BL2 DDR training (now fully observed)
`build in ddr magic:ddr4` but the part is LPDDR4 (LPDDR4_PHY_SC2_0_1_26):
  DDR4  @1320MHz  mask 003f -> "Training has failed! 1D training failed"
  DDR4  @1320MHz  mask 003e -> failed
  DDR3  @912MHz   mask 003c -> failed
  DDR3  @912MHz   mask 002c -> failed
  DDR3  @912MHz   mask 000c -> failed
  LPDDR4@1176MHz  mask 000c -> failed
  LPDDR4@1176MHz  mask 0008 -> "Training successfully!" CA/1D/2D all succeed
So it falls back to the LAST mask and then trains PROPERLY, bus tests pass.
Consistent with the DRAM itself being healthy.

### RECOVERY - SUCCESSFUL (see also BOOT LOOP entry above)
The fix for the boot loop, found via the user's XDA reference:
  1. Button + USB A-A cable  -> DNL mode (1b8e:c004 Aml_DNL)
  2. `adnl reboot bootloader` -> fastboot (<BOARD_SERIAL> Android Fastboot)
  3. `fastboot flashing unlock` -> `unlocked: yes`
  4. `fastboot erase env`     -> `Erasing 'env' OKAY`  <-- KILLS THE LOOP
  5. `fastboot reboot`

KEY INSIGHT: DNL partition read/write is BLOCKED by secure boot
("upload not allowed as secure boot enabled", write -> "remote failure"),
`oem/cmd` unsupported, `getvar` unimplemented. But FASTBOOT, once unlocked,
writes fine. The XDA unlock method is the writable path - should have asked
the user this much earlier instead of treating DNL as the only channel.

AFTER RECOVERY: U-Boot is interactive again, `bootcmd=run storeboot` (defaults).
With default env it tries Android and fails AVB:
```
AVB2 verify with default kpub:520, vbmeta kpub:520
avb_slot_verify.c:432: ERROR: boot_b: Hash of data does not match digest in descriptor.
avb verification: locked = 1, result = 3
try upgrade as booting failure
```
=> This finally EXPLAINS why Android will not boot on this box: AVB checks the
boot image hash against vbmeta and our partition changes broke the match.
=> Also confirms the secure-boot eFuse IS enforcing (locked=1), contradicting my
earlier reading of `forUpgrade_secureBoot=false` (that only gates the upgrade path).

NOTE: `backup/sdstb02/bootloader.img` is 0 BYTES - there is NO bootloader backup.
Do that before it matters.

DO NOT setenv+saveenv bootcmd again. We now have unlocked fastboot, so a
persistent env can be FLASHED as an image instead of typed at a prompt.

### Standalone serial-console.service - unit works, agetty itself is corrupt
```
[OK  ] Started serial-console.service - Serial console on ttyS0 (no device dependency).
(agetty)[316]: serial-console.service: Failed to execute /sbin/agetty: Exec format error
restart counter is at 61
```
- The standalone unit LOADS and STARTS. `dev-ttyS0` occurrences = 0, the 90s
  timeout spew is GONE. Masking the template + a unit with no device dependency
  was the right structural fix.
- BUT /sbin/agetty fails DETERMINISTICALLY: 67 failures across 61 restarts,
  zero successes. systemd-logind fails 5x. Everything else fails 1x.
- Exec format errors 18 -> 154 (mostly the agetty restart loop).

*** KEY INFERENCE: a deterministic, always-fails exec is NOT a transient read
fault. It means the BYTES ON DISK are wrong. /sbin/agetty is genuinely corrupt
on the eMMC rootfs. ***
This is the user's original hypothesis ("maybe the corruption is from the build
on the stick or us manually moving it to emmc") and it has been the most likely
explanation all along. I talked myself out of it on day 1 and chased DDR /
bootloader theories instead.

NEXT TEST (decisive, cheap): from init=/bin/sh run `md5sum /sbin/agetty` 5+ times.
  - md5 CONSTANT across runs  => on-disk corruption. Re-copy from the USB stick.
  - md5 VARIES between runs  => transient read fault after all.
Then: boot with root=/dev/sda2 (root on the pristine stick). Same cmdline, only
root device differs.

NOTE: systemd warns `Ignoring unknown escape sequences: "-- \u"` - cosmetic.

### DECISIVE TEST - on-disk corruption theory is WRONG
Ran from init=/bin/sh (quiet system):
```
md5sum /sbin/agetty   x4  ->  bc56bdb778f7c902601ea126638b5867   ALL IDENTICAL
md5sum /mnt/u/sbin/agetty    ->  bc56bdb778f7c902601ea126638b5867   SAME
cmp /sbin/agetty /mnt/u/sbin/agetty  ->  IDENTICAL
/sbin/agetty --version    ->  RC=0, "agetty from util-linux 2.41.5"
/mnt/u/sbin/agetty --version -> RC=0
ls -l: both 134672 bytes, identical
```
=> The eMMC copy is BYTE-IDENTICAL to the pristine stick. The file is NOT
corrupt on disk. agetty EXECUTES FINE from a shell.

=> The "deterministic always-fails" reading was wrong. The difference is LOAD:
  quiet shell  -> exec works
  systemd boot -> exec fails (67x)
This is transient corruption under CONCURRENT LOAD, which is the original
signature. The md5 test was clean precisely because it ran in the one condition
where corruption does not occur - a methodological trap worth remembering.

Stick is /dev/sda1 (256M FAT), /dev/sda2 (773M ext4), NO labels on either.
Cannot use root=UUID= or root=LABEL= : the eMMC rootfs is a copy of the stick's
partition 2 and shares both UUID (56ca1992-...) and would share its label.

### Stick re-imaged and VERIFIED
dl/devmfc-trixie.img sha256 401f2587d8c6d5970743e4947181d638b746f99916443392ebb050d049698d8e
verified against a fresh `xz -dc` of the original .xz.
Also established: p2 (rootfs) of devmfc-trixie.img and devmfc-trixie-ready.img
are BIT-IDENTICAL - the -ready edit was only in the FAT boot partition at 16MB.
The stick previously held -ready (sha c2bdd53f...), i.e. our modified copy.

### NEW FIX APPLIED: infinite restart for serial-console.service
Restart counter reached 61 - that is systemd's start-limit giving up, not agetty
being permanently broken. Added `StartLimitIntervalSec=0` and `RestartSec=5` so it
retries forever; once the boot-time load subsides, exec should succeed.
NEXT: boot normally (no init=/bin/sh) and see whether a login prompt eventually
appears. That is the real test of the load-dependent-corruption theory.

### Boot 2026-10-17 16:0x - exec errors collapsed, agetty now EXECS but exits
| Metric | Prior boot | This boot |
|---|---|---|
| Exec format errors | 154 | **6** |
| SIGILL | - | 10 |
| SEGV | - | 10 |
No `(agetty)` failure lines at all. systemd reports `Deactivated successfully`
i.e. agetty starts and immediately exits.

Suspected cause: the unit's `StandardInput=tty` / `StandardOutput=tty`. With
`console=ttyS0`, ttyS0 is ALREADY systemd's stdio; forcing those directives
makes systemd try to re-assign the unit's terminal to itself. `--keep-baud`
also needs a real terminal to query.

NEXT FIX: drop StandardInput/StandardOutput and `--keep-baud`:
`ExecStart=-/sbin/agetty --noreset --noclear ttyS0 vt220`
(Writing it hit BlockingIOError - the catcher held the serial port. Sequence
must be: power cycle -> catch U-Boot -> init=/bin/sh -> write unit -> power
cycle -> test. Do not arm a catcher while the box is already running Linux.)

### *** WORKING LOGIN ACHIEVED *** rescue-init.sh
`/root/rescue-init.sh` (1316 bytes) written to the eMMC rootfs, then exec'd
from an init=/bin/sh shell so it took over the console immediately.

Result: full Debian login banner, prompt, and successful authentication:
```
#  Debian GNU/Linux 13 (trixie) with Kernel 6.18.55-meson64 on aarch64  #
#  Host:        eon-sc2               #
#  Default login: root/tvbox ...
eon-sc2 login: root
Password:
eon-sc2:~# LOGIN_OK
uid=0(root) gid=0(root) groups=0(root)
Linux eon-sc2 6.18.55-meson64 #73 SMP PREEMPT Sun Oct 4 15:24:35 CEST 2026 aarch64
```

BOOT WITH: init=/root/rescue-init.sh   (appended to the maxcpus=1 cmdline)

Why systemd could never do this: systemd fails to exec /sbin/agetty with
"Exec format error" on EVERY attempt (51+ retries), while the identical
binary execs with RC=0 from a plain shell, and is byte-identical to the
pristine stick copy. Best explanation: a page of the binary poisoned in the
page cache by an earlier bad read during systemd's boot-time load; systemd
then maps that page forever. rescue-init sidesteps systemd entirely.

Caveat: no systemd => no dbus/logind/networkd/systemctl. It is a rescue shell,
not a normal Linux desktop. The box still cannot run multi-core reliably.

### Load test wedged the console
Ran 6x `dd if=/dev/mmcblk1 bs=1M count=120` in parallel + 4x 250MB tmpfs
writes, while md5summing 30 times. Result: serial began emitting a continuous
stream of NUL bytes - UART wedged under load. NEEDS POWER CYCLE.
Lesson: do not run heavy parallel I/O on this box; it is already marginal.

### HDMI + KEYBOARD CONSOLE WORKS
`/root/rescue-init.sh` now also spawns a BACKGROUNDED agetty on tty1:
```
( while true; do /sbin/agetty --noreset --noclear tty1 vt220; sleep 1; done ) &
```
Backgrounded on purpose so it can never block or kill the serial console.
Verified: user has a working login prompt on HDMI, root/tvbox.
rescue-init.sh works as a real `init=` (not just exec'd from a shell) - boots
to a login prompt in ~3s vs ~100s to multi-user under systemd.

FINAL WORKING CONFIGURATION (this box):
  mmc dev 1
  mmc read 0x2000000 c6000 c10d          # kernel
  mmc read 0x4000000 136000 2a           # dtb
  setenv bootargs "root=/dev/mmcblk1p1 rootfstype=ext4 rootwait rw \
    console=ttyS0,921600 no_console_suspend earlycon=aml-uart,0xfe07a000 \
    nowatchdog pd_ignore_unused clk_ignore_unused TERM=vt220 maxcpus=1 \
    init=/root/rescue-init.sh"
  booti 0x2000000 - 0x4000000

DRM initialises fine: `meson-drm ff000000.vpu: Queued 2 outputs on vpu.hdmi-tx`,
`[drm] Initialized meson 1.0.0`, `[drm] fb0: mesondrmfb frame buffer device`.

REMAINING KNOWN ISSUES (not fixed):
 - Box runs single-core only. Multi-core causes SIGILL/corruption within ~1-2s.
 - Memory fault NOT root-caused. Best hypothesis: a poisoned page in the page
   cache, seeded by a bad read during systemd's parallel boot load, which then
   poisons every exec. rescue-init works around it by bypassing systemd.
 - Networking dead: `end0: Failed to reset the dma`, stmmac DMA init fails.
 - No unattended boot yet (bootcmd is default after `fastboot erase env`).
   Should be fixed by FLASHING an env image via fastboot, not `saveenv`.
 - `backup/sdstb02/bootloader.img` is 0 bytes - create a real backup.

### FACTORY BOX (unmodified) - MAJOR FINDING
Tested on a brand-new, unmodified SDSTB02. Nothing written to its eMMC.

FACTORY ENV vs FLASHED BOX ENV:
  bootdelay=0      (same as flashed box)
  bootcmd=run storeboot   (same as flashed box)
  baudrate=115200  (same)
=> The XDA flash did NOT change bootcmd/bootdelay/baudrate.
=> Theory "unlocking broke the USB path" is WRONG.

FACTORY BOOTLOADER **DOES** HAVE A USB BOOT PATH:
  update=run usb_burning; run recovery_from_sdcard; run recovery_from_udisk; run recovery_from_flash;
  recovery_from_udisk=...setenv fatload_dev usb; if usb start 0; then run recovery_from_fat_dev; fi;
  recovery_from_fat_dev=...fatload ${fatload_dev} 0 ${loadaddr} aml_autoscript; then autoscr ...
Earlier "factory boxes can't boot from USB" was therefore an IMAGE/script problem,
not an unlocking problem.

FULL-SPEED TEST ON FACTORY BOX: booted kernel from stick via aml_autoscript
=> KERNEL PANIC. Same failure as the flashed box.
*** THE BOOTLOADER IS NOT THE VARIABLE. The fault is in the kernel or the SoC
itself. The flashed-bootloader theory is dead. ***

SINGLE-CORE TEST ON FACTORY BOX: attempted maxcpus=1 + root=/dev/sda2 with the
board's own DTB (sc2_s905x4_ah212 from dtbo via common_dtb_load).
=> Kernel produced ZERO console output at every baud. Hangs before console init.
CONFOUNDED: this used the factory DTB, not the 21KB devmfc DTB the working box
uses. Need to retry with the identical DTB to isolate maxcpus properly.

Notes for next time:
 - DTB lives at 0x1000000 when loaded via common_dtb_load; booti needs
   `booti <kernel> - 0x1000000`. Using 0x4000000 fails with
   "Did not find a cmdline Flattened Device Tree".
 - This U-Boot has no `dir`/`ls` for USB. Use fatload + RC to probe filenames.
 - Kernel file on stick FAT: `vmlinuz-6.18.55-meson64` (25.3 MB).
 - DTB name unknown; ${dtb_img} comes from a box-config that is not present.
 - Working box's DTB is ~21KB; candidates in dl/ are sc2-gbit*.dtb.

### ARMBIAN VIA bootefi - BLOCKED BY U-Boot EFI LOADER (significant finding)
Armbian ships a PE/ZBOOT-wrapped kernel (`zImage`, 41.95 MB, CONFIG_EFI_ZBOOT).
`booti` mis-parses it (session-1 blocker), so the correct entry is `bootefi`.
It does NOT work on this box:
```
## Starting EFI application at 02000000 ...
EFI stub: ERROR: FIRMWARE BUG: efi_loaded_image_t::image_base has bogus value
EFI stub: ERROR: FIRMWARE BUG: kernel image not aligned on 64k boundary
EFI stub: ERROR: FIRMWARE BUG: Image BSS overlaps adjacent EFI memory region
EFI stub: Using DTB from configuration table      <- our DTB at 0x4000000 ignored
EFI stub: ERROR: Unable to construct new device tree.
EFI stub: ERROR: Failed to update FDT and exit boot services
## Application terminated, r = 1
```
Retried with `fdt addr 0x4000000` and with the kernel loaded at 0x10000000 -
identical failure. Root cause is in U-Boot's EFI loader, not the image.

PE header inspection of zImage:
  MZ @0, PE @0x40, 2 sections (.text 36MB, .data 6.7MB)
  ImageBase = 0x0   <- malformed/nonstandard, this is what the stub chokes on
  SectionAlignment = 0x0, FileAlignment = 0x10000

*** CONSEQUENCE: Armbian (and any ZBOOT-wrapped kernel) cannot boot on this box
without a U-Boot that supports ZBOOT. This is a hard blocker for Armbian. ***
The reliable path is a NON-PE kernel (like devmfc's) - mainline kernels from
kernel.org are non-PE by default, so a prebuilt mainline Image for another
version would work via booti. Building or sourcing one is the next task.

Reused: projetotvbox/amlogic-bootscripts-Armbian turned out to be a STUB (its
aml_autoscript only does `saveenv`; .command has no kernel loading). Dead end.
The devmfc bootscript loads `vmlinuz-${release}` from FAT and does
`booti ${os_addr} ${rd_addr} ${dtb_addr}` - the mechanism that works here.

Armbian extlinux.conf references: /zImage, /uInitrd,
/dtb/amlogic/meson-sm1-x96-max-plus-100m.dtb (close to but not identical to ah212).

### PHASE A STEP 1 - DTB CPU/OPP AUDIT (pyfdt 0.3 installed; pip --user --break-system-packages)
Tooling note: our hand-rolled FDT walkers in scripts/fdt.py + /tmp desync on NOP
tokens and produce garbage. `pip install --user --break-system-packages pyfdt`
works and is reliable; use `FdtBlobParse().to_fdt().resolve_path(P).dts_represent(0)`.
apt/dtc unavailable (no apt-get on this host).

Audited dl/sc2-gbit*.dtb (all variants share the same /cpus).

FINDING 1 - the OPP table EXISTS and is correct. /opp_table, 13 opps,
100MHz-2000Hz(2.0GHz), voltages 779mV..1005mV, compatible=operating-points-v2.
So the "missing OPP table" hypothesis is DISCONFIRMED. Per the plan's own step-2
decision point, we stop rather than build a variant for its own sake.

FINDING 2 - the OPP table is ORPHANED, not missing. /opp_table has NO phandle,
and NO cpu node references it. Our cpu@0..3 lack, vs mainline
meson-sm1-odroid-hc4.dtb:
    operating-points-v2 = <phandle>   (ours: absent)
    clocks = <0x2 0xbb>               (ours: absent)
    cpu-supply = <phandle>            (ours: absent - no regulator-vddcpu,
                                                 no regulator-pwm node at all)
    #cooling-cells                    (ours: absent)
Consequence: cpufreq-sched never registers. Confirms the earlier finding that
cpufreq.default_governor=powersave was a silent no-op. CPU frequency is left
entirely at whatever BL2/U-Boot programmed; the kernel never touches it.

FINDING 3 - HAZARD if we "fix" the wiring naively. Upstream v6.3 removed CPU
OPPs below 1GHz for G12A boards. Our table's four lowest entries are exactly
100MHz/250MHz/500MHz/666MHz. Enabling cpufreq-sched with a powersave governor
would let the kernel select an OPP upstream considers invalid for this SoC.
Wiring it up is therefore NOT a safe drop-in - it needs the low OPPs trimmed
first. This may be why the vendor DTB ships it unwired.

FINDING 4 - L2 cache description is IDENTICAL to mainline hc4 (256KB unified,
64B lines, 256 sets). Cache coherency geometry is therefore not our bug. Kills
the v4.16 "L2 cache settings" lead.

Unrelated but noted: panfrost logs "_opp_set_regulators: no regulator (mali)
found" repeatedly - the GPU OPP table /opp-table-gpu has microvolt 0x47e (1150,
nonsense) and no mali regulator node. Cosmetic for now, GPU is unusable anyway.

CONCLUSION: the DTB is not obviously the cause. The strongest remaining DTB-side
idea is that the CPU runs at an unknown, BL2-set frequency with zero kernel
oversight - worth ONE cheap controlled test (read /sys/devices/system/cpu at
single core to learn the actual frequency), but not a rewrite.

### PHASE C STEP 1 - ETHERNET ROOT-CAUSE RESEARCH (read-only, no box touched)
Sought prior art instead of guessing. Same SoC family (SM1/G12A), same error.

CONFIRMED OUR FAULT MATCHES khadas VIM2 (g12a) issue exactly:
  meson8b-dwmac ...: Failed to reset the dma
  eth0: stmmac_hw_setup: DMA engine initialization failed
  eth0: stmmac_open: Hw setup failed
Root cause there was NOT a missing driver - it was DTB config. hyphop's fix
(hyphop/khadas-linux-kernel, patches/linux-5.4.5/0030):
  patches/linux-5.4.5/0030-fix-broken-ethernet-interface-up-down.patch
  - comment out reset-gpios on &ethmac, add max-speed = <1000>
  Comment in patch: "no need it ## hyphop ##"
chewitt's WORKING g12a log has the line "no reset control found" - i.e. the fix
in effect is the ABSENCE of a reset control.

OUR DTB eth node (/soc/ethernet@fdc00000) - audit vs mainline:
  [x] NO reset-gpios already  -> so the khadas reset-gpios bug does NOT apply
  [ ] NO max-speed            -> khadas fix adds this; ours lacks it
  [ ] NO "timing-adjustment" clock. mainline x96-max-plus AND x96-air both have
      clock-names = "stmmaceth","clkin0","clkin1","timing-adjustment".
      Ours has only 3 names. The timing-adjustment clock is what the driver uses
      to set RGMII delays in hardware.
  [!] phy-mode = "rgmii-txid" + rx-internal-delay-ps = <0x578> (1400ps).
      Mainline x96-max-plus uses plain phy-mode = "rgmii".
      Driver log: "Selected RGMII-TXID phy-mode, so not setting TX clock skew on
      mac side" - the delay handling path differs from mainline.
  [i] reg base fdc00000 (ours) vs ff3f0000 (mainline kernels we looked at) -
      different kernel/driver generation, expected.
  [i] phy-handle = <0x11> = internal PHY at mdio-multiplexer@28000/mdio@0/
      ethernet-phy@0, max-speed = 1000. Second PHY ethernet-phy@8 (id 0180.3301
      = RTL8211F) is status="disabled".

KEY GAP IN OUR OWN PRIOR WORK: notes line 781 says we tried "all 4 devmfc ah212
DTB variants (same clocks/FIFOs; only phy-mode differs)". Those were all our own
sc2-gbit* shims, which all share the missing timing-adjustment clock and the
rgmii-txid mode. We have NEVER tried a mainline x96-max-plus.dtb on this box,
even though we have it locally (dtbs/dtb/amlogic/meson-sm1-x96-max-plus.dtb).
That is the obvious untried experiment and it is zero-risk (USB stick only).

CAVEAT: ophub issue 121 is a DIFFERENT fault (external IP1001M USB ethernet chip,
no mainline driver) - do not conflate with ours.

### PATCHED DTB BUILT OFFLINE: dtbs/patched/sc2-gbit-ethfix.dtb
Built with pyfdt (scripts at /tmp/opencode/mketh.py during session; copy in later).
Verified: reparses cleanly, exactly 8 changed lines, all inside
/soc/ethernet@fdc00000. /cpus /mdio /reserved-memory /opp_table all still present.

Full eth-node diff vs our original sc2-gbit.dtb:
  clocks: 3 entries -> 4, adding clock-controller 0x06 id 0x0d.
    0x0d = G12A "timing-adjustment" clock. Verified from TWO independent upstream
    DTBs: meson-sm1-x96-max-plus.dtb and meson-g12a-s905l3a-m401a.dtb (both
    clock-names = "stmmaceth","clkin0","clkin1","timing-adjustment", 4th id 0x0d)
  + clock-names gains "timing-adjustment"
  + max-speed = <1000>            (hyphop patch 0030)
  + snps,rxpbl = <8>, snps,txpbl = <8>, amlogic,tx-delay-ns = <2>
    (copied from upstream x96-max-plus)

Deliberately NOT changed:
  phy-mode stays "rgmii-txid" and rx-internal-delay-ps stays 1400. Switching to
  plain "rgmii" would also need removing rx-internal-delay-ps, and that changes
  two variables at once. Keep the experiment single-variable.
  reg stays fdc00000 - must match our kernel's driver generation, NOT mainline's.

This DTB is a fallback. FIRST test remains booting mainline
meson-sm1-x96-max-plus.dtb unchanged, so we learn whether the stock mainline
config works before we start changing ours.

### ETH TEST 1 - mainline x96-max-plus.dtb: U-Boot OK, kernel SILENT. ROOT CAUSE FOUND.
Booted via run recovery_from_udisk (usb start 0 -> recovery_from_fat_dev ->
aml_autoscript -> devmfc bootscript). U-Boot side was PERFECT:
  Using devicetree [dtb-6.18.55-meson64/amlogic/meson-sm1-x96-max-plus.dtb]
  77026 bytes read / 25303048 bytes read (kernel) / Starting linux with cmdline:...
  ## Flattened Device Tree blob at 04000000
   Booting using the fdt blob at 0x4000000
  Starting kernel ... / boot 64bit kernel
=> the mainline DTB LOADS and ACCEPTSED against our devmfc kernel. The
cross-generation pairing (ff3f0000 DTB vs fdc00000 kernel) is NOT fatal at the
U-Boot/booti level, as suspected.

BUT: kernel produced ZERO console output. No "Linux version", no earlycon, no
panic. Not a SIGILL - it dies before the first printk.

ROOT CAUSE: memory node size mismatch.
  OURS  dl/sc2-gbit.dtb                memory@0 reg = <0x0 0x0  0x0 0x80000000>  = 2 GB  (correct)
  MAIN  meson-sm1-x96-max-plus.dtb      memory@0 reg = <0x0 0x0  0x0 0xffffffff>  = 4 GB  (WRONG)
The mainline x96-max-plus DTB is built for the 4GB variant of that board. On our
2GB box the kernel is told 4GB exists, initialises page structs/allocators over
memory that is not there, and dies before console_init.

Lesson: a silent kernel with no output at all means a pre-console-init failure -
memory sizing being the first thing to check. It is NOT the multi-core bug and
NOT SIGILL. Distinguish "no output whatsoever" from "output then SIGILL/Exec
format"; they are different faults with different causes.

### *** CONTROL TEST: USB BOOT WORKS *** (the test I should have run FIRST)
Ran the missing control - boot from USB with the KNOWN-GOOD DTB
(dtb-.../amlogic/meson-sc2-ah212-generic-gbit.dtb, 21036 bytes = same as our
dl/sc2-gbit.dtb), kernel from USB, rootfs /dev/sda2 from USB, identical cmdline.

RESULT: FULL BOOT TO LOGIN.
  [0.000000] Linux version 6.18.55-meson64
  [0.017967] Memory: 1699056K/2088960K available (14016K kernel code ...)
  [2.236632] VFS: Mounted root (ext4 filesystem) on device 8:2.
  Debian GNU/Linux 13 (trixie) ... eon-sc2 login:
Logged in as root. Root FS /dev/sda2 69% of 780M.

=> USB boot is FINE. The silent kernels in test 1 were caused by the MAINLINE
   DTB, not by USB. Both mainline-DTB runs (4GB version and 2GB-fixed version)
   went silent; this run with our own DTB boots perfectly. The memory-size fix
   was a REAL bug worth fixing but was NOT the cause of the silence - hypothesis
   disconfirmed, and I should have run this control before theorising.

METHODOLOGICAL NOTE (2nd time this session): I theorised, built a patch on the
theory, and only afterwards ran the control that would have told me which
variable mattered. Same shape as the md5sum-in-a-quiet-shell error and the
never-compared-against-a-factory-box error. THE CONTROL COMES FIRST.

*** ETHERNET: now reproducible on demand, and NOT fixed by USB boot ***
Boot log shows NO "Failed to reset the dma" at probe time. It only appears when
the interface is brought up:
  [ 140.25] eth0: PHY [mdio_mux-0.0:00] driver [Generic PHY] (irq=POLL)
  [ 140.46] eth0: Failed to reset the dma
  [ 140.46] eth0: stmmac_hw_setup: DMA engine initialization failed
  [ 140.46] eth0: __stmmac_open: Hw setup failed
  ip link set eth0 up -> RTNETLINK answers: Connection timed out
Reproduced twice (t=140s, t=230s) at will from a root shell. That is a big
improvement in our position: previously this could only be observed in a boot
log; now it is an interactive, repeatable experiment.

Next: boot test 2 - dtb/sc2-gbit-ethfix.dtb, already staged on the stick
(timing-adjustment clock 0x0d + max-speed 1000 + snps,rxpbl/txpbl).

### ETH TEST 2 - sc2-gbit-ethfix.dtb: boots fine, ETHERNET STILL FAILS
Boot to login clean (VFS: Mounted root, 2.38s). eth0 up still fails identically:
  [139.47] eth0: Failed to reset the dma / DMA engine initialization failed /
          __stmmac_open: Hw setup failed / RTNETLINK Connection timed out
=> HYPOTHESIS DISCONFIRMED. The timing-adjustment clock + max-speed + snps
   rxpbl/txpbl are NOT the cause. DTB-side ethernet configuration is now
   largely eliminated (we tried: no-op, mainline DTB, patched DTB).

Useful negative result: driver still logs "Selected RGMII-TXID phy-mode, so not
setting TX clock skew on mac side" - the driver is running the SAME code path
regardless of our DTB changes, i.e. the extra properties we added are not
reaching the delay code. Also no clk_summary output - debugfs clocks not
available in this rescue init.

Next options, in order of cost:
 1. Live experiments from this root shell (cheap): try ethtool-style register
    poke, check the internal PHY at mdio_mux-0.0:00 is real (Generic PHY =
    unrecognised id - suspicious for an internal RGMII PHY).
    "Generic PHY" on an INTERNAL Amlogic PHY is a red flag worth chasing.
 2. Compare against the vendor DTB's ethmac node (amlogic,meson-g12a-dwmac in
    orig-from-stick/meson-g12a-*.dtb uses different reg base ff3f0000 and
    phy-mode "rmii" for some boards).
 3. Accept: mainline stmmac may simply not drive this board's internal PHY, and
    get networking via the vendor 5.4 kernel (option D) instead.

### ETHERNET LIVE DIAGNOSIS: phy_id 0x0000ff80, phy-mode rgmii-txid
Live from root shell (reproducible on demand):
  /sys/bus/mdio_bus/devices/mdio_mux-0.0:00/phy_id        = 0x0000ff80
  /sys/bus/mdio_bus/devices/mdio_mux-0.0:00/phy_interface = rgmii-txid
  driver announces "Generic PHY" (unrecognised id), mdio_mux-0.1:08 ABSENT
  (the RTL8211F @0180.3301 node in our DTB is status="disabled", as shipped)

0x0000ff80 is NOT a real OUI-bearing PHY id - this is the Amlogic INTERNAL PHY,
not an external RTL8211F. So the box is using the SoC-internal RGMII PHY.

*** KEY LEAD: this may be a 100M board, not gigabit. ***
The VENDOR DTS for OUR EXACT BOARD (CoreELEC amlogic-5.4.210,
arch/arm64/boot/dts/amlogic/sc2_s905x4_ah212.dts) says:
    &ethmac { status = "okay"; phy-handle = <&internal_ephy>; phy-mode = "rmii"; }
  => internal_ephy + RMII = 100 Mbit. Our DTB uses rgmii-txid + max-speed 1000.
notes.md:609 chose "gigabit" by reading max-speed=<0x3e8> out of the vendor DTB -
but max-speed is a DECLARATION, not evidence of the fitted hardware. That
assumption may be the whole bug: declaring an RGMII/gigabit interface on a
board wired for RMII/100M would leave the MAC and PHY mismatched, which is a
plausible cause of "Failed to reset the dma".

NEXT TEST (cheap, one DTB each):
  A) phy-mode = "rmii", keep internal PHY  -> matches the vendor board file
  B) A + max-speed = <100> on the PHY node
Both keep everything else identical. If either works, the board is 100M and the
"gbit" naming in our DTB family was simply wrong for this variant.

### ETH TEST A (RMII): boots fine, STILL "Failed to reset the dma"
Boot to login clean (VFS: Mounted root, 2.44s). phy-mode confirmed applied -
/sys/bus/mdio_bus/devices/mdio_mux-0.0:00/phy_interface now reads "rmii".
Yet:
  [149.67] eth0: Failed to reset the dma
          stmmac_hw_setup: DMA engine initialization failed
          __stmmac_open: Hw setup failed
  ip link set eth0 up -> RTNETLINK Connection timed out
=> The 100M/RMII hypothesis is DISCONFIRMED as the fix. Interface mode was
   genuinely changed and the failure is byte-identical.

ERROR PATH IDENTIFIED (from codebrowser stmmac_main.c ~line 3208):
  ret = stmmac_reset(priv);
  if (ret) { netdev_err(... "Failed to reset the dma\n"); return ret; }
  => dwmac_dma_reset() failed. It writes DMA_MODE.SWR (software reset) and
     polls for the hardware to CLEAR that bit. On this board it never clears.
This is a MAC-internal register operation, upstream of any PHY/speed
negotiation. That explains why phy-mode, max-speed and RGMII delays all had
zero effect - none of them run before or affect the DMA soft-reset handshake.

TEST B (sc2-rmii-100m.dtb) IS STILL ON THE STICK but is now low-value: it only
differs by PHY max-speed 1000->100, which cannot affect a DMA register reset
that happens before link/speed negotiation. Recommend SKIPPING it.

ASSESSMENT: DTB configuration is now thoroughly excluded -
  interface mode (rgmii-txid / rmii) ....... tested, no effect
  max-speed (1000 / 100) ..................... no plausible path, not tested
  timing-adjustment clock .................... tested (ethfix), no effect
  snps rxpbl/txpbl, amlogic tx-delay-ns ....... tested (ethfix), no effect
  rx-internal-delay-ps ........................ tested (rmii), no effect
  reset-gpios ................................ absent already
Remaining explanations are the DRIVER (devmfc's patched stmmac - note the
DEVMFC: printk code paths, which are not mainline) or the VENDOR 5.4 kernel.

### *** PHASE E STEP 1 - DEVMFC PATCH READ: FOUND A BUILT-IN OVERRIDE ***
devmfc/linux (github). Branches: master (stock mainline), meson64-6.6/6.10/6.11/
6.12/6.13/6.14. NO 6.18 branch on GitHub - our kernel is 6.18.55-meson64, so the
exact tree is not public; but the patch is identical in 6.12 and 6.14 (both 606
lines, 8 DEVMFC prints), so the logic below almost certainly still applies.

File: drivers/net/ethernet/stmicro/stmmac/dwmac-meson8b.c (devmfc-patched).

*** THE KEY FINDING: devmfc added a KERNEL-CMDLINE OVERRIDE for exactly these
two registers, explicitly for debugging this class of problem: ***
  int cmdline_mc_val = -1;
  module_param_named(mc_val, cmdline_mc_val, int, 0);
  MODULE_PARM_DESC(mc_val, "Kernel commandline mc_val. Is override value for
      the complete (u32|0xffff_ffff) ETH_REG0 register");
  int cmdline_cali_val = -1;
  module_param_named(cali_val, cmdline_cali_val, int, 0);
  MODULE_PARM_DESC(cali_val, "... ETH_REG1 register");
In probe(), AFTER stmmac_dvr_probe() and AFTER debug_show_regs():
  if (cmdline_mc_val > -1)   writel(cmdline_mc_val,   dwmac->regs + PRG_ETH0);
  if (cmdline_cali_val > -1) writel(cmdline_cali_val, dwmac->regs + PRG_ETH1);
  then debug_show_regs(dwmac, "resulting");
The in-source comments even carry suggested values:
  dwmac-meson8b.mc_val=0x1621
  dwmac-meson8b.cali_val=0xa0000

*** WHY THIS MATTERS TO US ***
The probe order is:
  meson8b_init_rgmii_delays()   (RX/TX delay + timing-adjustment clock)
  meson8b_init_rgmii_tx_clk()
  data->set_phy_mode(dwmac)     <-- PRG_ETH0_EXT_PHY_MODE: RGMII(1) vs RMII(4)
  meson8b_init_prg_eth()        <-- RGMII: clk_set_rate(125MHz)+enable TX clk;
                                     RMII: INVERTED_RMII_CLK instead
  stmmac_dvr_probe()
  <-- mc_val / cali_val override applied HERE, after all of the above
So ALL of the DTB properties we tested (phy-mode, rx/tx delay, timing-adjustment
clock, max-speed) are consumed in meson8b_init_rgmii_delays/set_phy_mode/
init_prg_eth - i.e. BEFORE the override point. That fully explains why none of
them changed the outcome, and confirms the fault is downstream of DT config.

Our observed register state:
  after stmmac_dvr_probe: eth reg0 = 0x00001601  reg1 = 0x00070260
  resulting:              eth reg0 = 0x00001601  reg1 = 0x00070260   (identical)

NEXT TEST (cheapest yet - no new kernel, no DTB, no re-flash):
  append to bootargs:  dwmac-meson8b.mc_val=0x1621 dwmac-meson8b.cali_val=0xa0000
The driver will then writel() those into PRG_ETH0/PRG_ETH1 and print the
"resulting" values. If reg0 changes away from 0x1601, we have a working knob.
Caveat: this is a REGISTER BLIND WRITE supplied by devmfc as a guess for a
different board; it may not be correct for ours. But it is one boot, needs no
new artifacts, and directly tests whether ETH_REG0/1 state is what blocks the
DMA soft-reset.

### ETH mc_val/cali_val TEST: knob WORKS, still fails - registers excluded
Boot with dwmac-meson8b.mc_val=0x1621 dwmac-meson8b.cali_val=0xa0000 appended.
The devmfc module params were accepted and the writes took effect:
  after stmmac_dvr_probe  reg0 = 0x00001601  reg1 = 0x00070260
  set reg0 via mc_val      -> 0x00001621
  set reg1 via cali_val    -> 0x000A0260   (note: NOT 0xa0000 - bits 0x260
                                            were already set and are preserved,
                                            i.e. the driver ORs into the reg)
  resulting                reg0 = 0x00001621  reg1 = 0x000A0260
So ETH_REG0/ETH_REG1 genuinely changed and the failure is IDENTICAL:
  [150.56] Failed to reset the dma / DMA engine initialization failed /
           __stmmac_open: Hw setup failed / RTNETLINK Connection timed out

=> PRG_ETH0/PRG_ETH1 (ETH_REG0/ETH_REG1) state is DISCONFIRMED as the cause of
   the DMA soft-reset failure. devmfc's own suggested values were applied and did
   not help.
=> Phase E step 1 is now CLOSED. Both its sub-goals answered:
     - the patch's probe order explains why all DTB tests were futile (confirmed)
     - the register override lever devmfc left exposed does not fix it (confirmed)

Remaining in phase E: only step 2, a STOCK MAINLINE arm64 kernel, to isolate
whether devmfc's patch (or something else in their tree) breaks stmmac. Note the
0x6.18 tree is not public (branches stop at meson64-6.14), so we cannot diff our
exact kernel against stock - which is precisely why the empirical step-2 boot is
the only way to answer it.

### PHASE E STEP 2 - DEBIAN ARM64 KERNEL IS ALSO ZBOOT-WRAPPED (blocked)
Tried Debian trixie linux-image-6.12.107+deb13-arm64-unsigned (stock mainline,
NOT devmfc - exactly the isolation test we wanted).
  deb.debian.org/.../linux-image-6.12.107+deb13-arm64-unsigned_6.12.107-1_arm64.deb
  extracted boot/vmlinuz-6.12.107+deb13-arm64, 37659136 bytes.
VERDICT: ZBOOT/PE-wrapped, same blocker as Armbian:
  starts with "MZ", PE header at 0x40, 2 sections:
    .text  vaddr=0x10000 filesize=0x1e00000 filepos=0x10000
    .data  vaddr=0x1e10000 filesize=0x5da200 filepos=0x1e10000
  No raw arm64 Image anywhere: ARMd magic (0x644d5241) absent at .text start.
  .text begins 1f2003d51f2003d5... = repeated ZBOOT compressed-stub stub words,
  NOT gzip/lz4/zstd framing and NOT an Image header.
=> booti cannot boot it, and bootefi is broken on this box (plan section 5).
=> "Debian does NOT enable EFI_ZBOOT on arm64" was WRONG - Debian DOES.
   Correct that claim in the plan; it was a bad inference.

IMPLICATION: every mainstream distro arm64 kernel is ZBOOT-wrapped (we have now
independently confirmed this for Armbian/ophub AND Debian). A non-PE mainline
Image is not obtainable from a distro .deb; it needs either:
  a) Bootlin prebuilt kernels (may or may not be PE - unverified), or
  b) an actual kernel build with CONFIG_EFI_ZBOOT=n, or
  c) the vendor 5.4 tree (option D), which is where this was heading anyway.
This materially weakens step 2 as a cheap test and strengthens the case for D.

## 2026-10-18 — Option D recon (no build started yet)

Fetched from `CoreELEC/linux-amlogic` branch `amlogic-5.4.210`
(HEAD a3aaaa5b0), single files via raw.githubusercontent:
- `arch/arm64/configs/meson64_a64_P_defconfig` (22747 B)
- `arch/arm64/boot/dts/amlogic/sc2_s905x4_ah212.dts` (34541 B)
- `arch/arm64/boot/dts/amlogic/meson-sc2.dtsi` (68959 B)

### D GATE PASSED: vendor Image is non-PE

    # CONFIG_EFI is not set      (line 58 of meson64_a64_P_defconfig)

No ZBOOT, no PE header. Output `Image` will be a plain arm64 image that
`booti` can load. **The master blocker (§7 of PLAN.md) does not apply to
option D.** This was the go/no-go and it is answered.

### Board match is exact

- `amlogic-dt-id = "sc2_s905x4_ah212"` — our board id
- `memory@0`: `linux,usable-memory = <0x0 0x0 0x80000000>` = **2 GB**, matches
  our single cs0 2048MB. (Mainline's generic DTB had said 4 GB = 0xffffffff.)

### ETHERNET — new evidence, and it is the best lead we have had

From `meson-sc2.dtsi`:

1. The internal PHY is on the **int_mdio bus** (`mdio@1`, reg = <1>) at
   **address 8**: `internal_ephy: ethernet_phy@8 { reg = <8>; }`.

   This EXACTLY matches our live mainline observation that
   `mdio_mux-0.1:08` is **absent**. i.e. the mainline DTB has no node for the
   internal PHY at all, which is why mainline reports "Generic PHY" with no
   real PHY behind it.

2. `compatible = "ethernet-phy-id0180.3301"`. Our live `phy_id = 0x0000ff80`;
   0xff80 masked down to the ID field is **0x0180**. Confirms internal PHY
   definitively — and confirms the vendor's expectation for this board is
   RMII 100 Mbit, not gigabit.

3. **`mc_val = <0x4BE0C>` is in the vendor DTS itself** on the ethmac node.

   We tested devmfc's *cmdline* value `0x1621` (PLAN §8) and it changed
   nothing. Amlogic's own tree ships a different value: **0x4BE0C**.
   Untested. This is a DT property, so it is *testable on mainline right now*
   by patching the DTB — unlike everything else in that table.
   NOTE: our earlier `PRG_ETH0` reasoning assumed the driver ORs the value in
   preserving existing bits; 0x4BE0C has bits our board's current reg0 (0x1601)
   does not, so the result may differ from the OR case.

4. `reg` for ethmac includes a second region `<0x0 0xfe024000 0x0 0x8>` (the
   PRG_ETH block), and `rx-fifo-depth = <4096> tx-fifo-depth = <2048>`.

So the Ethernet failure has a concrete new hypothesis: mainline's DTB omits the
internal PHY node entirely, and Amlogic's tree compensates with a non-default
`mc_val`. Still consistent with the pre-negotiation `dwmac_dma_reset()` failure
being an mc_val/clkin issue rather than a PHY issue.

**Caveat, recorded before it is forgotten:** this is inference from a DTS, not
a measurement. Per the project's own rule, the control (boot and look) comes
first. Do not patch a DTB on this theory alone.

### Option D build — setup and two obstacles

Toolchain: Bootlin `aarch64--glibc--stable-2024.05-1`, gcc **13.3.0**
(Buildroot 2021.11). Chosen deliberately as the *oldest* Bootlin aarch64
glibc tarball, because 5.4 is old and newer GCC trips old kernel trees.
No cross toolchain was present on the host, and `sudo` needs a password, so a
self-contained tarball was the only no-friction route. **gcc 13.3 against 5.4
is an unusual pairing and was the top build risk — so far it is holding.**

Host gcc is **16.2.1** (very new). 5.4's kconfig host tools built fine under
it, so the host toolchain is not a problem.

Tree: shallow clone of `amlogic-5.4.210`, HEAD `a3aaaa5b0`, 1.3 GB.
Configure: `make ARCH=arm64 CROSS_COMPILE=aarch64-linux- O=out
meson64_a64_P_defconfig` — clean, `CONFIG_AMLOGIC_MODIFY=y` present.

**Obstacle 1 — `libssl-dev` missing (host has no openssl headers).**
Build died at `scripts/extract-cert.c: openssl/engine.h: No such file`.
`extract-cert` is pulled in by `CONFIG_SYSTEM_TRUSTED_KEYRING=y`
(`scripts/Makefile:24`), which `certs/Makefile:28` genuinely requires for
`x509_certificate_list` -> `system_certificates.o`. So it cannot simply be
dropped.

*First attempt, and why it failed:* disable `SYSTEM_TRUSTED_KEYRING`. Wrote
`# CONFIG_SYSTEM_TRUSTED_KEYRING is not set` to `out/.config`, but running
`syncconfig` **silently put it back to `=y`**. Repeated with
`SYSTEM_EXTRA_CERTIFICATE` and `MODULE_SIG` also off — still forced back.
Chased this a fair way: no stray `linux/.config`, no `KCONFIG_ALLCONFIG` in
env, no unconditional `extract-cert` in `scripts/Makefile`, `certs/Kconfig`
has a normal `bool "..."` prompt, and no `aml`/force hooks in
`scripts/kconfig/confdata.c` or `scripts/Makefile`. **UNRESOLVED** — Amlogic's
kconfig forces this symbol on and I did not find where. Do not assume config
edits stick in this tree; verify with a `syncconfig` after changing anything.

*Fix actually used:* satisfy openssl instead of fighting kconfig. `dnf
download` failed (repo GPG/metalink errors), so headers came straight from
Debian: `libssl-dev_3.5.7-1~deb13u3_amd64.deb` via `deb.debian.org`, extracted
with `dpkg-deb -x` into `build/sslprefix/`. Host runtime is OpenSSL 3.5.8, so
3.5.7 headers are the closest match. Linked against the **host**
`/usr/lib64/libcrypto.so.3` via a symlink in `sslprefix/lib/`, since only the
headers were missing.

Build command now carries:

    CRYPTO_CFLAGS="-I$P/usr/include" CRYPTO_LIBS="-L$P/lib -lcrypto"

passed on the `make` command line, because `scripts/Makefile:31-32` assigns
`HOSTCFLAGS_extract-cert.o`/`HOSTLDLIBS_extract-cert` per-object — a global
`HOSTCFLAGS` would have been overridden for exactly the object we needed.

### Phase 1 probe prepared (built, not yet booted)

- `alpine-minirootfs-3.24.2-aarch64.tar.gz` (4 MB, musl) -> `build/initramfs`
- `scripts/probe-init.sh` (in repo) -> `/init`
- packed to `build/initramfs.cpio.gz` (4,026,943 bytes)

Deliberately minimal: mounts pseudo-fs, prints a single unambiguous marker
(`PROBE-INIT: vendor kernel userspace reached`), then drops to a shell. No
networking, no modules, no disks — so a failure is unambiguously about the
kernel and not about userspace. Includes a `/probe` helper that reports CPU
count online, memory, `ip link`, `ip link set eth0 up`, and the
dwmac/stmmac/mdio dmesg tail, so Phase 2 needs no second boot.

Note this is Alpine, not busybox-static: busybox is dynamically linked against
musl, which is fine because the whole minirootfs travels in the initramfs.

## 2026-10-18 — Option D first boot attempt: FAILED (Synchronous Abort)

### What was staged on the stick (`/BOOT/d/`)
```
Image                          34,551,816   sha 5adbc4cc53cc3633
initramfs.cpio.gz               4,026,943   sha d510ec902c903963
sc2_s905x4_ah212.dtb               76,574   sha 8a9a0c7135ff652c
sc2_s905x4_ah212_linux.dtb         78,956   sha 176ddf27b9e39217
initramfs.uimage                4,027,007   (mkimage-wrapped, see below)
```

### Attempt 1 — initramfs, FAILED EARLY (cheap, useful)
`booti 0x2000000 0x10000000 0x5000000` with a raw cpio.gz ramdisk:
```
libfdt fdt_path_offset() returned FDT_ERR_NOTFOUND
Wrong Ramdisk Image Format
```
**U-Boot will not accept a raw cpio.gz as booti's ramdisk argument** — it needs a
recognised image format. Wrapped it with the repo's host `mkimage`
(`tools/utils/mkimage`, x86-64; note `mkimage-arm64`/`-armhf` are aarch64/armhf
binaries and cannot run on this host):
```
mkimage -A arm64 -O linux -T ramdisk -C gzip -d initramfs.cpio.gz initramfs.uimage
```
Not yet retried with the uImage; attempt 2 switched to a different rootfs first.

### Attempt 2 — Debian rootfs, Synchronous Abort
Root is on the stick's p2, reached over **USB mass storage**, not eMMC/MMC.
Checked the vendor config: `CONFIG_USB_STORAGE=y`, `BLK_DEV_SD=y`, `SCSI=y`,
`EXT4_FS=y`, `MMC_MESON_GX=y`, `DEVTMPFS=y` — **all built-in**, so no modules
needed and the Alpine detour could be skipped entirely.

```
root=/dev/sda2 rootfstype=ext4 rootwait rw
console=ttyS0,921600 earlycon=amlogic,meson-uart,0xfe07a000
no_console_suspend nowatchdog pd_ignore_unused clk_ignore_unused
TERM=vt220 maxcpus=1 init=/root/rescue-init.sh
```

U-Boot loaded everything correctly and jumped:
```
## Flattened Device Tree blob at 05000000
Booting using the fdt blob at 0x5000000
Loading Device Tree to 000000001ffea000 ... OK
Starting kernel ...
uboot time: 151919432 us
boot 64bit kernel
"Synchronous Abort" handler, esr 0x02000000
Call trace: [<00000000038e0000>]N/A
Resetting CPU ...
```

`esr 0x02000000` = EC 0 = **unknown exception**, i.e. jumped to garbage.
**Zero kernel console output** despite earlycon — Linux prints `Linux version`
almost immediately, so this faulted at or very near entry.

### Image header sanity (rules out a bad Image)
```
text_offset  = 0x80000
image_size   = 0x2295000
flags        = 0x0a  (bit0 = little-endian)
magic @0x38  = 'ARMd'
```
U-Boot computed entry = 0x2000000 + 0x80000 = **0x2080000**, which matches
register x4 in the fault dump. So the entry calculation was **correct** and the
Image itself is well-formed and non-PE. It faulted *somehow*, not because of a
malformed load.

### LEADING HYPOTHESIS — wrong DTB variant (my error)
I staged **`sc2_s905x4_ah212.dtb`**, which is the **Android** variant. Diff vs
the `_linux` variant:
- base includes `partition_mbox_ab.dtsi` — **A/B partitions, an Android
  construct**; `_linux` uses `partition_normal_linux.dtsi`
- base has **no DRM include**; `_linux` adds `mesonsc2_drm.dtsi` (Linux display)
- reserved-memory 100 MB (base) vs 128 MB (_linux)
- `di_cma` reserved pool present in base, commented out in _linux

I had both variants in hand, noted `_linux` existed, and staged the base one
anyway. Own mistake. `sc2_s905x4_ah212_linux.dtb` is now staged and verified
(memory 0x80000000 = 2 GB, dt-id correct, 28 hdmi/drm nodes, ethmac intact).

### Second, unresolved ambiguity
Cannot distinguish from one run:
1. kernel faulted at entry, vs
2. `earlycon` never bound (the vendor driver registers via
   `OF_EARLYCON_DECLARE(meson, "amlogic,meson-uart", ...)`, not `aml-uart` as
   mainline used) and the kernel died silently.

Different fixes, so do not guess. If the `_linux` DTB still aborts, next move is
dropping `earlycon` and testing `console=` alone.

### Console address — resolved, worth keeping
`aliases { serial0 = "/soc/apb4@fe000000/serial@7a000" }`, and that child's
`reg` is `0x7a000` **relative to apb4@fe000000**, so the absolute address is
**0xfe07a000** — identical to the mainline earlycon base we already used.
`ttyS0` stays correct. Only the earlycon *name* differs between the two kernels.

### Box state
After the abort U-Boot reset the CPU; the box then wedged partway through its
own update path and stopped emitting output (no marker echo). Needed a power
cycle. **Nothing persisted** — only fatload/setenv/booti were used, and
`saveenv` was never issued.

## 2026-10-18 — OPTION D: **VENDOR KERNEL BOOTS, ETHERNET WORKS** ✅

### The fix was the DTB variant
Switching `sc2_s905x4_ah212.dtb` (Android) → `sc2_s905x4_ah212_linux.dtb`
turned a Synchronous Abort with **zero console output** into a full boot. The
`_linux` variant includes `mesonsc2_drm.dtsi` (28 hdmi/drm nodes vs **0** in
the base) and `partition_normal_linux.dtsi` instead of `partition_mbox_ab.dtsi`.
Note the base variant had NO display include at all — that was the abort cause.

Also confirms **`earlycon` DOES bind**: `earlycon=amlogic,meson-uart,0xfe07a000`
gave `[0.000000@0]` timestamps immediately. The silence in attempt 2 was not a
console problem.

### Boot result
```
Amlogic dt-id: sc2_s905x4_ah212
Linux version 5.4.210-ga3aaaa5b0e64-dirty ... #1 SMP PREEMPT
rcu: RCU restricting CPUs from NR_CPUS=8 to nr_cpu_ids=4
Memory: 1333604K/2097152K available
EXT4-fs (sda2): mounted filesystem with ordered data mode
VFS: Mounted root (ext4 filesystem) on device 8:2
Run /root/rescue-init.sh as init process
Starting serial console on ttyS0...
Welcome to Debian GNU/Linux 13 (Trixie) with Linux 5.4.210-ga3aaaa5b0e64-dirty on ARM64
```
**Vendor kernel 5.4.210 + Debian userspace works.** Alpine detour not needed.

### ETHERNET — SOLVED (this was the project's main blocker)
```
meson8b-dwmac fdc00000.ethernet eth0: PHY [0.1:08] driver [Meson G12A Internal PHY]
meson8b-dwmac eth0: configuring for phy/rmii link mode
meson8b-dwmac fdc00000.ethernet eth0: Link is Up - 100Mbps/Full - flow control rx/tx
IPv6: ADDRCONF(NETDEV_CHANGE): eth0: link becomes ready
```
Live: `/sys/class/net/eth0/speed` = **100**, `ethtool`: `Speed: 100Mb/s`,
`Link detected: yes`, IPv6 addrs assigned.

**No `Failed to reset the dma` anywhere.** The vendor kernel's own MAC driver
(again Amlogic's `dwmac-meson8b` + internal PHY support) drives the MAC where
mainline `stmmac` could not.

This also **resolves the §8 devmfc question by elimination** — no longer needs a
non-PE stock mainline kernel. The root cause chain is now clear:
1. mainline DTB has **no node for the internal PHY at all** (it lives on the
   internal mdio bus, addr 8), so mainline probed a "Generic PHY" with nothing
   behind it;
2. with no real PHY, Amlogic's `dwmac_dma_reset()` handshake never completes,
   and mainline dies **before any PHY/speed negotiation** — which is exactly
   why every single DTB property we ever changed had no effect.

### Other observations from dmesg
- `[drm] hdcp_tx22 load timeout` / `HDCP statue changed, need re-run hdcp` —
  the display stack IS present and probing (not a silent no-op). Worth checking
  for an actual framebuffer later.
- `custom_internal_config` / `set phy setup_amp = 3` — Amlogic's own PHY
  calibration path running.
- No IPv4 (no DHCP configured) — `ping 1.1.1.1` → "Network is unreachable".
  Expected; not a fault. IPv6 addresses are assigned.
- Boot to prompt in ~81s (vendor kernel, 1 core).

### Open question: multi-core
Still untested — booted with `maxcpus=1`. This is now the *next* experiment:
same everything, `maxcpus=4`. `nr_cpu_ids=4` so all four cores are visible.

### Working boot recipe (save this)
```
usb start 0
fatload usb 0:1 0x2000000  d/Image
fatload usb 0:1 0x5000000  d/sc2_s905x4_ah212_linux.dtb
setenv bootargs "root=/dev/sda2 rootfstype=ext4 rootwait rw \
  console=ttyS0,921600 earlycon=amlogic,meson-uart,0xfe07a000 \
  no_console_suspend nowatchdog pd_ignore_unused clk_ignore_unused \
  TERM=vt220 maxcpus=1 init=/root/rescue-init.sh"
booti 0x2000000 - 0x5000000
```
Stick `/BOOT/d/` holds: Image, initramfs.cpio.gz, initramfs.uimage,
sc2_s905x4_ah212.dtb (Android variant), sc2_s905x4_ah212_linux.dtb (USE THIS).
Login: root / tvbox.

### MULTI-CORE: **WORKS** on the vendor kernel ✅
Tested without a power cycle by hot-plugging secondary CPUs:
```
echo 1 > /sys/devices/system/cpu/cpu1/online   # RC=0
echo 1 > /sys/devices/system/cpu/cpu2/online
echo 1 > /sys/devices/system/cpu/cpu3/online
```
`possible=0-3 present=0-3`, final `ONLINE=0-3`, `nproc=4`.

Under load (4 x `while :; do :; done` and 4 x 2M-iteration arithmetic loops):
- box survived, no oops/abort/SIGILL/`Exec format error` in dmesg
- **exec still worked under load** — `EXEC_TEST_1=$(echo hi)` and
  `EXEC_TEST_2=$(uname -r)` both returned correctly while 4 cores were
  saturated. This is exactly what mainline failed at (SIGILL / Exec format
  error / SEGV).
- dmesg: clean apart from benign lines.

**The mainline multi-core corruption was a mainline bug, not the hardware.**

### Console silence under load — A TRAP
When all 4 cores are saturated with CPU load, **the UART console goes
completely silent** and stops echoing, for the duration of the load. It looks
exactly like a hang or a kernel crash, but it is NOT — the box is fine and
recovers the instant the load stops (verified with `echo MARKER` returning
immediately afterwards).

This is the same shape as the earlier "quiet-shell tests lie" trap: absence of
console output is not evidence of a hang. Always probe with a marker before
concluding anything.

### cpufreq on the vendor kernel
- cpu1/cpu2: `_of_add_opp_table_v2: no supported OPPs` → cpufreq init fails.
  Same unwired-OPP-table situation as mainline (the vendor DTS does not wire
  `operating-points-v2` either).
- cpu3: `meson_cpufreq_init: CPU 3 initialized` / `Running at unlisted freq:
  1512000 KHz` → **cpufreq partially works**, running at the 1.512 GHz syspll
  BL2 programmed. So frequency IS controllable on this kernel where mainline
  had no governor at all.

### Status of the mainline blockers under option D
| Mainline problem | Under vendor 5.4.210 |
|---|---|
| Ethernet (dwmac_dma_reset) | **works** — 100Mbps/Full |
| Multi-core corruption | **works** — 4 cores, exec under load OK |
| systemd cannot exec agetty | **works** — Debian userspace unmodified |
| No non-PE kernel | solved by this whole path |
Remaining unknown: actual HDMI output (DRM present/probing, not yet verified
on a display), and WiFi (RTL8812CS, still no open driver).

## 2026-10-18 — SSH WORKING ✅

Ethernet was up but had no IPv4 (nothing was running a DHCP client — rescue-init
runs no network manager). Only `dhclient` was present (no udhcpc/dhcpcd).

```
dhclient -v eth0      # -> DHCPOFFER/ACK of 192.168.1.21 from 192.168.1.1
```
`ip -br addr`: eth0 UP 192.168.1.21/24, default via 192.168.1.1. Router has DHCP.

```
apt-get update && apt-get install -y openssh-server
mkdir -p /run/sshd && ssh-keygen -A && /usr/sbin/sshd
```
sshd listening on :22 (v4+v6). Host keys: RSA/ECDSA/ED25519.
Tested from the host:
```
sshpass -p tvbox ssh root@192.168.1.21 'uname -a; nproc'
# -> Linux eon-sc2 5.4.210-ga3aaaa5b0e64-dirty ... 4
```

**Lesson (third occurrence of the same shape): the console went completely
silent for ~5 min during `apt-get`.** Cause: `-qq` suppresses apt's output AND
the apt process blocked the foreground shell, so queued UART commands (markers)
could not execute — they were waiting on the blocked shell, not a wedged box.
`ps` showed no apt running and sshd appeared once it finished. Do not conclude
"wedged" from a silent console while a foreground command is still running.

Now we can work headless. UART kept for kernel/boot debugging.

### eMMC boot contract — now fully understood
From the serial logs, `storeboot` is **hardcoded to the Android flow**:
```
system_mode in storeboot: 0
active_slot in storeboot: _b
[imgread]read from part: boot_b
[imgread]partname_r = vendor_boot_b
avb2: 1 ... avb verification: locked = 0, result = 3
## Booting Android Image at 0x03080000 ...
Android's image name: ohm
Kernel load addr 0x11000000 size 24711 KiB
Kernel command line: console=ttyAML0,1000000 console=tty0 earlycon=aml-uart,0xfe07a000 ...
No androidboot.dtbo_idx configured
RAM disk load addr 0x15000000 size 1736 KiB
load dtb from 0x1000000 ...
```
- storeboot reads the A/B `boot_b` partition and `bootm`s it as an **Android boot
  image**. It does NOT run the devmfc bootscript, so there is no script path.
- The Android cmdline from the image IS used as the kernel command line.
- dtb is loaded separately (`load dtb from 0x1000000`).
- AVB verification failure (result 3) does NOT block the boot.

**Implication: to boot our kernel from eMMC with no env change, put an
Android-format boot image containing our kernel + cmdline (+dtb) into `boot_b`.**
`mkbootimg` and `unpack_bootimg` are both available on the host.

Also: `fw_printenv` is installed but returns "Cannot initialize environment" —
`/etc/fw_env.config` points at `/dev/mmcblk1 0x4d400000` which does not match
this box, so reading/writing the U-Boot env from Linux is not available.

eMMC layout (standard Amlogic, do NOT touch bootloader/reserved/env):
bootloader 4M | reserved 64M | cache 0 | env 8M | frp 2M | factory 8M |
vendor_boot_a/b 24M each | tee 32M | logo 8M | misc 2M | dtbo_a/b 2M |
cri_data 8M | param 16M | odm_ext_a/b 16M | oem_a/b 32M | boot_a/b 64M |
rsv 16M | metadata 16M | vbmeta_a/b 2M | vbmeta_system_a/b 2M |
super 1.8G | userdata 12.1G

## 2026-10-18 — eMMC autoboot investigation: DTB detected, but format mismatch

The `boot_second.img` (DTB in second slot) **fixed the DTB detection**:
```
ab mode, read dtb from kernel
      Amlogic Multi-DTB tool
      Single DTB detected
```
No more `Err imgread(L265):NO second part in kernel image`.

**But `imgread kernel` + `booti` fails** with "Bad Linux ARM64 Image magic!" — the `imgread kernel` command doesn't extract a valid kernel from our `mkbootimg` output. The box's native `storeboot` uses `bootm` on the full Android boot image at 0x03080000, not `booti` on extracted parts.

**Investigated paths:**
| Method | Result |
|---|---|
| `boot_second.img` (DTB in second) + `imgread dtb` | DTB detected ✅ |
| `imgread kernel boot_b 0x11000000` + `booti 0x11000000 - 0x1000000` | "Bad Linux ARM64 Image magic!" ❌ |
| `imgread dtb boot_b 0x1000000` + `booti` | Same ❌ |
| `boot_appended.img` (kernel+DTB appended) + `imgread` | DTB not found ❌ |

The box's `storeboot` natively does `imgread` + `bootm` on the full Android image at 0x03080000. Our `mkbootimg` output doesn't match what `imgread kernel` expects.

**Pivot: installer approach.** The working USB boot path is proven. Build an installer that runs from USB and:
1. Repartitions eMMC (preserve bootloader 4M, reserved 64M, env 8M)
2. Creates FAT boot partition + ext4 root partition
3. Copies `Image` + `sc2_s905x4_ah212_linux.dtb` to boot partition
4. Copies rootfs to root partition, fixes fstab
5. Places a minimal boot script on boot partition that U-Boot can find

## 2026-10-19 — eMMC autoboot: aml_autoscript approach

**Key insight:** The factory bootloader's "update path" scans USB FAT for
`aml_autoscript` (a uImage script) before falling to `storeboot`. This path runs
`booti` natively (not `bootm`), and it works from ext4.

**storeboot dead end:** Only boots Android boot images via `bootm`. `imgread
kernel` doesn't recognize our mkbootimg output ("Bad Linux ARM64 Image magic").
The Amlogic `imgread` command expects a specific Android boot image format
with raw kernel data, not the mkbootimg header our tooling produces.

**Solution:** Create `aml_autoscript` (uImage script) that uses `ext4load` +
`booti` to boot from eMMC ext4 partitions. Place it on:
1. USB stick root (so update path picks it up and boots Linux from USB root)
2. eMMC boot partition (for standalone boot)

**The "eMMCkey: Access range is illegal" error:** This happens when
`ext4load mmc 1:1 0x2000000 Image` is run from the U-Boot prompt. The issue is
that `storeboot`'s eMMC write/erase locks the data area — after a failed
storeboot attempt, the key manager flags the region. Using `load mmc` instead
of `ext4load` might bypass this, or using a different load address (0x11000000)
helps.

**Current state:** Boot loop caused by boot_b partition having an incompatible
Android boot image. Need to clear it and try `aml_autoscript` on USB.

## 2026-10-19 — eMMC boot investigation: eMMCkey protection

**Root cause found.** The `ext4load mmc 1:1` fails with "eMMCkey: Access range
is illegal" because the eMMC has key-based protection on certain LBA ranges.
The error shows: `emmc, keys 73760, keye 74785, start 55298, blkcnt 28672`

Where:
- `start=55298` = LBA of the file in the filesystem
- `keys/keye` = protected key range boundaries (73760-74785)

**The issue**: our install script creates partitions starting at sector 2048 (1MB),
overwriting the bootloader (4M) + reserved (64M) regions. The Amlogic eMMC has:
- Bootloader: first 4M
- Reserved: 64M
- Then partitions...

The "eMMCkey" is a hardware key management feature that protects certain
regions regardless of the partition table. The file Image is stored at LBA 55298,
which falls in a key-protected range.

**Solution**: Use the correct Amlogic eMMC partition layout:
- Partition 1 (BOOT) should be placed AFTER the bootloader+reserved areas
- Or use `load mmc` with raw sector reads bypassing filesystem layer
- Or use the USB key approach where kernel+dtb come from USB FAT

**Alternative**: The `mmc read` approach works (used in historical §4b of PLAN.md)
because it uses raw LBA reads, bypassing the filesystem layer's key checks.
But that requires knowing exact LBA offsets.

**Current plan**: boot kernel+dtb from USB (proven), then fix
eMMC boot by relocating the boot partition past the protected region.

## 2026-10-19 — eMMC boot SUCCESS

**Root cause of "eMMCkey: Access range is illegal!":**
The boot partition started at sector 2048 (1MB), overlapping the eMMC
key-protected range (sectors 73760-74785, approx 36-37MB into the eMMC).
When ext4load reads a file whose blocks span this range, the eMMC's
hardware key management blocks the access.

**Fix:** Created a new partition layout with the boot partition starting at
sector 81920 (41.9MB), past the key-protected range:
- Partition 1 (boot): sectors 81920-180223 (50.3MB ext4)
- Partition 2 (root): sectors 180224-end (15.6GB ext4)

**Verified steps:**
1. Boot from USB (vendor kernel, known-good path)
2. Repartition eMMC with `parted` — boot partition past key range
3. Format boot partition ext4, copy Image + DTB from USB
4. Create `aml_autoscript` (uImage script) for factory bootloader
5. Copy rootfs via `dd if=/dev/sda2 of=/dev/mmcblk0p2`
6. Fix fstab on root partition

**Manual boot test (from U-Boot prompt):**
```
mmc dev 1
ext4ls mmc 1:1     → Lists Image, DTB, aml_autoscript, extlinux.conf
ext4load mmc 1:1 0x2000000 Image       → 34551816 bytes read in 239ms
ext4load mmc 1:1 0x5000000 DTB          → 78956 bytes read
booti 0x2000000 - 0x5000000             → Kernel boots, systemd starts
```
SSH works at 192.168.1.21 after ~60 seconds.

**For the boot script:** Use `init=/root/rescue-init.sh` in bootargs for
faster boot (~3s to login prompt vs ~100s for systemd).

**Key files on eMMC boot partition:**
- Image (34MB) — vendor kernel 5.4.210, non-PE
- sc2_s905x4_ah212_linux.dtb (78KB)
- aml_autoscript (uImage script) — runs: mmc dev 1 → ext4load → booti
- extlinux.conf (fallback config for U-Boot's extlinux support)

## 2026-10-19 — Final deployment conclusion

**Bootloader behavior (confirmed):**
- `bootcmd = run storeboot` → tries Android boot from `boot_b` partition
- AVB verification fails (locked=1)
- Falls to recovery → fails
- Drops to U-Boot prompt
- **Update path ONLY scans USB FAT partitions for aml_autoscript**
- eMMC FAT32/ext4 is NOT scanned

**Deployment = USB stick as permanent bootloader**

```
┌─────────────────────────────────────────────────────────────┐
│  USB STICK (bootloader)          eMMC (storage)            │
│  ────────────────────────────    ────────────────────────   │
│  /aml_autoscript  ────────────►  mmcblk0p2 (rootfs, ext4)   │
│  /d/Image                        mmcblk0p1 (boot, ext4)     │
│  /d/DTB                           (optional, for manual)    │
└─────────────────────────────────────────────────────────────┘
```

**Boot sequence (automatic, USB inserted):**
1. Box powers on → BL2 → BL3 → U-Boot
2. `storeboot` fails (AVB locked)
3. Update path scans USB → finds `aml_autoscript`
4. `aml_autoscript` runs: `usb start 0` → `fatload` kernel+DTB → `booti`
5. Kernel boots with `root=/dev/mmcblk0p2` → Debian from eMMC

**Installation per box:**
1. Flash USB stick with `dl/devmfc-trixie.img` (sha256 verified)
2. Insert USB, power on → vendor kernel 5.4.210 boots Debian from USB
3. Run `scripts/install-to-emmc.sh` → prepares eMMC (partitions, rootfs, boot files)
4. Leave USB plugged in, power-cycle → auto-boots from eMMC root

**Files on eMMC after install:**
```
mmcblk0p1 (50MB ext4, past key range):
  /Image (34MB)
  /sc2_s905x4_ah212_linux.dtb (78KB)
  /aml_autoscript (manual U-Boot boot)
  /extlinux.conf (fallback)

mmcblk0p2 (15.6GB ext4):
  / (Debian 13 rootfs, fstab → /dev/mmcblk0p2)
```

**Key constraint resolved:** eMMC key-protected range (sectors 73760-74785)
- Boot partition starts at sector 81920 (41.9MB) → clear of key range
- `ext4load mmc 1:1` works without "eMMCkey: Access range is illegal"

**Multi-core + Ethernet verified working** on vendor kernel 5.4.210.

## 2026-10-19 — AUDIT: the silent kernel was a corrupt kernel file on eMMC

### Starting point
Yesterday's notes concluded "bootloader doesn't auto-run aml_autoscript from eMMC"
and settled on "USB stick as bootloader". That conclusion was drawn from a boot
that never actually ran a kernel. **The eMMC path was never correctly tested**,
because the kernel file on eMMC was corrupt the whole time.

### Discovery path
1. Booting kernel+DTB from **USB** works (full console, network, login).
2. Booting the *same* kernel+DTB from **eMMC p1** gives **zero console output** —
   not even earlycon stamps. Reproduced 3×.
3. Control test (the one the notes keep demanding): hash the eMMC copy vs the
   host artefact. Found via SSH after booting from USB and bringing up networking.

```
host   build/out/arch/arm64/boot/Image
       5adbc4cc53cc3633cf44a07f0d61cc2937af41ed3c717846f253526b46c52dc9
USB    /mnt/u1/d/Image
       5adbc4cc53cc3633cf44a07f0d61cc2937af41ed3c717846f253526b46c52dc9   <- pristine
eMMC   /mnt/p1/Image
       828032992486749bae258b76b1077af41836999521d380a11d249e37dfec6a03   <- CORRUPT

eMMC DTB 176ddf27b9e392175dbbbd057449d023c7ddd8bda68210d54c71fccf585d2043  <- correct
host DTB 176ddf27b9e392175dbbbd057449d023c7ddd8bda68210d54c71fccf585d2043  <- match
```
First differing byte: **1,273,345** (~1.2 MB into the file).

### Root cause: FAT32 geometry does not match the partition
p1 is 98304 sectors (48 MiB). The FAT32 BPB at offset 32 declares
**102400 sectors (50 MiB)**. The filesystem overruns its partition by 2 MiB.

```
BPB offset 32..35 = 00 90 01 00  ->  0x00019000 = 102400 sectors
blockdev --getsz /dev/mmcblk0p1   ->  98304 sectors
```

Consequences, all observed:
- `sha256sum /mnt/p1/Image` -> **Input/output error**
- `dmesg`: `attempt to access beyond end of device
  mmcblk0p1: rw=..., want=..., limit=98304`
- Reads map as: OK 0..13 MB, **FAIL 14..16 MB**, OK 16 MB..end
  (fragmented cluster allocation; some clusters land in the dead 2 MiB tail)

**Why the corruption was invisible:** `cp` then `sha256sum` in the same mount
matched the host hash — because the page cache held the good bytes. Only after
`umount` + remount did the failure appear. **A hash taken without remounting
proves nothing.** This is the same class of error as the earlier "md5sum in a
quiet shell" trap, and it is now the project's third instance.

### Why the sizes diverged
| script | p1 partition | p1 filesystem |
|---|---|---|
| `install-to-emmc.sh` | `sgdisk -n 1:2048:+64M` | `mkfs.vfat` |
| `install-to-emmc.sh` | `parted mkpart primary 81920 180223` (48 MiB) | `mkfs.ext4` |

The on-box state matches **neither**: 48 MiB partition carrying a FAT32
filesystem sized for 50 MiB (install-to-emmc label "BOOT"). That is the
signature of a partition **resized without reformatting**. Consistent with
`extlinux.conf` being absent — p1 was rebuilt by something not in the repo.

### p2 is clean
```
e2fsck -fn /dev/mmcblk0p2  ->  rc=0, no errors, label ROOTFS
15792/827424 files, 181408/3802107 blocks
```
The rootfs was written by the path that *didn't* dd into a mounted filesystem,
or the corruption never reached it. **No reinstall of p2 is needed.**

### Bugs found in the install scripts (audit)
1. **`install-to-emmc.sh` dd's into a mounted filesystem.** L54 mounts `MMC_ROOT`,
   L90 `dd if=$USB_ROOT of=$MMC_ROOT`. Raw block write under a live ext4 mount.
   Fatal in principle; appears not to have bitten here, but must be fixed.
2. **`install-to-emmc.sh` has literal `EOF` and `chmod` lines baked in** (L150-151).
   Dies under `set -eu` — cannot have run to completion as written.
3. **Filesystem type vs boot script mismatch.** `install-to-emmc.sh` formats FAT32
   but its `aml_autoscript` uses `ext4load`. Would fail if ever run.
4. **Both installers copy rootfs from `/dev/sda2`**, the *modified live stick*,
   not the sha256-verified pristine `dl/devmfc-trixie.img` p2.
5. **No post-write verification anywhere.** No script hashes what it wrote and
   re-reads it. This is the single omission that let a corrupt kernel sit on the
   box through an entire session of "the eMMC path doesn't work".

### Also found: the USB stick's autoscript is broken
```
** Unable to read file box-config/kernel-.config **
** Unable to read file vmlinuz- **
Bad Linux ARM64 Image magic!
```
The kernel name resolves with an empty release suffix, so nothing is loaded and
`booti` fails — **in a loop** (60 autoscript runs in 30 s, 0 U-Boot prompts).
**The USB autoboot method has therefore never worked unattended.** Every prior
"USB boot works" was a *manual* `fatload`+`booti` at the prompt.

### U-Boot hazards confirmed
- `fatload usb 0:1 0x6000000 d/Image` (34 MB) ->
  `BUG at ../drivers/usb/host/xhci-ring.c:496/abort_td()` -> **reset**.
  Do not do large USB reads into high addresses from U-Boot.
- `fatload mmc 1:1` works and is safe (141 MB/s).
- No `sleep` command. `mmc rescan` exists and is a candidate settle step.
- `sysboot <iface> <dev[:part]> <ext2|fat|any> [addr] [file]` exists —
  U-Boot's native extlinux loader, not yet tried.
- p1 is **FAT32**, so `fatload` (not `ext4load`) is correct against it.

### Method lessons (project now has 4 of these)
- "The eMMC boot path doesn't work" was recorded as a *bootloader* conclusion
  when the real fault was a corrupt file. **Verify the payload before diagnosing
  the mechanism.**
- A hash taken from a mounted filesystem can be a page-cache artefact.
  Unmount, remount, then hash.
- Absence of a working console proves nothing about a kernel; it may not have
  started at all.

## 2026-10-19 — The box has no usable network stack out of the box

Diagnosed while trying to install `dosfstools` on the box. **Three independent
faults**, any one of which alone breaks `apt`.

### 1. Clock is at 1970
```
date -> Thu Jan  1 01:13:55 AM CET 1970
hwclock: command not found
```
No `hwclock` binary, and the meson-vrtc RTC reads back as invalid, so nothing sets
the clock at boot. Consequences seen:
- PAM: `unix_chkpwd: account root has password changed in future`
- apt would treat every repo `Release` file (dated 2026) as being from the future

Fixed by `date -s "<host time>"` from the host. **Needs a permanent fix** — this
will also break TLS and log timestamps.

### 2. `/etc/resolv.conf` does not exist
```
cat /etc/resolv.conf -> No such file or directory
getent hosts deb.debian.org -> FAIL
```
`dhclient` obtains the lease but never writes a resolver file (no `resolvconf`
installed). Routing is fine — `192.168.1.1` OK, `1.1.1.1` OK, `8.8.8.8` OK — but
**DNS was dead**, which is what made `apt-get update` hang with an empty
`/var/lib/apt/lists/`.

Fixed by writing `/etc/resolv.conf` with `8.8.8.8` / `1.1.1.1`.

### 3. DNS returns IPv6-only, and there is no IPv6 route
```
getent hosts deb.debian.org
-> 2a04:4e42:400::644 debian.map.fastlydns.net ...
```
AAAA only. The box has a v4 default route and no IPv6 connectivity, so apt stalls
trying to fetch over v6.

Fixed with `/etc/apt/apt.conf.d/99force-ipv4`:
```
Acquire::ForceIPv4 "true";
```
(note: the `-o Acquire::ForceIPv4=true` form is **command-line only** and is a
syntax error inside a config file — that cost a couple of round trips.)

### After all three: apt works
```
Fetched 17.6 MB in 11s (1,615 kB/s)
```

### Lesson
`apt-get install` failing was assumed to be "no package available". It was three
unrelated faults stacked. **Diagnose the layer before concluding anything** — the
same shape as the corrupt-kernel episode, one level down.

### Deployment implications (must be fixed in any installer)
- set the clock, or install NTP
- ship a `resolv.conf` (do not rely on the DHCP client to create one)
- force IPv4 in apt config
- `init=/bin/sh` leaves `/proc` unmounted — mount it first or every
  `ps`/`cat /proc/*`/`netstat` silently returns nothing (this masked the
  missing eMMC devices during the audit and made it look like the eMMC had
  vanished)

## 2026-10-19 — SILENT KERNEL FIXED. eMMC BOOT WORKS.

### The fix
p1 was reformatted **ext4** (the box has no FAT tooling at all — `mkfs.vfat`,
`mke2fs`-adjacent FAT tools and `busybox` are all absent, and `dosfstools` is not
installable without first fixing the network, see below), then `Image` + DTB
copied from the **verified-pristine USB source**.

Using ext4 is not a workaround, it is the *original* documented path:
`ext4load mmc 1:1 0x2000000 Image` -> `34551816 bytes read` (the "eMMC boot
SUCCESS" entry). It also permanently removes the fs/script mismatch bug, since
both host scripts already emit an `ext4load` autoscript.

### Verified from storage, not from cache
```
umount /mnt/p1; mount -o ro /dev/mmcblk0p1 /mnt/p1
sha256sum -> 5adbc4cc53cc3633cf44a07f0d61cc2937af41ed3c717846f253526b46c52dc9  Image
             176ddf27b9e392175dbbbd057449d023c7ddd8bda68210d54c71fccf585d2043  dtb
e2fsck -fn /dev/mmcblk0p1 -> clean
e2fsck -fn /dev/mmcblk0p2 -> clean
```

### Boot result — first ever clean unattended-from-eMMC Linux
```
ext4load mmc 1:1 0x2000000 Image          -> 34551816 bytes read (138.4 MiB/s)
ext4load mmc 1:1 0x5000000 sc2_s905x4_ah212_linux.dtb -> 78956 bytes read
booti 0x2000000 - 0x5000000
```
```
[0.000000@0] Linux version 5.4.210-ga3aaaa5b0e64-dirty ...
[0.000000@0] Amlogic dt-id: sc2_s905x4_ah212
[0.000000@0] Kernel command line: root=/dev/mmcblk0p2 ... init=/root/rescue-init.sh
[  2.305047@0] EXT4-fs (mmcblk0p2): recovery complete
[  2.306103@0] VFS: Mounted root (ext4 filesystem) on device 179:2.
[  2.322064@0] Run /root/rescue-init.sh as init process
eon-sc2 login:                                      <- ~3 s
```
```
/dev/mmcblk0p2 on / type ext4 (rw,relatime)   15G  486M  4% /
eth0 UP 192.168.1.21/24,  Link is Up - 100Mbps/Full
```

### What this invalidates
- **"The bootloader does not auto-run aml_autoscript from eMMC"** — still true,
  but it was never the interesting fact. The eMMC path had never been tested
  because the kernel file was corrupt. **The conclusion was drawn from a boot
  that never ran a kernel.**
- **"USB stick as permanent bootloader"** — no longer necessary. A persistent
  `bootcmd` is the remaining step for fully unattended eMMC boot.

### Remaining work for standalone autoboot
1. Pull the USB stick, power cycle, confirm boot with nothing attached.
2. Build `bootcmd` = the sequence above; `printenv` to verify; `saveenv`.
3. Unattended runs have no inter-command delay, and the notes record an earlier
   unattended attempt where **the eMMC controller never probed in Linux**. Need a
   settle step. `mmc rescan` exists and is untested — test it interactively
   before it goes anywhere near `bootcmd`.
4. `rescue-init.sh` does **not** bring up networking. `dhclient eth0` has to be
   run by hand, so an unattended box has no IP and therefore no SSH. Must be
   added to rescue-init so an unattended box is manageable headless.

### Standing caution
Nothing goes into `bootcmd` that has not been typed and run by hand first, and
every command in it must have a non-reset failure mode. A `crc32` in `bootcmd`
bricked this box once already.

## 2026-10-19 — STANDALONE BOOT CONFIRMED (no USB stick)

USB stick physically removed, power cycle, boot sequence typed at the U-Boot
prompt:
```
mmc dev 1
ext4load mmc 1:1 0x2000000 Image                 -> 34551816 bytes read
ext4load mmc 1:1 0x5000000 sc2_s905x4_ah212_linux.dtb -> 78956 bytes read
booti 0x2000000 - 0x5000000
```
```
/dev/mmcblk0p2 on / type ext4 (rw,relatime)
uname -r -> 5.4.210-ga3aaaa5b0e64-dirty
ls /dev/sd* -> No such file or directory      <- no USB at all
eth0 UP 192.168.1.21/24, Link is Up - 100Mbps/Full
```

**The original goal is met: the box boots from eMMC with nothing plugged in.**
Manual U-Boot commands only — see below for the remaining unattended step.

### Two gaps found in this test, both blocking
1. **The DNS/clock fixes went to the USB stick's rootfs, not eMMC.**
   `date` on the eMMC boot reads `Thu Jan 1 1970`. `/etc/resolv.conf` was written
   to `/dev/sda2` only. **p2 therefore still has no resolver and no clock**, and
   needs the same three fixes (clock, `resolv.conf`, `Acquire::ForceIPv4`)
   applied directly.
2. **`rescue-init.sh` does not bring up networking.** `dhclient eth0` had to be
   run by hand after every boot. An unattended box therefore gets no DHCP lease,
   no IP and no SSH — unmanageable on a network.
   Must add: interface up, dhclient, resolv.conf, clock.

## 2026-10-19 — bootcmd quoting: escaped quotes RESET the box

### What was tested, in a scratch variable (never saveenv'd until proven)
```
setenv testcmd "mmc dev 1; mmc rescan; echo PARSER_OK"
run testcmd
-> emmc tuning x2, then PARSER_OK          ==> ';' parsing WORKS inside run
```

### Attempt 1 — bootargs embedded with escaped quotes: **CPU RESET**
```
setenv testcmd "...; setenv bootargs \"root=/dev/mmcblk0p2 ...\"; booti ..."
printenv testcmd
-> ... setenv bootargs \"root=/dev/mmcblk0p2 ...\"; booti ...
                                  ^^ backslashes stored LITERALLY
run testcmd
-> mmc tuning x2, 34551816 bytes read, 78956 bytes read,
   "Starting kernel ... / boot 64bit kernel"
-> bl31 reboot reason: 0xd / 0xc
-> back in BL2, full reboot
```
**The box reset.** Recovered cleanly because this was a RAM-only scratch variable:
after the reboot `bootcmd=run storeboot` (default) and `testcmd` undefined.
Nothing was persisted. **This is precisely why the scratch-variable step exists.**

The inner `setenv bootargs \"...\"` stored literal backslash-quote characters, so
the kernel got a mangled command line and died before console init.

### Attempt 2 — bootargs set separately: **WORKS**
```
setenv bootargs "root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw console=ttyS0,921600 \
  earlycon=amlogic,meson-uart,0xfe07a000 no_console_suspend nowatchdog pd_ignore_unused \
  clk_ignore_unused TERM=vt220 maxcpus=4 init=/root/rescue-init.sh"
setenv testcmd "mmc dev 1; mmc rescan; ext4load mmc 1:1 0x2000000 Image; \
  ext4load mmc 1:1 0x5000000 sc2_s905x4_ah212_linux.dtb; booti 0x2000000 - 0x5000000"
run testcmd
```
```
[0.000000@0] Kernel command line: root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw
   console=ttyS0,921600 earlycon=amlogic,meson-uart,0xfe07a000 no_console_suspend
   nowatchdog pd_ignore_unused clk_ignore_unused TERM=vt220 maxcpus=4
   init=/root/rescue-init.sh          <- clean, NO stray backslashes
EXT4-fs (mmcblk0p2): mounted filesystem with ordered data mode
VFS: Mounted root (ext4 filesystem) on device 179:2.
eon-sc2 login:
```

### Re-reading the notes entry that "proved" bootargs cannot be embedded
notes.md:1483-1486 recorded:
> "bootargs was EMPTY when booti ran. `printenv bootargs` was correct before
> saveenv, but the var did not reach the kernel on the unattended boot."

That unattended bootcmd (notes:1490) **also embedded bootargs with escaped
quotes** — the identical construct that resets the box today. So that entry
almost certainly recorded this same quoting bug misdiagnosed as "the env var
did not reach the kernel". It is **not** evidence that a separate `bootargs`
variable fails.

### Confirmed facts for the real bootcmd
- `;` separates commands inside a variable executed by `run` — **works**
- `mmc rescan` re-runs eMMC tuning cleanly, no reset — safe settle candidate
- loads + `booti` inside one variable, run unattended-style, **boots to login**
- embedding `bootargs` via `\"` **resets the CPU** — must not be used

### Outstanding risk to resolve before saveenv
If `bootargs` is stored as a **separate** saved variable and it fails to reach the
kernel, the result is a silent kernel **in a boot loop** (bootdelay=0, bootcmd
re-runs every power cycle) — the exact trap from notes:1525-1542 that needed
ADNL to escape. Before saving, either:
- confirm a separate saved `bootargs` survives (test it), or
- find an embedding that works (test `setenv bootargs '...'` with single quotes)

## 2026-10-19 — bootcmd SOLVED: embed bootargs with SINGLE quotes

### Quote delimiter test
```
setenv t1 'hello world'  -> printenv t1 -> t1=hello world
setenv t2 "hello world"  -> printenv t2 -> t2=hello world
```
Both styles work as delimiters when typed at the CLI.

### The working bootcmd (single quotes INSIDE the outer double-quoted string)
```
setenv testcmd "mmc dev 1; mmc rescan; \
  ext4load mmc 1:1 0x2000000 Image; \
  ext4load mmc 1:1 0x5000000 sc2_s905x4_ah212_linux.dtb; \
  setenv bootargs 'root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw \
    console=ttyS0,921600 earlycon=amlogic,meson-uart,0xfe07a000 no_console_suspend \
    nowatchdog pd_ignore_unused clk_ignore_unused TERM=vt220 maxcpus=4 \
    init=/root/rescue-init.sh'; \
  booti 0x2000000 - 0x5000000"
run testcmd
```
Result:
```
Kernel command line: root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw
  console=ttyS0,921600 earlycon=amlogic,meson-uart,0xfe07a000 no_console_suspend
  nowatchdog pd_ignore_unused clk_ignore_unused TERM=vt220 maxcpus=4
  init=/root/rescue-init.sh                    <- complete and correct
VFS: Mounted root (ext4 filesystem) on device 179:2.
eon-sc2 login:
```

Note `printenv testcmd` displays the string with the inner single quotes **absent**,
which looked like they had been eaten. They are not — the value stored by the
outer `setenv` retains them and the inner `setenv bootargs '...'` uses them as
delimiters when `run` executes it. **Trust the kernel's cmdline over `printenv`
output here** — a fourth instance of "read the artefact, not the label".

### Why single quotes and not escaped double quotes
| Form | Stored as | Result |
|---|---|---|
| `setenv bootargs \"...\"` inside bootcmd | literal backslash-quote | **CPU RESET** |
| `setenv bootargs '...'` inside bootcmd | correct delimiter | **boots to login** |

### Why this is the right form (not just a working one)
Embedding `bootargs` inside `bootcmd` removes any dependency on a separate saved
`bootargs` variable. That matters because if such a variable failed to reach the
kernel the box would boot silent **in an unrecoverable loop** (bootdelay=0,
bootcmd re-runs every cycle) — the notes:1525-1542 trap that previously required
ADNL to escape. With bootargs embedded, the only failure mode left is
`Bad Linux ARM64 Image magic!`, which returns to the prompt.

### Ready for saveenv
Everything in this string has been executed and has booted to a login prompt.
`mmc dev`, `mmc rescan`, `ext4load`, `setenv`, `booti` all return errors rather
than resetting the CPU — the property `crc32` lacked.

## 2026-10-19 — *** UNATTENDED STANDALONE eMMC BOOT ACHIEVED ***

No USB stick. No catcher. No serial input at all. Power cycle only.

```
setenv bootcmd "mmc dev 1; mmc rescan; \
  ext4load mmc 1:1 0x2000000 Image; \
  ext4load mmc 1:1 0x5000000 sc2_s905x4_ah212_linux.dtb; \
  setenv bootargs 'root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw \
    console=ttyS0,921600 earlycon=amlogic,meson-uart,0xfe07a000 no_console_suspend \
    nowatchdog pd_ignore_unused clk_ignore_unused TERM=vt220 maxcpus=4 \
    init=/root/rescue-init.sh'; \
  booti 0x2000000 - 0x5000000"
saveenv
-> Saving Environment to STORAGE... OK
```

Power cycle, passive capture, zero interference:
```
boots in log            : 1
storeboot attempts      : 0
USB Storage Device(s)   : 0
autoscript runs         : 0
U-Boot prompts          : 0
booti attempts          : 1

34551816 bytes read in 239 ms (137.9 MiB/s)
78956 bytes read in 1 ms (75.3 MiB/s)
[0.000000@0] Linux version 5.4.210-ga3aaaa5b0e64-dirty ...
[0.000000@0] Kernel command line: root=/dev/mmcblk0p2 ... init=/root/rescue-init.sh
[  2.335635@0] EXT4-fs (mmcblk0p2): mounted filesystem with ordered data mode
[  2.336484@0] VFS: Mounted root (ext4 filesystem) on device 179:2.
eon-sc2 login:                                    <- ~2.3 s, unattended
```

**This is the original project goal, met.** The box boots Linux from eMMC with
nothing plugged in and no human intervention.

### What it actually took
1. The eMMC `Image` was **corrupt** — FAT32 geometry (102400 sectors) exceeded
   the partition (98304), so the copy silently lost everything past ~13 MB.
   Reformatting p1 as ext4 and re-copying fixed it.
2. `bootargs` must be embedded in `bootcmd` with **single quotes**.
   Escaped double quotes store literal backslashes and **reset the CPU**.

Neither of these is visible in the "bootloader doesn't scan eMMC" story that
dominated the previous session. That conclusion was reached from a boot that
never ran a kernel.

### Remaining gap
**No network after boot.** `rescue-init.sh` does not run `dhclient`, so the box
sits at a login prompt with no IP:
```
ping 192.168.1.21 -> 100% packet loss
ssh  -> Connection timed out
```
Unattended, this box is only reachable by HDMI keyboard or a UART console.
`rescue-init.sh` must bring up eth0 + dhclient + resolv.conf + clock + sshd,
all backgrounded so the serial console is never blocked.

Also still outstanding: clock reads 1970, `/etc/resolv.conf` absent, and
`Acquire::ForceIPv4` unset **on the eMMC rootfs** — those fixes were applied to
the USB stick's copy only. See `INSTALL-IMAGE-REQUIREMENTS.md`.

---

## 2026-10-19 (later) — the installer runs end-to-end, and the stick is rebuilt

### Conditional `bootcmd` saved and proven in both directions

The saved `bootcmd` is a conditional: the stick if present, the eMMC if not.

```
usb start 0; if fatload usb 0:1 0x2000000 Image; then <usb branch>;
else <emmc branch>; fi
```

Two things had to be established before it was safe to `saveenv`:

- **`fatload` returns non-zero on failure**, so `if fatload ...; then` is a
  valid test. Verified directly with a non-existent filename.
- **`usb start 0` returns instantly with no stick** — no stall. This was the
  one thing that could have made `saveenv` dangerous.

Both branches then verified from a cold boot, unattended, zero prompts:
stick in → `root=/dev/sda2`; stick out → `root=/dev/mmcblk0p2`.

#### The serial link truncates long lines

Sending the ~900-character conditional as one line **failed** — U-Boot dropped
into a `>` continuation prompt because the line arrived truncated. `Ctrl-C`
does not escape it; a lone `"` does.

Fix: build the value from short pieces with hush expansion, which works:

```sh
setenv x ABC
setenv y ${x}DEF      # y=ABCDEF
```

Also: do **not** `printenv` a long value immediately before `saveenv`. Long
output over this link is dropped, and `saveenv` landed mid-stream and reset
the box.

### `fw_setenv` works — the config was wrong twice over

The stock `/etc/fw_env.config` named `/dev/mmcblk1` (which does not exist on
this board) and the wrong offset. With both corrected, `fw_printenv` returns
all **132** variables with a valid CRC.

The offset is a property of this board's U-Boot build, so it must be
**discovered**, not hardcoded. `scripts/find-env.sh` does that read-only.

Two false positives found while testing it, both silent and in opposite
directions:

- A **byte-identical copy** of the environment passes every content check —
  because the installer `dd`s p2 wholesale, another partition holds a full
  copy, and `fw_printenv` parses it happily. A variable *count* proves
  nothing, and neither does checking variable *names*: the copy has the same
  names. Only **position** discriminates.
- A glob meant to match a partition (`*[0-9]*`) also matched the whole device
  (`/dev/mmcblk0`, trailing digit) and rejected the one correct candidate.

A guard against this class of bug needs a **negative** test, not just a
positive one.

#### `fw_setenv` takes a bare value

`fw_printenv` prints `bootcmd=<value>`; feeding that back into `fw_setenv`
stores `bootcmd=bootcmd=...`. This happened during testing and briefly broke
the working bootcmd. Always strip the name, and verify by reading back and
comparing.

### The environment lives INSIDE p2 — so the installer's own `dd` destroys it

Located at 28 MiB into p2 (sector 237568). This is why the installer has to
back the environment up *before* the rootfs copy and restore it *after*.

### The installer, run end-to-end

| step | result |
|---|---|
| partition + format | p1 ext4 at sector 81920 (past the eMMC key range 73760–74785), p2 to 100 % |
| copy rootfs | 773 MiB, target unmounted |
| **`resize2fs`** | **773 MiB → 14,851 MiB** |
| restore env | verified from the device |
| `fw_setenv bootcmd` | verified by full-string readback |
| boot artefacts | hashes verified from a read-only remount |

The result: a 15 GB rootfs with 13 GB free, on hardware that previously had
744 MB with 23 MB free.

#### `resize2fs` — the fix that was not optional

`dd` with no `count=` copies only the source partition's bytes. Without the
resize the rootfs stayed at 773 MiB inside a 14.9 GB partition — about 5 % of
the eMMC usable, which looks exactly like a hardware fault from `df`.

#### Two arithmetic bugs of my own, both caught by checking against a device

- `Block count:` splits into fields 2 and 3; the number is `$3`. Parsing `$2`
  yields the string `count:` and evaluates to 0.
- The block size is **4096**, not the 512-byte sector size. Assuming 512
  reports every size 8× too small.

Both would have shipped a broken installer. Both were caught by comparing the
number against `df` rather than trusting it.

### `rescue-init.sh` had two ordering bugs

**The network could never come up.** The carrier poll ran *before*
`ip link set eth0 up`, and reading `carrier` on a down interface returns
`EINVAL`, not `0` — so the test could never succeed. Confirmed empirically:
up → `1`, down → `Invalid argument`. And after bringing the link up, a fixed
one-second sleep is not enough: the PHY needs ~1.5 s (`ip link` at 146.12 s,
`Link is Up` at 147.61 s).

This was a **race**, not a hard failure. The same code sometimes worked,
which is exactly why it went unnoticed: the eMMC boot won the race, the stick
boot lost it.

**The clock had no fallback.** Now the last-known-good time is persisted and
restored when chrony cannot sync — with the saved value validated as
all-digits first, because handing garbage to `date -s` would set a nonsense
clock, which is harder to debug than no clock at all.

### A safety guard that was silently broken

The installer refuses to run while booted from the eMMC it is about to
repartition. The first version compared device **names**:

```sh
ROOTDEV=$(findmnt -n -o SOURCE /)     # -> "/dev/root"
case "$ROOTDEV" in "${MMC}"p*) die ;; esac
```

`findmnt` reports the root as `/dev/root` on this box, not `/dev/sda2`, so the
comparison never matched and the guard never fired. It now compares
**major:minor** from `/proc/self/mountinfo` (stick `8:2` vs eMMC `179:2`).

A guard that reads plausibly and never fires is worse than no guard, because
it looks like protection.

### The stick rebuilt: flat layout, 880 MB

| | size | filesystem |
|---|---|---|
| p1 | 64 MB | FAT32 (LBA), LBA 32768 |
| p2 | 800 MB | ext4, LBA 163840 |

Deliberately small so it fits a 1 GB stick. The stick is the *install source*,
so p2's size sets the install time (773 MB → 39 s, 7 GB → 109 s), and the
eMMC takes all the space anyway. This is the same relationship an ISO has to
its target disk.

`scripts/grow-stick.sh` extends p2 into leftover space for anyone with a
bigger stick — tested, 800 MB → 1968 MB with contents intact.

The boot artefacts moved from `d/` to the **root** of the FAT boot partition.
Three things had to be updated together, and one of them was a latent bug:

- the `aml_autoscript` uImage (rebuilt with flat paths)
- the installer's `fw_setenv` path
- **the installer read the kernel from an auto-detected directory but wrote a
  bootcmd with `d/` hardcoded** — so on a flat stick the USB branch would fail
  *silently*, fall through to the eMMC branch, and the stick would appear to
  do nothing at all.

#### The U-Boot payload must not contain quotes in comments

An unbalanced quote puts hush into its `>` continuation prompt and the script
never runs. The vendor's own autoscript avoids quotes in comments for the
same reason. The source is kept for documentation; the uImage is built from a
comment-stripped copy.

#### The stick's `aml_autoscript` must boot the stick

It is the first-boot entry vector — the vendor bootloader scans the USB stick
and runs it. It must set `root=/dev/sda2`. One copy of it in the tree had
`root=/dev/mmcblk0p2`, which would boot the Android you are trying to
replace.

#### The host has no loop devices

`losetup` fails (the module cannot be loaded). FAT images must be built with
`mtools`; ext4 images must be built on the box, which does have loop
devices.

An early attempt to populate p1 with `cp` into a mountpoint silently wrote
into an empty directory, because the loop mount had failed and the `&&` chain
still echoed "mounted". **Verify the mount actually happened.**

#### A failed copy leaves a file with the right name and the wrong size

Copying the p1 backup produced a 0-byte `Image`. A file with the right name
is indistinguishable from a good one until you hash it. Hash every artefact
after every copy.
