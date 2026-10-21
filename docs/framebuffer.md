# The framebuffer, and what the display is really doing

This is the honest record of how the display works on this box, and of
a diagnosis that was wrong for a long time and had to be corrected.

## The short version

**The display scans the framebuffer live.** There is no copy of it, no
"flush" that is being missed, and no path by which the picture has to
be "handed to" the display. What you draw into `/dev/fb0` is on the
television as soon as it is written.

This was measured, not argued:

* filling `/dev/fb0` through an `mmap` with solid magenta and solid
  green, eight seconds apart, made the television alternate between
  magenta and green;
* the DRM's state (`/sys/kernel/debug/dri/0/state`) says the OSD plane
  is enabled, with `src_y=0`, `src_h=1080` and

      phy_addr=0x77ff0000

  and the framebuffer device says

      fix.smem_start = 0x77ff0000

  The same address. The display is reading exactly the buffer that
  `/dev/fb0` is;
* the X server's own output lands in that buffer and keeps landing
  there: `xclock`, which redraws once a second, changes the
  framebuffer's checksum every second, and the clock is visible in a
  picture of the framebuffer taken through the `mmap`.

Both write paths reach the display, which matters because the text
console and the X server's software cursor do **not** use an `mmap`: a
band written through the kernel's `write()` path — the path the fbdev's
own `fillrect`, `copyarea` and `imageblit` use — appeared on the
television exactly where it was written.

One subtlety worth keeping: a 256-byte write through the kernel's
mapping did not become visible to the `mmap` straight away, while a
4 KB write did. That is **write combining**, not a coherency bug: the
small write sat in the WC buffer. Small updates can therefore be
delayed, which is worth knowing when a single small change does not
appear at once.

## The diagnosis that was wrong

For a long time the working theory was:

> the television shows a *copy* the vout made, and the copy is only
> refreshed when the plane's framebuffer *changes* — which it never
> does, because the X server draws into the same buffer. So the
> driver's flush, which runs only at the mode set, is what is missing.

It was a plausible story, and it was wrong. There is no copy. The
symptom it was invented to explain — "some windows' contents do not
reach the display" — has a different cause, which is described below.

The story survived because every experiment available at the time
pointed the same way: the X server made no ioctl and no `fsync`, the
atomic commit ran only twice, and the framebuffer's contents were
correct. All three of those are true, and none of them imply a copy.

**The lesson**: measure the thing you are explaining. The tools below
do that, and they take two minutes.

## The tools

Six small static programs, in `scripts/fbtools/`. They are built with
the kernel's own toolchain:

    TC=.../aarch64--glibc--stable-2024.05-1/bin/aarch64-buildroot-linux-gnu
    for f in fb*.c; do $TC-gcc -static -O2 -o "${f%.c}" "$f"; done

| program    | what it answers |
|------------|-----------------|
| `fbaddr`   | which physical addresses are involved: the framebuffer device's `smem_start`, and the plane's `phy_addr` in the DRM debugfs |
| `fbhash`   | is the framebuffer changing? **takes the checksum through the `mmap`**, which is the only view that describes what the display scans |
| `fbhalves` | a picture of the framebuffer, and how many colours are in each half |
| `fbviews`  | are the kernel's view of the framebuffer and the userspace's view the same memory? |
| `fblife`   | does the framebuffer's buffer survive a close? |
| `fbtest`   | fills the framebuffer with a colour, through the `mmap` |
| `fbmix`    | fills the framebuffer one way and writes a band the other way, so the two can be told apart on the television |

`fbhash` is the one that matters. A checksum taken with `read()` —
which goes through the kernel's mapping — does **not** describe what
the display is scanning, and using one is how the wrong diagnosis was
made convincing.

`fbmix` needs somebody to look at the television; the rest do not.

## The bugs that are real

### The physical address in `fix.smem_start` — the big one

`patches/0008-fbdev-smem-start.patch`.

The DRM's own framebuffer helper deliberately does **not** put the
physical address of the framebuffer in `fix.smem_start`. It only does
so under `CONFIG_DRM_FBDEV_LEAK_PHYS_SMEM`, and then only if the field
is still zero:

    /* Shamelessly leak the physical address to user-space */
    #if IS_ENABLED(CONFIG_DRM_FBDEV_LEAK_PHYS_SMEM)
            if (drm_leak_fbdev_smem && fbi->fix.smem_start == 0)
                    fbi->fix.smem_start =
                            page_to_phys(virt_to_page(fbi->screen_buffer));
    #endif

That is not squeamishness. **The X server's fbdev driver treats
`fix.smem_start` as an offset into its own mapping of `/dev/fb0`, not
as a physical address:**

    fPtr->fboff = (unsigned long) fPtr->fix.smem_start & ~PAGE_MASK;
    fPtr->fbmem_len = (fPtr->fboff + fPtr->fix.smem_len + ~PAGE_MASK)
                      & PAGE_MASK;
    ...
    fPtr->fbstart = fPtr->fbmem + fPtr->fboff;

With the physical address in that field — `0x77ff0000` on this box —
the X server's screen pixmap landed **two gigabytes** past the start of
its mapping, and everything it drew went there instead of into the
framebuffer. The television showed a stale picture, and the parts of it
that X had drawn were moiré'd, because what was there was the remains
of something else.

With the field left at zero — which is what the DRM does — the X
server's screen pixmap *is* the framebuffer, and the desktop and its
windows appear.

### The framebuffer's buffer belongs to the framebuffer

`patches/0007-fbdev-buffer-lifetime.patch`.

The vendor's DRM framebuffer emulation frees the framebuffer's buffer
when the last user closes `/dev/fb0`. That is wrong in two ways:

* the plane may still be reading it. The plane's address is programmed
  when the framebuffer's contents are committed, and nothing undoes
  that when the file is closed, so the display went on reading memory
  that had been handed back to the allocator;
* the next open has to find the buffer at the **same** address. Because
  it had been freed, the next open allocated a new one — usually at a
  different address — while the plane still pointed at the old one. The
  display therefore showed the *old* buffer, which is what "the display
  shows a stale frame" looks like from the outside, while the client
  that had just drawn into the new one saw nothing.

The patch unmaps the buffer when the file is closed but does not free
it, retires a buffer that is being replaced rather than freeing it
while the plane may still be reading it, and frees it when the
framebuffer goes away.

### What is still wrong

The desktop, its windows and their backgrounds now reach the television.
**The text does not**: the glyphs are copied into the framebuffer with
the wrong stride, and repeat every 652 pixels where they should be
written once. The window's background and border are correct; only the
glyphs are wrong, which means they are drawn by a different mechanism
— the X server's font engine, rather than the client — and reach the
framebuffer by a different path.

Two more symptoms in the same area:

* the mouse pointer vanishes over the terminal windows;
* the terminal started from the XFCE menu comes up blank, with no
  shell, while the same `xterm` started from a shell works. That one
  smells like a missing font rather than a missing stride: a terminal
  with no font can draw its background and its border and nothing else.

### The shadows, and why there is no alpha

The compositor's shadows and the semi-transparent button backgrounds
come out black, and that is not about the GPU.

The X server's fbdev driver sets the visual's colour weights to zero:

    /* color weight */
    if (pScrn->depth > 8) {
            rgb zeros = { 0, 0, 0 };
            if (!xf86SetWeight(pScrn, zeros, zeros))
                    return FALSE;
    }

So the X server's screen visual has **no alpha channel**, and the
compositor blends the shadows against black.

And the fbdev driver **cannot run at depth 32 at all** — asked for it
with `Option "DefaultDepth" "32"`, the X server refuses to start:

    (**) FBDEV(0): Depth 32, (--) framebuffer bpp 32
    (EE) FBDEV(0): Weight given (000) is inconsistent with the depth (32)
    (EE) Fatal server error: no screens found

because `xf86SetWeight()` checks the weights against the depth, and the
driver has just set them to zero. **The alpha channel is not reachable
by configuration**; it needs a different X driver, or a patched one.

The tools in `scripts/fbtools/` answer all three: `fbhash` says
whether the framebuffer changed, `fbhalves` and `fbregion` show what
is in it, and `fbraw` compares the kernel's view of the memory with
userspace's.

### The build script was dropping an option

On 2026-10-21 at 16:48, `CONFIG_DRM_MESON_EMULATE_FBDEV` was dropped
from the list of options the kernel build script applied, and every
kernel built since then has had **no DRM framebuffer at all**: no
`/dev/fb0` from the DRM driver, and no display the X server can use.
The published kernel was built before that, which is why nobody
noticed.

The build script now reads the options from the config delta file —
the same file the public repository publishes — so the list and the
file cannot drift apart again, and it **fails the build** if an option
the delta asks for does not survive.

### The patches have to build the tree

`scripts/check-patches.sh` applies the published patches, in order, to
a pristine copy of the vendor's tree, and compares the result with the
tree the kernel is actually built from. It is the only way to know that
the published patches are worth publishing.

It found that `0005-no-osd-framebuffers.patch` did not apply at all: it
had been generated against a tree that already had part of its own
change in it. The patches now apply, and reproduce the tree exactly.
