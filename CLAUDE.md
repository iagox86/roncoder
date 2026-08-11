# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Personal scripts to rip educational/instructional DVDs (magic lecture discs) into a clean Jellyfin/media-server-compatible (same .nfo format as Kodi) library: video + poster/fanart thumbnails + `.nfo` metadata. Originally bash, rewritten in Ruby (see `81b3aeb`). The `legacy/` directory holds the old bash scripts (`roncoder.sh`, `thumbnailer.sh`, `finalize.sh`) kept for reference only -- they are not maintained and should not be edited.

## Running

```fish
ruby roncoder.rb <media file or folder>          # ISO/drive path, or a folder containing exactly one .iso
ruby standalone-file.rb <video> [thumbnail]   # generate poster/fanart/nfo for a single already-encoded file, no re-encode
ruby split-file.rb [--dry-run] <video>            # split one already-encoded video (e.g. a multi-trick compilation) into several output items, no HandBrake/DVD involved
ruby apply-chapter-title.rb --title N [--chapter N] [--name TEXT] [--sort-title TEXT] [--thumbnail-offset MS] [--force]
                                                   # safely set a chapter's title/sort_title/thumbnail_offset in ./roncoder.json
ruby apply-metadata.rb [--title TEXT] [--year YYYY] [--genre NAME] [--director NAME] [--writer NAME] [--actor-name NAME ...] [--role ROLE ...] [--force]
                                                   # safely set the disc title and/or metadata fields in ./roncoder.json
ruby generate-review-pdf.rb [--scan-dir DIR] [--out FILE]
                                                   # build a PDF summarizing every processed disc/video for human review
```

CLI parsing is via the `optimist` gem (see `OPTS`/`ARGV` handling at the top of `roncoder.rb`). Dependencies (`optimist`, `prawn`, `prawn-table`, `rainbow`) are managed via `Gemfile`/`bundler`.

### roncoder.rb workflow

`roncoder.rb` takes one positional argument, which is either:

- a path to a regular `.iso` file -- the script `Dir.chdir`s into the folder containing it, so all work (`roncoder.json`, `tmp_dir`, `out_dir`, etc.) is contained there regardless of where the script was invoked from
- a path to a folder -- same containment, except the script expects the folder to hold exactly one `.iso` file (errors out otherwise) rather than being given the file directly
- a DVD device (e.g. `/dev/sr0`) -- has no meaningful containing folder, so work stays in whatever directory the script was invoked from

If the argument is omitted, it falls back to the old stdin prompt (defaulting to `/dev/sr0`).

Pass `--dry-run` to validate configuration and (if not yet discovered) enumerate titles/chapters via `lsdvd`, without invoking any of the actual rip/thumbnail tools (HandBrake, mediainfo, magick, ffmpeg) and without touching `tmp_dir`/`out_dir`/`thumbnail_tmp_dir` or `roncoder.json`. Useful for sanity-checking a config before committing to a real rip.

It's meant to be run multiple times, each run advancing a stateful `roncoder.json` in the working directory (or the target folder, per above):

1. First run: no `roncoder.json` exists. It writes a default `roncoder.json` (using the resolved ISO/device path and a placeholder `title` derived from the ISO's basename) *and, in the same run*, falls straight through into `lsdvd` title/chapter discovery (see next step) -- there's no longer a separate "write config and exit" run.
2. `roncoder.json` exists but has no `titles`: shells out to `lsdvd` to enumerate titles/chapters, populates `CONFIG['titles']`, writes it back, and exits. Edit this file by hand to fix the real title, crop, quality, metadata, etc. before continuing (or see the `rip-review` skill below for the title-card/thumbnail part of this).
3. With `titles` populated: actually rips each title/chapter via `flatpak run ... HandBrakeCLI`, using `presets.json` as the HandBrake preset file (preset name `Ron`).

New configs default to HandBrake's `--crop-mode auto` (the initial `CONFIG` template explicitly sets `global_config.crop_mode: "auto"`). **A config with no `crop_mode` field at all is treated as `"custom"`, not `"auto"`** -- that's any disc's `roncoder.json` predating this field, back when `--crop-mode custom` was the only behavior; defaulting those to `auto` instead would silently discard their tuned `crop` values and change their `tmp/` cache key, forcing a full wasteful re-encode of every already-ripped chapter (this actually happened -- see `working/Peterson Professional Disk */roncoder.json`, which needed `"crop_mode": "custom"` added explicitly after hitting exactly this). Set a title/chapter's `crop_mode` to `"custom"` (or just omit it) and fill in its `crop` block to override with manual values; set it to `"auto"` to explicitly opt into HandBrake's detection. The `tmp/` cache key includes `crop_mode` (as `"auto"` or the literal crop numbers), so switching modes doesn't reuse a stale rip.

Config resolves per-chapter as a merge: `global_config` -> per-title overrides -> per-chapter overrides (later wins). `roncoder.json` is rewritten after every rip (and in an `ensure` block) so progress and quality adjustments survive a crash/interrupt and reruns skip files that already exist in `tmp_dir` -- the skip check requires `mediainfo` to report a real duration, not just file existence, so a truncated file left behind by a killed/crashed rip gets redone instead of silently copied into `out/` as if it were complete. All writes to `roncoder.json` (in `roncoder.rb` and the three `apply-*.rb`/`standalone-file.rb` helpers) go through an `atomic_write` helper (write to a `.tmp.<pid>` file, then `File.rename`) rather than `File.write` directly -- a process killed mid-write can otherwise leave the file truncated to 0 bytes (happened in practice), and `rename` is atomic so the file on disk is always either the complete old version or the complete new one.

When `global_config.auto_quality` is true, `rip_video_with_bitrate_target` re-rips at quality -1/+1 repeatedly until `mediainfo`-reported bitrate falls inside `[min_bit_rate, max_bit_rate]`, or until `min_quality`/`max_quality` is hit.

Output per title/chapter lands in `out_dir` (default `./out`) as `<NN[-NN]> <title>.mp4` plus matching `.jpg`/`-fanart.jpg`/`-logo.jpg` and `.nfo`. A `folder_thumbnail` (default `./folder.jpg`) is copied into `out_dir` as the disc-level poster; this file must exist or the run aborts.

### standalone-file.rb workflow

For a single already-encoded video (no disc, no re-encoding) -- generates the poster/fanart/logo/`.nfo` set for one file, structured like a trimmed-down `roncoder.rb`:

- Takes `<video> [thumbnail]`; the thumbnail is optional -- omit it to get just the `roncoder.json` skeleton and a minimal `.nfo` (title/sorttitle only), useful as a first pass before a thumbnail/metadata are known.
- Contains all work to the video's own folder (same `Dir.chdir` pattern as `roncoder.rb`'s file case), and creates a `roncoder.json` there on first run with a placeholder `title` (the video's basename), a top-level `metadata` block (same shape as `roncoder.rb`'s, so `apply-metadata.rb` works against it unmodified), and `thumbnail_poster_size`/`thumbnail_fanart_size` defaults. Reruns reuse that file instead of resetting it.
- Output filenames key off the *video's actual filename* (`<video-basename>.jpg`/`-fanart.jpg`/`-logo.jpg`/`.nfo`), not `CONFIG['title']` -- Jellyfin/Kodi require matching basenames to associate local assets with a video file, so the display title (which can be anything) and the filename (fixed by the source video) are intentionally decoupled.
- No `out_dir`/`tmp_dir` split (nothing is cached or re-encoded) -- outputs land directly next to the video.
- `<year>` is omitted from the `.nfo` entirely while still at the untouched-default `0`, so a metadata-less first pass doesn't emit a literal `<year>0</year>`.

### split-file.rb workflow

For a single already-encoded video that actually contains several distinct segments back-to-back (a multi-trick compilation, e.g. `working/standalone-todo/Heinous Collection - Volume 1 (split)` -- created by hand as a precedent before this script existed) -- splits it into one output item per segment via plain `ffmpeg` cuts (re-encode, not stream copy, and no HandBrake/DVD involved at all), producing the exact same flat `out_dir` shape as a disc rip (one shared `roncoder.json`, one `out/` full of `<NN> <title>.mp4/.jpg/-fanart.jpg/-logo.jpg/.nfo` sets, one `folder_thumbnail`) rather than a separate folder per clip:

- Deliberately reuses `roncoder.rb`'s exact `titles`/`global_config` JSON shape (a `titles` hash keyed by number, each entry independently overriding `global_config`, plus a metadata deep-merge for per-item `year`/`plot`/etc.) so `apply-chapter-title.rb` and `apply-metadata.rb` work against it completely unmodified -- `apply-chapter-title.rb --title N` (never `--chapter`) sets a split's `title`/`sort_title`/`thumbnail_offset`/`note`/`year`/`premiered`; `apply-metadata.rb` sets the collection-level `title` and `global_config.metadata`.
- There's no `lsdvd` equivalent for an arbitrary video file, so unlike `roncoder.rb` there's no auto-discovery step: first run just writes the skeleton (`titles: {}`) and exits, and a human (or an agent doing frame-search the same way `rip-review`/`standalone-review` do) hand-adds one entry per segment with `start`/`end` in **seconds** (plain numbers, not `lsdvd`'s `HH:MM:SS.mmm` strings) -- e.g. `"1": { "title": "Segment Name", "start": 68.0, "end": 368.0 }`. Entries missing `start`/`end` are skipped with a warning rather than failing the whole run, so a config can be filled in incrementally.
- Cutting uses `-ss` before `-i` (fast seek) plus `-t <computed duration>` rather than `-to`, since `-to` combined with a seeked input has confusing semantics; a plain `-c copy` stream-copy isn't used because segment boundaries won't reliably land on keyframes, so each cut is a real re-encode (`libx264 -crf 18 -preset medium`). The `tmp/` cache key includes the segment's `start`/`end`, so editing a cut point forces a redo of just that segment, same resumability model as `roncoder.rb`'s `crop_mode`-keyed cache.
- `do_nfo` is the lenient version (matches `standalone-file.rb`: skips `<year>` entirely at `0`, skips blank actor names) rather than `roncoder.rb`'s stricter one that hard-fails without a year -- a split item's metadata is often incomplete by design (an intro/outro clip may have no metadata at all, as in the Heinous precedent).
- No auto-discovery also means no `split_chapters` toggle -- every populated entry in `titles` is one final output item directly, there's no further per-item chapter level underneath it.

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
- `working/` -- gitignored scratch area for in-progress rips (ISOs, extracted videos, per-disc `roncoder.json`/`roncoder.log`/`tmp`/`out`/`thumbnails`). Each disc gets its own subdirectory here, passed to `roncoder.rb` as the folder argument.
- `out/` -- present at repo root but not gitignored; check before assuming it's disposable scratch.
- `apply-chapter-title.rb` -- run from inside a disc folder (next to its `roncoder.json`); sets a title/chapter's `title`, `sort_title`, `thumbnail_offset`, and/or `note`. `sort_title` matters when narrative episode order differs from the disc's physical title/chapter order (Jellyfin sorts by it if present); only set it when the two orders actually diverge -- otherwise `.nfo`'s `sorttitle` already falls back to the zero-padded `"<title>-<chapter> <title text>"` filename, which sorts in disc order for free. `note` is free text for flagging something a human should double check (content issue, mismatched presenter, etc.) -- purely for review tooling, `roncoder.rb`/`.nfo` generation ignores it. Only overwrites a field if it still matches the untouched-default pattern (`Title %02d[ chapter %02d]`) or is unset, unless `--force` is given -- safe to call repeatedly without clobbering human edits.
- `apply-metadata.rb` -- same safety pattern, for the disc-level `title` and `global_config.metadata`'s `year`, `genre`, `director`, `writer`, `plot`, and `actor` (name/role, repeatable for multi-performer discs). Only overwrites a field if it's still at the untouched default (raw ISO/video basename for `title`; `year: 0`, empty string, the single empty-name `Self` actor for metadata) unless `--force` is given. Also usable against `standalone-file.rb`'s per-video config (see below) -- it checks for `metadata` at the top level first, falling back to `global_config.metadata`. `plot` in particular tends to get skipped by the skill's metadata pass (it's explicitly left for a human) -- don't assume it's populated just because everything else is.
- `generate-review-pdf.rb` -- scans every `roncoder.json` under a directory (default `working/`) and builds one PDF for human review: per disc/video, the folder as a clickable `file://` link, cover art, metadata (a missing `plot` is flagged in red, same visual treatment as a `note`d chapter), and actor headshots (read from `/home/ron/projects/www.javaop.com/headshots/`). For discs, one long table with a thumbnail image in the same row as its title/sort_title/thumbnail_offset/note (deliberately not a separate contact-sheet-then-table split -- title and thumbnail need to be reviewable side by side, table length doesn't matter). `note`d rows are highlighted. Pure read-only over `roncoder.json` + already-generated images -- doesn't touch the library itself. Two things worth knowing if you touch this script: (1) Prawn embeds a raw image's full source resolution regardless of display size (`width:`/`fit:` only change how it's drawn, not what's embedded) -- for a table with one image per row, pre-shrink an actual small copy first (see `small_thumbnail`) or the PDF balloons; (2) when sizing a full-page image with `fit:`, size it against `pdf.cursor` (actual remaining space on the page), not a fixed height guess -- Prawn doesn't auto-paginate images, so overshooting the real remaining space even slightly renders it past the page boundary with no error, and it's simply never seen.

### rip-review skill

`.claude/skills/rip-review/SKILL.md` automates the tedious parts of the manual review loop:

- After the default rip, inspects each chapter's opening frames for a title card, reads the on-screen text, and calls `apply-chapter-title.rb` to fill in that chapter's `title`, `thumbnail_offset`, and (when narrative order differs from disc order, e.g. episodic content) `sort_title`. Cross-references an episode list via web search when a card doesn't show its own number, rather than assuming physical disc order matches story order.
- Makes a best-effort attempt at metadata via web search: the disc's display title, release year, genre (not just "Magic" -- this library also has cooking and lockpicking discs), and performer name(s) (all applied via `apply-metadata.rb`), a headshot saved to `/home/ron/projects/www.javaop.com/headshots/<Name-With-Dashes>.jpg` (a separate git repo -- the skill may add a file there but must never commit/push), and DVD cover art saved as the disc's `folder.jpg`. All of this is reported to the human as best-effort, since these lecture discs are often obscure.
- Hoists a thumbnail offset shared by most chapters into `global_config.thumbnail_offset` rather than leaving it as a per-chapter override on every single chapter.
- Re-runs the rip at the end (cheap, since `tmp/` caches the encoded video and this step is really just a rename + thumbnail/nfo regen).

It deliberately never touches `crop`/`crop_mode` (left to `--crop-mode auto`), never overwrites existing headshot/`folder.jpg` files, and never overwrites metadata/chapter fields a human already customized. Only handles `split_chapters: true` discs. `plot` is not attempted -- still manual. Chapter title sanitization only strips `/` (the one character actually unsafe on this filesystem) -- colons and other punctuation are kept, matching this library's existing filename convention.

### standalone-review skill

`.claude/skills/standalone-review/SKILL.md` is the `standalone-file.rb` counterpart to `rip-review`, for a single already-encoded video (no re-encoding involved):

- Runs `standalone-file.rb` to create the `roncoder.json` skeleton, then finds a thumbnail if the user didn't provide one -- same contact-sheet-based frame search as `rip-review`, first checking for a title-card-style intro in the first 60s, falling back to sampling evenly across the whole runtime if the content isn't chaptered/lecture-style.
- Same best-effort metadata pass as `rip-review` (title, year, genre, performer, headshot) via `apply-metadata.rb`, which works unmodified against this per-video config shape.
- No disc-level `folder.jpg` concept here (that's specific to a multi-chapter disc sharing one folder-level poster) -- a standalone file's poster/fanart/logo already live next to it, matched by filename.

## Style notes specific to this repo

`.rubocop.yml` disables most style/metrics cops (line length, method length, complexity, trailing commas, documentation, etc.) -- this is intentionally a loose, script-style ruleset, not idiomatic strict Ruby. Don't "fix" things rubocop would otherwise flag; match the existing loose style (long procedural methods, global-ish `CONFIG` constant, minimal guard clauses).
