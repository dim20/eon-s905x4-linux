# `dist/` — local build artefacts

`dist/` holds build outputs, not source. Everything here is gitignored
except `SHA256SUMS` and this file.

The names are **not** all release names. Read this table before using a
file:

| File | What it actually is |
|---|---|
| `eon-s905x4-linux-stick.img.gz` | the **v0.7-tty** image. This is the "current" asset name the README tells a user to download; the file it names changes from release to release. It is the same bytes as `v0.7-tty-img.gz`. |
| `v0.7-tty-img.gz` | the same bytes as `eon-s905x4-linux-stick.img.gz`, kept under a release-named copy so it cannot be mistaken for another release. |
| `v0.7-tty-kernel.deb` | the v0.7-tty kernel as an installable package, with rollback. |
| `Image` | the v0.7-tty kernel (`45a67743…`). |
| `sc2_s905x4_ah212_linux.dtb` | the v0.7-tty device tree (`d1e2267f…`). |
| `v0.6-desktop-img.gz` | the **v0.6** image (`934d3969…`). Despite the name it contains no desktop — only `tasksel`. See [`../docs/releases/errata-v0.6.md`](../docs/releases/errata-v0.6.md) Correction 4. |
| `v0.5-manifest-img.gz` | the **v0.5** image (`7c6147cb…`). It is not v0.5.1. |
| `inventory.txt`, `TEST-CHECKLIST.md` | produced by the v0.7-tty build. |
| `SHA256SUMS` | covers the v0.7-tty assets above. Verify with `sha256sum -c SHA256SUMS` from this directory. |

## What is missing, and why

- **The v0.5.1 image is not here.** Its published SHA256 is
  `998899…` (see `docs/releases/v0.5.1-units.md`); it was built elsewhere
  and is not stored in this working tree.
- **No checksum for `v0.5-manifest-img.gz`** in `SHA256SUMS`: that file
  predates the current sums file. Its hash is
  `7c6147cbb469cf269d5ae4cc2cfc3c383f4fee7f90111442470099369a8f9472`.

## Which one should I use?

For the text console, **v0.7-tty** — the current release. The two image
files named above are the same bytes; either works. v0.6-desktop is an
older asset whose terminal text is unreadable, and whose "desktop" is not
in the file at all: see [`../docs/releases/errata-v0.6.md`](../docs/releases/errata-v0.6.md).
