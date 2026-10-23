# Audio

The box has a working ALSA stack on its Amlogic ASoC card. HDMI audio
**plays**, and it was heard on the television on **2026-10-23** — but only
after one routing control is set, because the vendor's default points the
HDMI transmitter at the wrong input.

---

## The card

`card 0: AMLAUGESOUND [AML-AUGESOUND]`. The playback devices:

| Device | Name | What it is |
|---|---|---|
| `hw:0,0` | `TDM-A-dummy-alsaPORT-pcm` | TDM A |
| `hw:0,1` | `TDM-B-T9015-audio-hifi-alsaPORT-i2s` | the T9015 analog codec (line-out, if the board has one) |
| **`hw:0,2`** | **`TDM-C-dummy-alsaPORT-i2s2hdmi`** | **the HDMI audio path** |
| `hw:0,4` | `SPDIF-dummy-alsaPORT-spdif` | SPDIF |
| `hw:0,5` | `SPDIF-B-dummy-alsaPORT-spdifb` | SPDIF B |

The mixer exposes the vendor's controls, including
`HDMITX Audio Source Select`, `Audio I2S to HDMITX Format`,
`Audio hdmi-out mute`, and a large `AED`/`DAC` set.

## The trap: the HDMI source defaults to Spdif

`HDMITX Audio Source Select` has five items:

```
Spdif   Spdif_b   Tdm_A   Tdm_B   Tdm_C
```

**Its default is `Spdif`.** The HDMI playback path is `Tdm_C` (the
`i2s2hdmi` device, `hw:0,2`). Opening `hw:0,2` and playing with the default
in place reaches ALSA, runs the stream, and produces **no sound** — the
transmitter is listening to SPDIF, not to TDM-C.

Set it to `Tdm_C` and the same stream is audible.

## What works, and how

```
amixer -c0 sset 'HDMITX Audio Source Select' 'Tdm_C'
amixer -c0 sset 'Audio hdmi-out mute' off
speaker-test -D hw:0,2 -t sine -f 440 -c 2 -l 2
```

**Verified 2026-10-23:** a 440 Hz sine on `hw:0,2` (48 kHz, S16_LE, stereo)
was heard on the television. Against the same stream with the default
`Spdif`, it was not.

`Speaker-test` reports the stream as accepted either way — ALSA saying "OK"
does not mean sound left the box. The transmitter logs a `set audio` line
when the stream starts, but that does not mean the right input was selected
either. The mixer control is the difference.

## Making it the default

The image ships `eon-hdmi-audio.service`, a oneshot unit that runs the two
`amixer` lines above at boot, after `sound.target` and after
`alsa-restore.service`. Without it a fresh image is silent on HDMI until
someone sets the control by hand.

On a running box, the setting can also be persisted with:

```sh
alsactl store
```

which writes `/var/lib/alsa/asound.state`; `alsa-restore.service` then
restores it at boot.

## Not verified

- **The T9015 analog codec** (`hw:0,1`): no speaker was plugged into any
  line-out, so it was not tested. Do not claim it works.
- **SPDIF** (`hw:0,4`, `hw:0,5`): not tested; the HDMI source would have to
  be `Spdif`/`Spdif_b` for it to reach the transmitter.
- **Multichannel / passthrough** (AC-3, DTS, …): the transmitter advertises
  them in `aud_cap`, but only stereo PCM was tried.
- **Volume calibration.** The test was at a comfortable TV volume, not
  measured. There is no claim about loudness or distortion.

## Troubleshooting

- **Silence, and `speaker-test` says the stream ran.** Check
  `amixer -c0 sget 'HDMITX Audio Source Select'` — it must be `Tdm_C` for
  `hw:0,2`.
- **Still silent.** Check `Audio hdmi-out mute` is `off`, and
  `Audio I2S to HDMITX Format` is `Stereo PCM`.
- **Silence on SPDIF.** Set the source to `Spdif` and play `hw:0,4`.

---

## Last verified

**2026-10-23**, eMMC system (`/dev/mmcblk0p2`), HDMI to a television:
440 Hz sine on `hw:0,2` audible after setting `HDMITX Audio Source Select`
to `Tdm_C`; inaudible with the vendor default `Spdif`. Analog and SPDIF
paths not tested.