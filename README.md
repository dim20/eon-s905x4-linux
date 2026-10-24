# eon-s905x4-linux — EON Linux

Debian on the **EON SDSTB02** (Greek EON / NOVA set-top box, built by
SDMC) — an Amlogic **S905X4 / SC2** box with 2 GB LPDDR4 and 14.6 GB
eMMC — turned into a small, silent, general-purpose Linux computer.

The box ships with a locked Android bootloader and no way to boot
anything else. This project gets it to boot Debian from eMMC,
unattended, with nothing plugged in.

```
UNMODIFIED BOX + USB STICK  →  POWER CYCLE  →  LINUX, NOBODY TOUCHES IT
```

---

## Status

| | |
|---|---|
| **Latest release** | **v0.7.1-tty** — the text console on HDMI and on serial; HDMI audio, the clock fallback, the hostname fix and the smoke test |
| **Previous TTY release** | **v0.7-tty** — the text console as a product |
| **The "desktop" release** | **v0.6-desktop** — named for a desktop its asset does not contain. See [`docs/releases/errata-v0.6.md`](docs/releases/errata-v0.6.md) |
| **Next** | **P1** — a solid base: audio, power, thermal, storage, smoke test |

The desktop is **frozen** and returns as an optional package set, not as a
second image.

Verified on the development box for v0.7.1-tty:

| | |
|---|---|
| Boots unattended from eMMC | ✅ power cycle only, a few seconds to a systemd login |
| Boots unattended from the stick | ✅ 1 boot / 1 booti / 0 prompts |
| systemd | ✅ PID 1, **0 failed units**, `apt` works |
| 4 cores | ✅ |
| Ethernet 100 Mbps | ✅ internal RMII PHY |
| HDMI | ✅ 1920×1080 output confirmed on a real display |
| Text console on HDMI | ✅ a login prompt on the TV, confirmed on a real display |
| Network after boot | ✅ DHCP, DNS, SSH, from a cold power cycle |
| Clock after boot | ✅ chrony, with a persisted last-known-good fallback |
| Automated eMMC install | ✅ runs end-to-end, verifies every write from storage |
| Bootcmd installed automatically | ✅ the installer finds the U-Boot environment and sets it |
| U-Boot recovery window | ✅ `bootdelay=3` — a "hit any key" prompt, when no stick is attached |
| Root filesystem size | ✅ 15 GB on the eMMC, not the 744 MB it started with |
| Audio | ✅ HDMI audio plays (set `HDMITX Audio Source Select` to `Tdm_C`; the image does it at boot — see [`docs/audio.md`](docs/audio.md)) |
| USB keyboard on the HDMI console | ✅ login and `Ctrl-Alt-F1`…`F6` switching confirmed on the box |
| WiFi | ❌ no open driver for the RTL8812CS |

In **v0.7-tty**:

- the framebuffer fixes (`fix.smem_start`, the buffer's lifetime);
- the kernel as an installable package, labelled `5.4.210-eon3`, with
  rollback ([`docs/kernel-package.md`](docs/kernel-package.md)); its
  `uname -r` is the vendor tree's own string, and the document explains
  why the two differ;
- `scripts/check-patches.sh`, which proves the published patches
  reproduce the build tree;
- the corrected build recipe: `patches/0002-option-D.config.delta` is
  applied as a file, so an option cannot be silently dropped again (the
  development repository's build script reads the same file);
- brand-new login branding (see below).

## Quick start

Download the TTY image (**v0.7.1-tty**, `v0.7.1-tty-img.gz`; the same bytes
are also published as `eon-s905x4-linux-stick.img.gz`) and write it to a
USB stick of 1 GB or more:

```sh
gunzip -c eon-s905x4-linux-stick.img.gz | sudo dd of=/dev/sdX bs=4M status=progress
sync
```

Plug it into the box and power cycle. The box boots the stick, brings up
networking and SSH, and gives you a login (`root` / `tvbox`):

```sh
ssh root@<the address the box prints on the console>
```

**There is also a login prompt on the HDMI output.** Plug in a display
and a USB keyboard and the box gives you a text terminal — no SSH, no
serial cable needed. Both the output and the keyboard are confirmed on a
real display, including `Ctrl-Alt-F1`…`F6` switching between virtual
terminals.

From there, provision the eMMC:

```sh
/root/install-to-emmc.sh
```

It verifies every artefact before and after writing, grows the filesystem
to fill the eMMC, and sets the boot command so the box boots on its own
afterwards. **Remove the stick and power cycle** to confirm.

If your stick is larger than 1 GB and you want the extra space in the
live system, run `scripts/grow-stick.sh` against it first.

### The login banner

v0.7-tty shows our banner, not the vendor's: `/etc/issue`, `/etc/issue.net`
and the login-message hooks are replaced during the build. It is plain
ASCII on purpose: the framebuffer console does not interpret terminal
escape sequences.

## Known gaps

These are real and will bite you:

1. **Audio over HDMI works, but only with one mixer control set.** The
   transmitter's `HDMITX Audio Source Select` defaults to `Spdif`, while the
   playback path is `Tdm_C` (`hw:0,2`); with the default the stream runs and
   nothing is heard. Set it to `Tdm_C` — the image now does this at boot —
   and a 440 Hz test tone is audible on the TV. Analog (T9015) and SPDIF
   outputs were **not** tested. See [`docs/audio.md`](docs/audio.md).
2. **There is no desktop on the TTY image.** That is deliberate: a
   display manager takes the framebuffer from the text console, and a
   desktop is a large amount of software the user may not want.

   `v0.6-desktop` did ship one, and its terminal text was unreadable —
   the X server's screen pixmap was 24 bits deep inside a 32-bit
   framebuffer. The fix needs upstream's `fb24_32` conversion, which this
   version of the fbdev driver does not have. The desktop is frozen; the
   plan is an optional package set after v0.7-tty. If you are running
   v0.6 and want the console, mask the display manager:

   ```sh
   systemctl disable --now lightdm
   systemctl mask lightdm
   reboot
   ```

   Do **not** expect `tasksel` to give you a working desktop yet: it will
   install one, and the text will be wrong for the reason above.
3. **No GPU-accelerated 3D.** The vendor DRM driver advertises no dma-buf
   modifier support, so Mesa's GBM has nothing to negotiate. A 2D desktop
   does not need it; 3D does.
4. **The clock fallback is only unit-tested.** The chrony success path is
   proven on hardware; the "no network at boot" path has not been
   exercised on a real box.
5. **The root password is published.** `root`/`tvbox` is in a public
   repository. Change it before the box is on a network you do not trust:

   ```sh
   passwd
   ```

   The box also accepts root logins over SSH with that password. There is
   no first-boot wizard yet; this is documented rather than fixed.
6. **The kernel has no upstream security updates.** It is a vendor tree,
   Linux 5.4.210, built from CoreELEC/Amlogic sources. The kernel package
   makes a new kernel installable and a bad one reversible, but it does
   not track upstream.
7. **Only one box has been tested.** Everything here was proven on one
   development box. It has not been validated on other hardware.
8. **The first boot may need the vendor's own update path.** If your box
   does not find `aml_autoscript` on the stick by itself, see
   [`docs/recovery.md`](docs/recovery.md) — you will need a UART console
   once.
9. **Opening `/dev/fb0` panics the box — on v0.5.1, v0.6, and any image
   built before v0.7.** v0.7-tty fixes it. The text console itself is
   fine, and it draws all day. But any program that opens `/dev/fb0` —
   `fbset`, a framebuffer tool, an X server — closes it again, and on
   those older images the kernel panics a few seconds later: the
   framebuffer console's cursor puts the mapping back down and the next
   blink writes through a NULL screen base.

   ```
   fb_flashcursor -> bit_cursor -> soft_cursor ->
   drm_fb_helper_cfb_imageblit -> cfb_imageblit   (write to NULL + 0x200)
   Kernel panic - not syncing: Fatal exception
   ```

   Reproduced on 2026-10-23 on the test box, with the serial console
   capturing the panic. **On an image older than v0.7-tty, do not open
   `/dev/fb0`.** The fix is in the v0.7 kernel; see
   [`docs/framebuffer.md`](docs/framebuffer.md) for the mechanism.

If you want to help finish it, see the roadmap below.

---

## Read this first if you have some other S905X4 box

**You may not need any of this.**

A lot of the difficulty here is specific to *this* board and *this*
bootloader:

- the vendor bootloader cannot `booti` a PE/ZBOOT-wrapped kernel, which is
  what essentially every distro ships — so a custom kernel has to be built;
- the internal Ethernet PHY lives on a private MDIO bus that mainline's
  device tree does not describe, so mainline `stmmac` cannot drive it;
- the device tree shipped with the vendor kernel has two variants and the
  wrong one aborts before the kernel prints anything.

If your box already boots mainline Linux from a USB stick, you need none
of this and should stop reading. If you are hitting one of those specific
walls, this repo may save you a week.

The kernel is built from **CoreELEC's `amlogic-5.4.210`** tree, which
already supports this SoC properly. That is the single biggest reason
this project is tractable.

---

## What the box ends up doing

On power cycle, with nothing connected:

```
BL2 → BL31 → U-Boot
  "Hit any key to stop autoboot:  3  2  1  0"     ← 3 s to reach the U-Boot prompt
  bootcmd (saved in the U-Boot environment, set by the installer)
    usb start 0
    if fatload usb 0:1 0x2000000 Image; then
        → boot from the USB stick, root on /dev/sda2
    else
        mmc dev 1; mmc rescan
        ext4load mmc 1:1 0x2000000 Image
        ext4load mmc 1:1 0x5000000 sc2_s905x4_ah212_linux.dtb
        setenv bootargs 'root=/dev/mmcblk0p2 ... init=/lib/systemd/systemd'
        booti 0x2000000 - 0x5000000
        → Linux 5.4.210, root on eMMC, systemd as PID 1
```

The stick is a **recovery key**, not a dependency: plug it in and the box
boots the stick; unplug it and the box boots the eMMC. No menu. The
three-second U-Boot window exists only when no stick is attached: the
vendor's own pre-boot chain runs the stick's autoscript before the
countdown.

**The serial port is the kernel console; the screen is a virtual
terminal.** The kernel command line keeps `console=ttyS0,921600` and
nothing else, so the full boot log goes to the serial port and stays
there, and `getty` on `tty1` gives you a login prompt on HDMI — the usual
Linux arrangement, with `Ctrl-Alt-F1`…`F6` for the other terminals.

Adding `console=tty0` would put the kernel's own messages on the screen as
well, and it was tried. It is not what puts the login prompt there (that
is `getty` + the framebuffer console), and it means a driver logging a
line at 62 seconds lands in the middle of the login prompt. Left out on
purpose.

### If something goes wrong

There are three ways back in, in increasing order of effort:

1. **Plug the stick in.** It boots a complete Linux system with SSH,
   whether or not the eMMC works. This is why the stick is a recovery key.
2. **Interrupt the boot at the U-Boot prompt.** Unplug the stick first —
   with it attached the vendor's autoscript boots before the countdown.
   `bootdelay` is 3, so there is a three-second window with "Hit any key
   to stop autoboot". With nothing but a serial adapter you can boot a
   different `init=` — the rootfs carries both `systemd` and a minimal
   `rescue-init.sh`:

   ```
   setenv bootargs 'root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw console=ttyS0,921600 init=/root/rescue-init.sh'
   ext4load mmc 1:1 0x2000000 Image
   ext4load mmc 1:1 0x5000000 sc2_s905x4_ah212_linux.dtb
   booti 0x2000000 - 0x5000000
   ```

   To change the delay, `fw_setenv bootdelay 0` (faster boot, no window)
   or any other value in seconds. The installer sets it to 3.
3. **Unlocking the bootloader** — ADNL and fastboot. See
   [`docs/recovery.md`](docs/recovery.md).

### Verifying the box after a change

`scripts/smoke-test.sh` is installed into `/root` by the build. After a
kernel or image change, run it on the box:

```
/root/smoke-test.sh
```

It checks the branding, the console arrangement, failed units, the absence
of a desktop, `dpkg --audit`, `apt-get check`, the kernel and DTB on the
boot partition against their expected hashes, and the running system. It
is read-only. Exit status 0 means everything passed; `--quiet` prints only
the failures.

**The published v0.7-tty image predates this script; v0.7.1-tty carries
it**, so on the older download the file is not there. Copy
`scripts/smoke-test.sh` to `/root` on the box if you want it; every image
built from this tree afterwards carries it.

---

## Layout

```
.github/workflows/checks.yml     CI: check-docs.sh + script syntax on every push
dist/                           build artefacts; README.md says which file is which release
docs/
  README.md                       the map of the documentation, and the rules
  releases/                       the release notes, immutable, plus errata
  install-image-requirements.md   what the image must get right, and why
  build-the-kernel.md             how the kernel is built; required for GPL compliance
  recovery.md                     unlock / ADNL / fastboot, and how to get back in
  kernel-package.md               the kernel as an installable package, and rollback
  framebuffer.md                  how the display really works, and the tools that show it
  storage.md                      partitions, TRIM, eMMC wear and free space
  time.md                         the clock fallback, chrony and what to expect
  power.md                        reboot, poweroff and HDMI hotplug, with evidence
  network.md                      DHCP, static IP, DNS, mDNS, WiFi and Bluetooth
  thermal.md                      a sustained-load run, temperatures and throttling
  audio.md                        HDMI audio, the mixer trap, and how to test it
  troubleshooting.md              the traps, written down so you can avoid them
  lessons.md                      engineering lessons from this project
  licensing.md                    licences, credits, provenance
manifest/
  required-packages.txt           packages the image must contain
  forbidden-packages.txt          packages it must not (no desktop, no display manager)
  required-paths.txt              files it must contain, with their modes
  forbidden-paths.txt             files it must not contain
  forbidden-strings.txt           text that must not appear in the login files
  required-units.txt              systemd units it must have enabled
  masked-units.txt                units that must be masked
  global.txt                      rules that apply to the whole rootfs
  boot-artifacts.txt              what must be at the root of the boot partition
  kernel-package.txt              what the kernel package must contain
  inventory.txt                   every file in the image, with owner, mode, size, checksum
  provenance.txt                  where the rootfs came from, and what we changed
  vendor-leftovers.txt            what is still the vendor's, and what it costs
scripts/
  install-to-emmc.sh              provision eMMC from a running box
  rescue-init.sh                  minimal init — the fallback if systemd fails
  find-env.sh                     locate the U-Boot environment (read-only)
  prepare-stick.sh                make a stick a self-contained live system
  grow-stick.sh                   extend a stick's rootfs into leftover space
  smoke-test.sh                   one command after every kernel or image change
  build-stick-image.sh            build the published .img.gz from a rootfs tree
  build-kernel-package.sh         build the kernel as an installable .deb
  check-image.sh                  check an image (and a kernel package) against the manifest
  check-patches.sh                prove the published patches build the tree
  check-docs.sh                   prove the documentation does not contradict itself
  inventory.sh                    write down what is in an image, and diff it
  release.sh                      build a release, check it, print the test checklist
  write-stick-image.sh            write it to a stick and verify it byte-for-byte
  deploy-kernel.sh                send a kernel to a box and prove it arrived
  overrides/                      files the image build substitutes for the vendor's
  fbtools/                        small static tools that measure the framebuffer
  stick/                          the aml_autoscript uImage and its source
  uart/                           serial console tooling
kernel/
  sc2_s905x4_ah212_linux.dtb
  SHA256SUMS
  VERSION                         the project's release label for the kernel package
patches/                          local patches applied to the vendor tree
notes/journal.md                  chronological project log
```

The kernel `Image` is a **release asset**, not in the repo — it is 34 MB.
Download it from the Releases page and check it against
`kernel/SHA256SUMS`.

---

## The manifest

`manifest/` is the answer to "what is in this image, and what must be in
it". It is **data**, not code: plain text files listing what the image must
contain, what it must not, and which of the vendor's leftovers are still
there.

The build checks the image it has just produced against it and **refuses
to produce an image that fails**. `scripts/check-image.sh` can also be run
by hand against any rootfs tree:

```sh
scripts/check-image.sh --rootfs /path/to/tree --p1 /path/to/p1.img
```

Two things follow from this that are worth knowing:

* **The build does not modify its input.** It copies the rootfs tree to a
  scratch directory first and works on the copy, so the tree you give it
  is exactly the tree you still have afterwards — and building twice gives
  the same result as building once.
* **The build is reproducible.** The filesystem's timestamps and UUIDs and
  the gzip header are all pinned, so the same tree gives the same image,
  byte for byte.

`manifest/inventory.txt` lists every file in the image with its owner,
mode, size and checksum. Every build prints the difference against it, so
"what changed in this release" is a diff rather than a surprise.

**The manifest states what is true.** A rule that is not enforced does not
belong there; it belongs in `vendor-leftovers.txt` as a record. The vendor
kernel modules are recorded there, with their cost, because they are still
in the image — and the same is true of the vendor's branding packages.

---

## Roadmap

The phases are the plan of record's, not a new numbering:

| | Phase | State |
|---|---|---|
| H | documentation and housekeeping | **done** (2026-10-23), including the fresh-eyes review |
| P0 | **v0.7-tty**: finish the base and release it | **done** — this release |
| P1 | a solid base: audio, power, thermal, storage, smoke test | **next** |
| P2 | desktop, splash, and the boot experience | **frozen** |
| P3 | hardware: a second box, then other devices | planned |

The detailed plan, including what "done" means for each item, is
`plan/PLAN-OF-RECORD.md` in the development repository (it is not part
of this repository). The vblank-event work, an upstream `meson` port,
Wayland and FbTerm are parked, each with its reason written down there.

---

## Licence

Licensed by component, because they are not the same work:

| | |
|---|---|
| `scripts/`, `docs/`, `notes/`, `patches/` | **MIT** — see [LICENSE](LICENSE) |
| `kernel/Image`, `kernel/*.dtb` | **GPL-2.0** — built from CoreELEC / Amlogic sources |
| the Debian rootfs in the stick image | **GPL-2.0** and the licences of the Debian packages it contains |

**The rootfs is not MIT.** It is derived from
[devmfc/debian-on-amlogic](https://github.com/devmfc/debian-on-amlogic),
which is GPL-2.0, and the corresponding source for it is that upstream
project. The kernel's source provenance is in
[`docs/build-the-kernel.md`](docs/build-the-kernel.md), as GPL-2.0 requires.
The base system is Debian, and remains Debian: `/etc/os-release` says so
truthfully. The port identifies itself in `/etc/eon-release`, the login
banner and the login message.

Full detail, and the credits this project owes, are in
[`docs/licensing.md`](docs/licensing.md).

---

## Safety

- **Read `docs/recovery.md` before writing anything to a box.** There is a
  documented way back in, and it needs the box in a known state.
- If a box has had an OTA update, its bootloader has changed. A bootloader
  image from an un-updated unit is what the recovery path expects.
- Back up anything you care about. Provisioning overwrites the eMMC user
  area.
- The default password is published. Change it before the box is exposed.
