# Release notes

One file per published release. They are **immutable**: a release note says
what was believed at the time it shipped, and it is the record of what the
release promised. If a note turns out to be wrong, the correction goes in
an **errata** file next to it — never by rewriting the note.

| File | What it is |
|---|---|
| `v0.1-testbox.md` … `v0.6-desktop.md` | the published notes, in order |
| `v0.7-tty.md` | the TTY release, and what changed since v0.6; its later stick boot is recorded in `errata-v0.7.md` Addendum 1 |
| `v0.7.1-tty.md` | the last release under the EON name: the fixes that did not make v0.7 |
| `v0.7.2-sc2.md` | the rename release: the same kernel and image changes as v0.7.1-tty, new branding. Built and manifest-checked; hardware test pending |
| `errata-v0.6.md` | what v0.6 got wrong, and what to do if you have it |
| `errata-v0.7.md` | corrections and addenda for v0.7-tty |

Releases up to and including `v0.7.1-tty` were published under the earlier
**EON Linux** name. They are kept as historical artefacts; `v0.7.2-sc2`
is the first release under the **SC2 Linux** name.

## The checklist for a release

Run it in this order. A release is not done until every step has an
artefact, not a memory.

1. **Build** the kernel, the kernel package and the image from a clean
   tree. Record the commit.
2. **Prove the patches** with `scripts/check-patches.sh`; it must
   reproduce the build tree exactly.
3. **Check the artefact** with `scripts/check-image.sh --rootfs <tree>
   --p1 <p1 image> [--package <deb>]`. It must exit 0. A manifest rule
   that fails is a defect in the release, not a rule to relax.
4. **Check the docs** with `scripts/check-docs.sh`. It must exit 0.
5. **Name the assets by release** and record their sizes and SHA256
   values. `sc2-linux-stick.img.gz` is the current asset name;
   keep a release-named copy (`v0.7.2-img.gz`) so it can never be
   mistaken for another release.
6. **Write `vX.Y-name.md`** with: the status line, the assets and their
   hashes, what changed and why, what is *not* fixed, and `Last verified`
   with the date and the box it was verified on.
7. **Update the one status block** in `README.md`. No other document
   states the current version.
8. **Commit** the notes, the hashes and the updated manifest together,
   then tag and push. Pushing is part of the release, not an afterthought
   (P0-8 in the plan of record).
9. **Keep the test checklist** (`dist/TEST-CHECKLIST.md`) with the
   artefacts, so the next person knows what was actually exercised.

## What a release note must contain

- the assets, with sizes and SHA256;
- what changed, and the evidence for each change (a log line, a test, or
  "observed on the display");
- what is still broken, stated plainly;
- the exact hardware and image it was verified on.

If a claim has no witness, it does not go in the release note. Put it in
the lab notebook as a hypothesis instead.
