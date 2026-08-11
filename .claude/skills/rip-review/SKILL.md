---
name: rip-review
description: Hands-off post-rip pass for a roncoder.rb disc folder. Runs the default rip, inspects each chapter's opening frames to detect a title card, reads the on-screen text, and sets the chapter title + thumbnail_offset in roncoder.json. Also makes a best-effort attempt at metadata -- disc title, release year, genre, performer name(s), a headshot in the www.javaop.com repo, and DVD cover art -- via web search, for human review. Does not touch cropping (left to HandBrake's --crop-mode auto).
---

# rip-review

Automates the tedious part of `roncoder.rb`'s review loop: looking at each
chapter's video to find a title card and typing its text into
`roncoder.json`, plus a best-effort pass at filling in metadata (title,
year, genre, performer, headshot, cover art) via web search. Cropping is
left alone (HandBrake's `--crop-mode auto` handles it).

## Inputs

When invoked, this skill expects, via `args` or the surrounding
conversation:

- the disc folder or `.iso` path (same as always, passed straight to
  `roncoder.rb`)
- a human-readable title to search for -- the marketing/product title (e.g.
  "Vegan Black Metal Chef 2" or "Garrett Thomas - Ring Thing"), which may
  differ a lot from the raw ISO label. This also becomes the disc's
  `CONFIG['title']` (see step 4a) -- if not given, fall back to whatever
  `CONFIG['title']` currently is.
- optionally, the performer's name and/or genre, if already known (e.g.
  "Magic", "Cooking", "Lockpicking" -- these discs cover more than just
  magic). If not given, try to determine them via search (see Metadata
  step below).

## Preconditions

- This only handles the `split_chapters: true` case (one file per chapter).
  If `roncoder.json` has `"split_chapters": false`, stop and tell the user
  this skill doesn't support that mode yet.
- Requires `roncoder.json` to exist. If it doesn't, run
  `ruby roncoder.rb <path>` first -- this single invocation now creates the
  config AND discovers titles/chapters via `lsdvd` in one shot.

## Steps

1. **cd into the disc folder.** If given an `.iso` path, `cd` to its
   containing directory; if given a folder, `cd` into it directly. All the
   commands below assume you're running from inside that folder, next to
   `roncoder.json`.

2. **Ensure there's a default rip to inspect.** Run:

   ```
   ruby /var/home/ron/projects/roncoding/roncoder.rb .
   ```

   (Or whatever path you were given -- once `roncoder.json` already has
   `titles` populated, this rips every title/chapter with default names and
   `--crop-mode auto` into `tmp/` and `out/`.) If chapters/titles aren't
   populated yet, this call will populate them and exit -- run it a second
   time to actually rip.

   Rips of a full disc can take a long time (well past a normal command
   timeout) -- run it in the background and poll/wait rather than blocking.

   **Do not run `apply-chapter-title.rb` or `apply-metadata.rb` while a
   `roncoder.rb` rip is still running in the background.** `roncoder.rb`
   loads `roncoder.json` into memory once at startup and rewrites the whole
   file after every chapter (and again on exit), so any edit the helper
   scripts make while a rip is in flight gets silently clobbered the next
   time `roncoder.rb` saves. Wait until the rip process has fully exited
   before running either helper script, then proceed to step 3.

3. **For each chapter in `roncoder.json`'s `titles.<N>.chapters.<M>`:**

   **Thumbnail priority: a title card beats a representative action frame,
   always try the card first.** This still applies even when the chapter's
   *title text* is already known from another source (e.g. an authoritative
   numbered list sitting in `metadata.plot` -- seen on the Peterson
   Professional discs). Knowing the text doesn't mean skipping the visual
   card search -- the thumbnail should still use an actual on-screen title
   card when one exists, and different chapters on the same disc can vary
   (some Peterson chapters had no card at all and cut straight to the
   presenter talking; one had a lower-third card reading "Pro-1 Walkthrough"
   that didn't match the plot-derived title and was missed entirely because
   the card search got skipped that time). Only skip straight to picking a
   clean representative frame of the action (3d's fallback) for chapters
   where you've actually checked and confirmed no card exists.

   a. Find its ripped file in `out/` -- named like
      `NN-MM <current title>.mp4` (the current title is whatever's in the
      config right now, likely still the default `Title NN chapter MM`).

   b. Skip chapters whose `title` no longer matches the default pattern
      `Title %02d chapter %02d` -- that means a human already renamed it,
      so leave it alone.

   c. Extract one frame per second for the first 60 seconds of the chapter.
      Title cards can land anywhere in that window (some discs front-load
      a logo/disclaimer bumper before the actual title card), and the
      extra ffmpeg time is worth it versus missing the card. Use a scratch
      directory, e.g.:

      ```
      mkdir -p /tmp/rip-review-frames/NN-MM
      for t in $(seq 0 60); do
        ffmpeg -y -ss $t -i "out/NN-MM <title>.mp4" -frames:v 1 -q:v 2 \
          "/tmp/rip-review-frames/NN-MM/$(printf %02d $t).jpg" 2>/dev/null
      done
      ```

      Don't `Read` all 61 of these individually -- that's a lot of images
      per chapter. Instead build one or two contact-sheet grids with
      ImageMagick so you can scan them in a couple of `Read` calls:

      ```
      magick montage "/tmp/rip-review-frames/NN-MM/*.jpg" \
        -tile 10x -geometry 320x180+2+2 -label '%f' \
        "/tmp/rip-review-frames/NN-MM-contact.jpg"
      ```

      (Split into two montages if 61 tiles renders too small to read the
      labels/text.) Read the contact sheet(s), pick the one or two
      timestamps that look like a legible title card, then `Read` those
      specific full-size frames individually to confirm the exact text and
      settle on the single best timestamp.

      If nothing legible turns up in the 60s window, it's fine to sample a
      bit further out before giving up -- but don't keep expanding
      indefinitely. What "giving up" means depends on whether the title
      text is already known from elsewhere (e.g. a plot-derived list): if
      it is, a missing card is a fully acceptable outcome -- fall back to
      picking a clean representative frame of the action for the thumbnail
      (same criteria as 3d) and move on, no need to flag it. If the title
      text is *not* already known and no card ever turns up, that's when
      you flag the chapter for manual review (see 3h) instead of guessing.

   d. Decide: is there a clear, legible title card (on-screen text naming
      the trick/lesson/episode)? If several frames show it, prefer the one
      where the text is most fully on screen and least obscured by a
      transition/fade. Some chapters have a second, later card (e.g. an
      "ingredients"/instructional card right after the episode-identifying
      one) -- prefer the earlier, episode-identifying card as the title.

      No card found (title text already known from elsewhere): fall back
      to a clean representative frame instead -- the presenter/subject
      visible and in focus, mid-action if it's a demonstration, not a
      blink/transition/black frame or a generic disclaimer/copyright card.

   e. **Episode numbering.** If the card includes an explicit number (e.g.
      "Episode 4"), keep it. If it doesn't, don't just drop the number --
      for serial/episodic content (as opposed to a standalone lecture), the
      disc's physical title/chapter order does **not** necessarily match
      narrative episode order (seen in practice: a disc where title 9 was
      "Episode 4" while title 4 turned out to be "Episode 5"). Web search
      for an episode list/guide for the series to cross-reference numbering
      before finalizing, rather than assuming physical order == episode
      order. If you still can't determine a number, proceed without one and
      flag it in the summary.

      **Only set `sort_title` if narrative order actually differs from
      physical disc order.** When `sort_title` is unset, the `.nfo` falls
      back to `base_filename` (`roncoder.rb`'s `do_nfo`), which is
      `"<title>-<chapter as %02d> <title text>"` -- already zero-padded by
      physical title/chapter number, so it already sorts in disc order for
      free. If disc order happens to match the order a viewer should watch
      in (checked this on the Vegan Black Metal Chef Year 2 disc -- its
      episodes run 11-20 in physical order already, extras afterward,
      nothing to fix), don't add `sort_title` at all -- it'd be redundant,
      and one more field to keep in sync. Only reach for it when the two
      orders genuinely diverge (Year 1: title 9 was "Episode 4", title 4
      was "Episode 5" -- disc order alone would have played them wrong).

      When you do need it, format it as a readable, zero-padded string
      matching the title's own style -- `"Episode 04: Hail Seitan"`, not a
      bare `"04"` -- via `apply-chapter-title.rb --sort-title "..."`. A bare
      number sorts fine but throws away the readability a human skimming
      `roncoder.json` or a file listing would want.

   f. Sanitize the text for use in a filename -- join multiple lines with a
      single space, collapse repeated whitespace, trim. Only strip/replace
      the one character that's actually unsafe on this filesystem: `/`
      (and any NUL byte). Do **not** strip colons, `#`, `!`, or other
      punctuation the card actually displays -- this library's existing
      convention keeps them (e.g. `"Episode 1: Pad Thai.mp4"`), and ext4
      handles them fine.

   g. Apply the result with the helper script (it re-checks the
      untouched-default condition itself, so it's safe to call even if you
      re-run this skill later):

      ```
      ruby /var/home/ron/projects/roncoding/apply-chapter-title.rb \
        --title N --chapter M \
        --name "Sanitized Title" \
        --thumbnail-offset "4000ms" \
        [--sort-title "Episode 04: Hail Seitan"]
      ```

      Use the timestamp (in ms) of whichever candidate frame you picked as
      `--thumbnail-offset`.

   h. If no legible title card was found in any candidate frame, don't call
      the helper script for that chapter -- just note it in the final
      summary as needing manual attention.

   i. Delete the scratch frames for this chapter once you're done with it.

4. **After all chapters are processed:**

   a. Set the disc-level display title (decoupled from filenames -- this
      only affects `CONFIG['title']`, used for the final rsync-destination
      hint, not any `.nfo`):

      ```
      ruby /var/home/ron/projects/roncoding/apply-metadata.rb --title "<marketing title from Inputs>"
      ```

   b. If most chapters ended up with the same `thumbnail_offset`, hoist
      that value into `global_config.thumbnail_offset` (so it's the real
      default instead of the stale `"3000ms"` placeholder) and only leave
      per-chapter `thumbnail_offset` overrides on the outliers. Edit
      `roncoder.json` directly for this (there's no helper script for it --
      it's a single scalar, not worth a dedicated CLI flag). Remove the
      now-redundant per-chapter overrides that matched the old default.

5. **Metadata (best-effort).** This whole step is best-effort -- web search
   results for these lecture discs are often thin, so don't spend forever
   on it, and always surface what you found (or didn't) in the final
   summary rather than silently guessing.

   a. **Performer name.** If the user gave a name directly, use it as-is.
      Otherwise, web search for the title (e.g. `"<title>" magic lecture
      DVD`) and look at store listings, reviews, or video pages for who
      performs it. These discs are frequently a single performer across
      every role, so one name usually covers it -- but check for
      panel/multi-performer discs too (see `Panel-Discussion.jpg` in the
      headshots folder for a precedent).

      Normalize the name: strip apostrophes and other punctuation the
      existing headshot filenames don't have (e.g. "Michael O'Brien" is
      stored as `Michael-OBrien.jpg`, i.e. the stored name is "Michael
      OBrien" with no apostrophe) so the auto-generated URL in the `.nfo`
      (see `roncoder.rb:408`, `actor['name'].gsub(/ /, '-')`) actually
      matches the real filename. Stage names keep every word capitalized,
      e.g. "The Vegan Black Metal Chef".

   b. **Release year.** Web search the same store listings / release
      announcements / video upload dates for a year.

   c. **Genre.** If the user gave one, use it. Otherwise infer it from
      what the disc actually is -- these discs aren't all magic lectures;
      cooking and lockpicking discs exist in this library too (and there
      will be more categories over time). Use a short, simple genre string
      (e.g. "Magic", "Cooking", "Lockpicking"); don't overthink it.

   d. **Director/writer.** Only fill these in if the user told you
      directly, or a store listing explicitly credits someone (these are
      often the same person as the performer for a one-person lecture
      disc). Don't stretch to fill these in from a weak inference -- it's
      fine to leave them blank for a human.

   e. **Apply what you found**, without `--force` (never overwrite metadata
      a human already filled in):

      ```
      ruby /var/home/ron/projects/roncoding/apply-metadata.rb \
        --year YYYY \
        --genre "Genre" \
        [--director "Name"] [--writer "Name"] \
        --actor-name "Firstname Lastname" ["Second Performer" ...] \
        --role "Self" ["Role Two" ...]
      ```

      (`--director`/`--writer`/`--role` are all optional; omitted roles
      default to `"Self"`.) The script only writes fields that are still
      at their untouched default, same safety pattern as
      `apply-chapter-title.rb`.

   f. **Headshot.** Compute the expected path:
      `/home/ron/projects/www.javaop.com/headshots/<Name-With-Dashes>.jpg`
      (spaces to dashes, using the normalized name from step a). This is a
      separate git repo -- adding a new file to its working tree is fine,
      but never `git add`/`commit`/`push` there.

      - If a file already exists at that exact path (any extension), leave
        it alone and note it's already present.
      - Otherwise, web search for a photo of the performer (bio/press page,
        store listing, YouTube channel avatar, etc.), pick the clearest
        candidate, and download it:

        ```
        curl -Lo "/home/ron/projects/www.javaop.com/headshots/<Name-With-Dashes>.jpg" "<candidate image URL>"
        ```

      - If nothing reasonable turns up, say so in the summary instead of
        guessing.

   g. **Folder art (DVD cover).** Web search for the DVD's cover (store
      listing product image is usually the best source). If `folder.jpg`
      doesn't already exist in the disc folder, download the best
      candidate:

      ```
      curl -Lo folder.jpg "<candidate image URL>"
      ```

      Never overwrite an existing `folder.jpg` without asking first.

6. **Re-run the rip** once all chapters are processed:

   ```
   ruby /var/home/ron/projects/roncoding/roncoder.rb .
   ```

   Since quality/crop_mode didn't change, this reuses the cached files in
   `tmp/` -- it's essentially just copying + renaming + regenerating
   thumbnails/nfo, not re-encoding.

7. **Report a summary** to the user: a table of chapter -> proposed title ->
   sort_title (if set) -> thumbnail offset -> status (applied /
   skipped-already-customized / needs-manual-review), plus the metadata
   findings -- disc title, year, genre, performer name(s), headshot status
   (already present / downloaded from <source> / not found), folder art
   status (already present / downloaded from <source> / not found) --
   clearly labeled as best-effort. Remind them to:
   - Look over `out/` for anything the auto-crop got wrong
   - Confirm the thumbnails/titles actually look right
   - Verify the metadata this skill filled in (`plot` still needs a human
     either way -- this skill doesn't attempt it)

## Large re-review passes: checkpoint your progress

A full re-review of every chapter on a large disc (e.g. redoing all
thumbnails disc-wide with a new priority/criteria) can be tens of chapters
of frame extraction + contact sheets + vision review -- expensive enough
that a single background agent run can hit a session/usage limit before
finishing. Learned the hard way on the Peterson Professional discs: two
consecutive attempts at an 81-chapter thumbnail redo both died partway
through an API session limit, and because there was nothing recording
*which* chapters had already been redone, each retry started over from
chapter 1 -- burning a full session's budget per attempt for a net result
of zero completed discs.

If you're doing this kind of disc-wide re-review pass (not the normal
one-time flow in Steps 2-6, which is naturally incremental since it only
touches untouched-default chapters to begin with), checkpoint as you go:

- Keep a small sidecar progress file in the disc folder, e.g.
  `.rip-review-progress.json` -- NOT part of `roncoder.json`, this is pure
  bookkeeping for the pass itself, not disc/library metadata. A flat JSON
  array of `"title-chapter"` strings already handled is enough, e.g.
  `["1-1", "1-2", "2-1"]`.
- At the start of the pass, read this file if it exists and skip any
  chapter already listed -- don't redo it.
- After finishing each individual chapter (not batched at the end),
  append its key to the file and write it immediately. This is the whole
  point: if the process dies mid-chapter-50, chapters 1-49's work is
  provably saved and a retry picks up at 50, not 1.
- Once the entire pass is genuinely complete (every chapter checked), it's
  fine to delete the sidecar file -- its job was just to survive retries
  during the pass, not to persist forever.
- If you're the one *dispatching* this kind of pass (not the agent doing
  the work), consider splitting it into several smaller batches (by title
  range, e.g. 10-15 chapters each) up front rather than one huge run --
  smaller batches are far more likely to complete inside a single session,
  and a failure only costs you that batch, not the whole disc.
- If there's no urgency (check with the user, or just ask -- Ron said this
  explicitly once: "it's okay to do this slowly... I don't need results
  for 8+ hours"), have the agent doing the work actually pace itself with
  real pauses between small groups of chapters (e.g. process 4-5, then
  `sleep 1800`, repeat) instead of running flat-out. Combined with
  checkpointing, this is a legitimate way to spread a large pass across a
  long window without pressure to finish in one continuous burst.

## Things this skill must never do

- Never edit `crop` or `crop_mode` (auto-crop is the default and is left
  alone here).
- Never overwrite a chapter title/sort_title/thumbnail_offset, or a
  metadata field, that a human already set -- don't pass `--force` to
  either helper script unless the user explicitly asks to overwrite.
- Never touch chapters whose title doesn't match the untouched-default
  pattern.
- Never overwrite an existing headshot file or an existing `folder.jpg`.
- Never run `git add`/`commit`/`push` in the `www.javaop.com` repo (or
  anywhere) -- adding the headshot file to its working tree is as far as
  this goes.
