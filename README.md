# MusicLab

Native macOS music tool: library, player, stem separation (Demucs on the Apple
GPU), dynamic BPM detection with a beat grid, and playlists. No Docker, no
React, no server — just a SwiftUI app plus a bundled Python helper.

## What it does

- Import audio files (mp3/m4a/aac/wav/flac/ogg/opus) by drag & drop or Import
- Play them with seek, volume, shuffle and repeat; tags and cover art are read
  on import
- Waveform drawn in a canvas; click to seek, +/− to zoom up to 32×
- Tempo tracked beat by beat with madmom's RNN + DBN beat tracker (librosa
  as fallback) from the helper venv; a tempo map follows songs that change
  tempo (the chip shows a range), with ÷2 / ×2 octave correction and ↺ to
  re-detect. Without the helper a built-in spectral-flux / autocorrelation
  estimator is used
- **Analyze** separates the track into vocals/drums/bass/other with Demucs —
  running on `mps`, so it uses the GPU, not just the CPU — then detects the BPM
  from the isolated drums stem, which is far cleaner than the full mix
- Per-stem mute / solo / volume fader; the waveform shows the audible mix
- Playlists, `Analyze all` for missing stems and `Re-run all` for re-analysis

## Build & run (development)

```bash
brew install python@3.11        # once
./scripts/setup-venv.sh         # creates helper/venv with demucs + torch + madmom/librosa
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift run
```

The app finds the helper in this order: a `stems-tool` binary bundled in
`MusicLab.app`, `$MUSICLAB_DEMUCS`, `helper/venv/bin/demucs` (dev),
`~/Library/Application Support/MusicLab/venv/bin/demucs`, or `demucs` on the
usual bin paths.

> Note: `swift build` needs the full Xcode toolchain for SwiftUI macros —
> Command Line Tools alone fails with "SwiftUIMacros not found". Point
> `DEVELOPER_DIR` at an Xcode install (here: Xcode-beta).

## Ship it

```bash
./scripts/package-helper.sh   # PyInstaller → helper/dist/stems-tool (big, one-off)
./scripts/dmg.sh              # swift build -c release → build/MusicLab.app → build/MusicLab.dmg
```

`bundle.sh` ad-hoc-signs the app so it launches locally; use a Developer ID
(`codesign --sign "Developer ID Application: …"`) and notarization to share it.

## Environment knobs

| Variable | Default | What it does |
| --- | --- | --- |
| `DEMUCS_MODEL` | `htdemucs` | separation model (`mdx_q` is quantized + faster, `htdemucs_ft` slower + better) |
| `DEMUCS_DEVICE` | `mps` | torch device — `cpu`, `cuda`, `mps` |
| `DEMUCS_JOBS` | unset | parallel workers per track (`demucs --jobs`) |
| `DEMUCS_OVERLAP` | unset | below `0.25` cuts compute at a small quality cost |
| `MUSICLAB_DEMUCS` | unset | explicit helper command, e.g. `/path/to/venv/bin/demucs` |

Data lives in `~/Library/Application Support/MusicLab` (`tracks/`, `stems/`,
`store.json`, `models/` for the downloaded torch model).
