# The framebuffer tools

Small, static aarch64 programs that look at what the display is actually
doing. They exist because the answer to "why does the picture not reach the
television" turned out to be measurable, and every earlier answer to it was
a guess.

The findings, and the display path they describe, are in
[`../../docs/framebuffer.md`](../../docs/framebuffer.md).

## Build

The box has no compiler, so these are built on a host with a static
aarch64 toolchain — the same one the kernel is built with:

```sh
TC=${TC:-/path/to/aarch64-buildroot-linux-gnu/bin/aarch64-buildroot-linux-gnu-}
for f in fb*.c; do "${TC}gcc" -static -O2 -o "${f%.c}" "$f"; done
```

Copy them to the box and run them there.

## What each one answers

| program | what it answers |
|---|---|
| `fbaddr`   | which physical addresses are involved: the framebuffer device's `smem_start`, and the plane's `phy_addr` in the DRM debugfs |
| `fbhash`   | is the framebuffer changing? **takes the checksum through the `mmap`**, which is the only view that describes what the display scans |
| `fbhalves` | a picture of the framebuffer, and how many colours are in each half |
| `fbviews`  | are the kernel's view of the framebuffer and the userspace's view the same memory? |
| `fblife`   | does the framebuffer's buffer survive a close? It writes a pattern, closes, reopens, and reads it back: if it is gone, the display was left reading memory handed back to the allocator |
| `fbmem`    | the physical address a mapping of `/dev/fb0` lands on, for this process or for a given pid. Two mappings of the same file can be of different memory |
| `fbprobe`  | read the framebuffer with a given stride and pixel size. **This is how the 24-bits-in-a-32-bit-framebuffer smear was shown**: the same bytes, read two ways, disagree |
| `fbraw`    | the same bytes through both paths — the kernel's `read()` and a userspace `mmap` — which do not always agree |
| `fbregion` | dump a rectangle of the framebuffer at full resolution, through the `mmap` |
| `fbtest`   | fill the framebuffer with a colour, through the `mmap` |
| `fbmix`    | fill the framebuffer one way and write a band the other way, so the two can be told apart on the television |

`fbmix` needs a person to look at the television; the rest do not.
`fbhash` and `fbraw` are the two that settled the most arguments.

There is also a `fbraw2` on the test box that was never published; its source
was not kept.

## What they found

The display scans the framebuffer live. There is no copy of it, and no flush
that is being missed. `fbhash` (through the `mmap`) changes every second
while an animated X client runs, and the television shows it.

Two real bugs turned up on the way:

- when the X server exits, the OSD plane is left disabled and the television
  goes black; the text console does not take the display back;
- the framebuffer's buffer is freed and reallocated on every open and close,
  while the plane's address is only recomputed on a commit, so the display
  can be left scanning memory nobody is drawing into.
