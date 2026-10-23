# Errata and addenda — v0.7-tty

**Published 2026-10-23, about the v0.7-tty release. The release notes
themselves are not edited; this page records corrections and later
verification.**

## Addendum 1 — the image file has been booted from a stick

The v0.7-tty release note says, correctly at the time it was written, that
the image file had not yet been written to a stick and booted — only the
eMMC system, which was installed from the running stick, had been tested.
That gap is now closed, on 2026-10-23:

- `dist/v0.7-tty-img.gz` was verified as `c5c148cf…` before writing;
- it was written to a USB stick and read back with
  `gunzip -c v0.7-tty-img.gz | cmp - /dev/sdX` — **no differences**;
- the box was power-cycled and **booted from the stick**;
- the root filesystem was **~800 MiB**, so the vendor's stick-growing
  script did not run;
- p1 contained `Image`, `sc2_s905x4_ah212_linux.dtb` and
  `aml_autoscript`.

The p1 FAT layout and the first-boot `aml_autoscript` path are therefore
proven from the published download, not only from the stick that
installed the eMMC.

No correction to the release note is needed: the note described the state
of verification when it shipped. This addendum records what was verified
afterwards.