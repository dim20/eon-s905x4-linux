# Errata — v0.6-desktop

**Published 2026-10-23, about the v0.6-desktop release. The release notes
themselves are not edited; this page records what they got wrong.**

The v0.6 release is real and its assets are unchanged. This page says what
it claimed, what was actually true, and what to do if you have it.

## Assets (unchanged)

| File | SHA256 |
|---|---|
| `eon-s905x4-linux-stick.img.gz` | `934d39693029663bcf50c426640b057a0980bad3d604551b77722ff3b3346d06` |
| `Image` | `39b91fd04d6052009f83d645ecbbe93957f34bcedcf6fbe7d7e09a961bc67981` |
| `sc2_s905x4_ah212_linux.dtb` | `d1e2267f5e945acff73f7a8973af9fcbb2d777faf26771e2a7e75687537ffda8` |

## Correction 1 — "the desktop works"

**It does not, in the sense a user means.** The display manager started, the
greeter appeared, and windows and their backgrounds were drawn — but the
**text was unreadable** and the **mouse pointer vanished** over terminal
windows. The release notes' own "Known limitations" described windows whose
contents did not reach the display; the symptom was worse and more specific
than that.

**The cause** (found on 2026-10-21, after the release): the X server's screen
pixmap was **24 bits deep inside a 32-bit framebuffer with a 7680-byte
stride**. The fb library's conversions are keyed on the depth, so the X
server's own font engine wrote three bytes per pixel into storage that takes
four — the glyphs were smeared across the row and repeated every 652 pixels.
The screen's *layout* was already 32-bit after the fbdev driver patch; the
*conversion* was missing. Upstream X solves this in a module called
`fb24_32`, which the modesetting driver uses and this version of the fbdev
driver does not.

**Evidence, reproducible:** `xwd` (the X server's own dump of the root
window) reported 32 bits per pixel with a 7680-byte stride while the glyphs
in `/dev/fb0` were laid out at 24 bits. `fbprobe` in
[`../../scripts/fbtools/`](../../scripts/fbtools/) shows the same thing
directly: read the same
bytes as 24-bit pixels and as 32-bit pixels, and they disagree — that is the
smearing. The pixel-by-pixel diff against the server's dump was done with a
throwaway program that was not kept, so `docs/framebuffer.md` describes the
method and `fbprobe`/`fbregion` reproduce it.

## Correction 2 — the "missing flush" and the mmap theory

The release notes suggested that an `mmap` write from the X server did not
reach the display while a kernel `write()` did, and pointed at the fbdev's
`.fb_sync` as the suspect.

**That was wrong.** The display scans the framebuffer live. There is no copy
and no flush to miss. This was measured three ways and is recorded, with the
method, in [`../framebuffer.md`](../framebuffer.md). The real reason a
window's text was wrong was the 24/32-bit mismatch above, not a missing
damage call.

## Correction 3 — the vblank was not the blocker

The release notes correctly said the desktop got past the vblank bug, but
the contradiction with earlier documents survived: the vblank interrupt is
**still broken** (the vsync IRQ fires, but the vendor CRTC never delivers a
vblank *event*), and it is **not** what blocks the desktop. Anything that
waits for a vblank will time out; the fbdev path does not wait for one.

## What to do if you have v0.6

- **If you want the text console:** mask the display manager and reboot.

  ```sh
  systemctl disable --now lightdm
  systemctl mask lightdm
  reboot
  ```

  The console then takes the display over, as it does on v0.5.1.

- **If you want a desktop:** don't, yet. There is no v0.6 configuration in
  which the text is correct. Wait for the optional desktop package set that
  follows v0.7-tty.

- **If you are choosing an image today:** use **v0.5.1** for the TTY
  product, or wait for **v0.7-tty**.

## What v0.6 did get right

- It proved the desktop's display path: the greeter and window contents
  reach the television through the fbdev driver, not through the OSD overlay
  planes.
- It proved the build reproducible, with a byte-identical kernel.
- It added the manifest and the inventory to the image.
- It fixed the font-cache ordering that made the first terminal 173×62
  pixels.
- It identified `fix.smem_start` and the framebuffer's buffer lifetime as
  real bugs; both fixes are in the patch series.

The blank terminal opened from the XFCE menu was a second symptom in the
same area. It was not pursued once the desktop was frozen, and this page
does not claim a cause for it.

The desktop work is **frozen**, not abandoned. The plan of record schedules
it after the TTY release, as an optional package set.
