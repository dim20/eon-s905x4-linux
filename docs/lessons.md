# Lessons

Distilled from this project. They are here because each one cost real time, and
because most of them are not specific to this hardware — they are how embedded
debugging goes wrong in general.

---

## 1. Verify the payload before diagnosing the mechanism

The dominant failure of this project. A corrupt kernel file on the eMMC produced
a completely silent boot. That silence was interpreted, over several days, as
evidence about the **bootloader**: that it would not autostart from eMMC, that
the partition naming was wrong, that a USB stick had to be the bootloader.

None of that was tested, because **the kernel never ran**. The conclusion was
drawn from a boot that produced no output.

The fix was one `sha256sum`. It took two minutes. The theorising took a week.

> A boot that produces no output is not evidence about the boot chain. It is
> evidence that you have not verified anything yet.

---

## 2. Run the control before the theory

Twice, a hypothesis was acted on — a DTB was patched, a kernel rebuilt — and the
control that would have settled it was only run afterwards.

The pattern is seductive because the theory feels explanatory. The control feels
like a formality. It is the reverse.

- Ethernet looked like a `stmmac` DMA-reset bug. The control — boot with the
  **known-good** DTB and the same cmdline — showed USB boot was fine all along
  and the silence was a 4 GB memory node on a 2 GB board.
- Boot from USB "worked", so USB was assumed good and eMMC assumed broken. The
  control — hash both — showed the USB copy was pristine and only the eMMC copy
  was corrupt.

---

## 3. A verification that runs in the same context as the thing it verifies may be measuring the wrong thing

The decisive example:

```sh
cp /mnt/u1/d/Image /mnt/p1/Image
sync
sha256sum /mnt/p1/Image     # matches the source
```

That looked like proof the write succeeded. It was reading the **page cache**.
The bytes were never on the storage. Unmount, remount read-only, hash again —
and it failed.

The verification used the same view of the system as the operation. The
unmount/remount cycle is what makes it independent.

> Ask what your check is actually reading.

---

## 4. Read the artefact, not the label

`printenv bootcmd` displayed a working boot command with its inner single quotes
missing. The quotes were present; the display dropped them. Acting on the label
would have discarded a correct configuration.

This is the same shape as lesson 3: the convenient output and the truth came
apart.

The check that settles it is always the one closest to the thing you care about
— the kernel's `Kernel command line:` line, not `printenv`.

---

## 5. Absence of output is not evidence of failure

Several times a test looked like it had failed because there was no output:

- all four cores saturated → **UART goes silent**; the box was fine and recovered
  the instant load stopped
- `apt-get` running → console silent because a foreground process blocked the
  shell
- a binary "Exec format error" deterministically → turned out to execute
  perfectly from a quiet shell; the difference was **load**, not corruption

Before concluding anything from silence, probe with a marker.

---

## 6. Test destructive configuration in a scratch variable

`setenv testcmd "..."` then `run testcmd` is RAM-only. If it fails, a power cycle
discards it.

This caught a CPU reset during `bootcmd` development: the escaped-quote form
reset the box, and because it was never saved, recovery was a power cycle and
nothing else.

The same discipline applied to the Android boot image, partition surgery, and
every installer revision.

> When a configuration can brick something on failure, find the cheapest
> reversible way to test it and use that.

---

## 7. Record what was believed, not just what was found

The project log records the belief that was held *before* each test, alongside
the result. That is what makes the log worth reading: it shows which claims were
never tested, and those turned out to be the expensive ones.

A log that only records conclusions looks identical whether or not they were
verified — and in this project several conclusions were confidently wrong.

---

## 8. Distinguish "not implemented" from "not supported"

This board's U-Boot answers `getvar` for `secure`, `unlocked`, `board`,
`platform`, `soc-type`, `hw-revision` and `current-slot` with *"Variable not
implemented"*.

For a long time this was ambiguous, and conclusions were drawn in both
directions — first that secure boot was fine, later that the box was a dead end.
It is neither. The variables simply do not exist.

`getvar slot-count` returning `2` is real information. A `getvar` that is not
implemented is not.

---

## 9. Prefer the boring mechanism

The Android boot image path (`imgread` / `bootm` / AVB) was attractive because
it is how the box is *designed* to boot, and it would have needed no bootloader
modification at all.

The actual solution was `setenv bootcmd` — one environment variable, no images,
no signatures, no AVB. It took an afternoon once identified.

Before reconstructing a vendor's intended mechanism, check whether the mechanism
you can reach directly is sufficient. Here it was, by a wide margin.

---

## 10. Write the runbook while you still remember being stuck

Half of what this repository contains is documentation written by someone who had
just spent hours on a problem. Written a week later, most of it would have been
written down wrong — with the mistakes removed and the reasoning intact, which
is exactly the version that teaches nothing.

The same applies to recovery procedures: write them while you still know what
the failure felt like.