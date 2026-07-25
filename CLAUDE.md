# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Personal scripts to rip educational/instructional DVDs (magic lecture discs) into a clean Kodi/media-server-compatible library: video + poster/fanart thumbnails + `.nfo` metadata. Originally bash, rewritten in Ruby (see `81b3aeb`). The `legacy/` directory holds the old bash scripts (`roncoder.sh`, `thumbnailer.sh`, `finalize.sh`) kept for reference only -- they are not maintained and should not be edited.

## Running

```fish
ruby roncoder.rb          # run from inside a per-disc working directory
ruby standalone-file.rb <video> <thumbnail>   # generate poster/fanart/nfo for a single already-ripped file
```

Dependencies (just `rainbow`) are managed via `Gemfile`/`bundler`.

### roncoder.rb workflow

`roncoder.rb` is meant to be run multiple times, from a dedicated directory for one disc (e.g. `working/<Disc Name>/`), each run advancing a stateful `roncoder.json` in that directory:

1. First run: no `roncoder.json` exists. It prompts for the ISO path / DVD device, writes a default `roncoder.json`, and exits.
2. Second run: `roncoder.json` exists but has no `titles`. It shells out to `lsdvd` to enumerate titles/chapters, populates `CONFIG['titles']`, writes it back, and exits. Edit this file by hand to fix titles, crop, quality, metadata, etc. before continuing.
3. Third+ run: with `titles` populated, it actually rips each title/chapter via `flatpak run ... HandBrakeCLI`, using `presets.json` as the HandBrake preset file (preset name `Ron`).

Config resolves per-chapter as a merge: `global_config` -> per-title overrides -> per-chapter overrides (later wins). `roncoder.json` is rewritten after every rip (and in an `ensure` block) so progress and quality adjustments survive a crash/interrupt and reruns skip files that already exist in `tmp_dir`.

When `global_config.auto_quality` is true, `rip_video_with_bitrate_target` re-rips at quality -1/+1 repeatedly until `mediainfo`-reported bitrate falls inside `[min_bit_rate, max_bit_rate]`, or until `min_quality`/`max_quality` is hit.

Output per title/chapter lands in `out_dir` (default `./out`) as `<NN[-NN]> <title>.mp4` plus matching `.jpg`/`-fanart.jpg`/`-logo.jpg` and `.nfo`. A `folder_thumbnail` (default `./folder.jpg`) is copied into `out_dir` as the disc-level poster; this file must exist or the run aborts.

### External tool dependencies

Everything shells out via `system`/backticks -- there's no error handling if these are missing, they just silently fail or blow up:

- `lsdvd` -- enumerate DVD titles/chapters
- `flatpak run --command=HandBrakeCLI fr.handbrake.ghb` -- the actual rip (HandBrake CLI via flatpak, not a native binary)
- `mediainfo` -- read back bitrate/duration of a ripped file to drive the auto-quality loop
- `magick` (ImageMagick) -- resize thumbnails into poster/fanart/logo variants
- `ffmpeg` -- grab a thumbnail frame from the ripped video at `thumbnail_offset`

### Files

- `presets.json` -- HandBrake preset export, must contain a preset named `Ron`; referenced by `roncoder.rb` as `handbrake_config`.
- `metadata.nfo` -- template `.nfo` copied into a finished disc's output folder by hand, per the old workflow in README.md; fill in everything except `NN`/`Title` (those come from per-file `.nfo`s written by `roncoder.rb`).
- `working/` -- gitignored scratch area for in-progress rips (ISOs, extracted videos, per-disc `roncoder.json`/`roncoder.log`/`tmp`/`out`/`thumbnails`). Each disc gets its own subdirectory here and that's where `roncoder.rb` is actually invoked from.
- `out/` -- present at repo root but not gitignored; check before assuming it's disposable scratch.

## Style notes specific to this repo

`.rubocop.yml` disables most style/metrics cops (line length, method length, complexity, trailing commas, documentation, etc.) -- this is intentionally a loose, script-style ruleset, not idiomatic strict Ruby. Don't "fix" things rubocop would otherwise flag; match the existing loose style (long procedural methods, global-ish `CONFIG` constant, minimal guard clauses).
