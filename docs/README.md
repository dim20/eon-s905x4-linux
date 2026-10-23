# Documentation

Start here. This page is the map, and it says which document is the
authority when two of them disagree.

The product is **EON Linux**: Debian on the EON SDSTB02 (Amlogic
S905X4 / SC2) set-top box, booting unattended from eMMC with a text
console on HDMI and SSH over the network. It is meant to be a small
general-purpose Linux computer. It is not a media centre.

---

## Where to start

| You want to… | Read |
|---|---|
| use the box | [`../README.md`](../README.md) — status, quick start, safety |
| understand what is true right now | this page, then [`../README.md`](../README.md) |
| know what is planned | `plan/PLAN-OF-RECORD.md` in the development repository (not part of this one) |
| fix a box that will not boot | [`recovery.md`](recovery.md) |
| rebuild the kernel or the image | [`build-the-kernel.md`](build-the-kernel.md), [`kernel-package.md`](kernel-package.md) |
| understand the display path | [`framebuffer.md`](framebuffer.md) |
| understand storage, TRIM and eMMC wear | [`storage.md`](storage.md) |
| understand timekeeping and the clock fallback | [`time.md`](time.md) |
| avoid a trap we already hit | [`troubleshooting.md`](troubleshooting.md), [`lessons.md`](lessons.md) |
| know the licensing | [`licensing.md`](licensing.md) |

## The hierarchy of truth

When two sources disagree, the higher one wins.

| Rank | Source | What it is |
|---|---|---|
| 1 | **The shipped artefact** (`dist/`, the release assets) | What the image, kernel and DTB actually are. Checked with `sha256sum -c SHA256SUMS`. |
| 2 | **`manifest/`** | Machine-checked claims about the image, enforced by `scripts/check-image.sh`. Anything that is not enforced belongs in `vendor-leftovers.txt` as a record. |
| 3 | **`docs/releases/`** | The release notes. Immutable once published; corrections are added as **errata**, not by rewriting them. |
| 4 | **`README.md`** | The current product and status. Always describes the latest release. |
| 5 | **`docs/`** (this directory) | How-to and reference. Behaviour claims carry a `Last verified` date where they have been checked. |
| 6 | **`plan/PLAN-OF-RECORD.md`** | Decisions, priorities and the to-do list. The only current plan; everything else in `plan/` is archived. |
| 7 | **`notes/`** | A chronological lab notebook. Allowed to be wrong; never a source of truth without a matching document. |

## Three rules

1. **A claim about behaviour needs a date and a witness** — a log line, a
   command's output, or "observed on the display". "It works" is not
   evidence.
2. **Supersede, don't delete.** A finding that is no longer true is marked
   `SUPERSEDED <date> — <what is true instead>`. Deleting it loses the
   reason the current design exists.
3. **One question, one answer.** If two documents answer the same
   question, one of them links to the other.

## What is true now (2026-10-23)

- The **text console on HDMI works**: the kernel takes the display over
  at about 12–18 s (`fbcon: Taking over console`, then
  `Console: switching to colour frame buffer device 240x67`), because no
  display manager is running.
- The **latest release is v0.7-tty** (2026-10-23), the text-console
  product. See [`../README.md`](../README.md) and
  [`releases/v0.7-tty.md`](releases/v0.7-tty.md).
- The **image file has been exercised end-to-end**: written to a stick,
  verified with `cmp`, booted on the box; the root filesystem stayed
  ~800 MiB and p1 carried `Image`, the DTB and `aml_autoscript`. See
  [`releases/errata-v0.7.md`](releases/errata-v0.7.md) Addendum 1.
- The **desktop is frozen** and returns as an optional package set. The
  v0.6 asset was *named* for a desktop it does not contain; its terminal
  text was unreadable in the box's own desktop install. See
  [`releases/errata-v0.6.md`](releases/errata-v0.6.md).
- The box has **no loadable modules**: the kernel is monolithic, which is
  why the vendor's module tree is dead weight (see
  [`../manifest/vendor-leftovers.txt`](../manifest/vendor-leftovers.txt)).

## How to verify a claim

```sh
# the image and the kernel are what the release says
sha256sum -c SHA256SUMS

# the image satisfies the manifest
scripts/check-image.sh --rootfs /path/to/tree --p1 /path/to/p1.img

# the published patches reproduce the tree the kernel is built from
# (needs a clean CoreELEC amlogic-5.4.210 checkout; see build-the-kernel.md)
scripts/check-patches.sh patches /path/to/linux-amlogic

# the documentation does not contradict itself
scripts/check-docs.sh
```

On the box, the evidence for the console is:

```sh
dmesg | grep -E 'Taking over console|Console: switching'
cat /proc/consoles        # lists the serial port; a VT appears only with console=tty0
```
