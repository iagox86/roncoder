---
name: standalone-review
description: Hands-off packaging pass for a single already-encoded video file via standalone-file.rb -- no re-encoding. Finds a representative thumbnail frame if one isn't given, makes a best-effort attempt at metadata (title, year, genre, performer, headshot) via web search, and produces the same poster/fanart/logo/.nfo set as a disc rip.
---

# standalone-review

For a single video file that's already encoded (no HandBrake/re-encode
involved at all) -- runs `standalone-file.rb` to produce the poster,
fanart, logo, and `.nfo` alongside it, the same output shape as a disc rip
via `roncoder.rb`, just for one file instead of a whole disc's chapters.

## Inputs

When invoked, this skill expects, via `args` or the surrounding
conversation:

- the video file's path
- optionally, a thumbnail image. The user often provides one directly --
  if so, use it as-is and skip step 2's frame search entirely.
- optionally, a display title, genre, performer name, and/or other metadata
  hints. Whatever isn't given, try to determine via search (step 3).

## Preconditions

- `magick` (ImageMagick) must be available -- `standalone-file.rb` checks
  this itself and will say so clearly if it's missing.
- This does not touch the video's encoding at all -- if what's actually
  needed is ripping/re-encoding a DVD, this is the wrong skill; use
  `rip-review` instead.

## Steps

1. **Run `standalone-file.rb` once up front**, even before you have a
   thumbnail or metadata, to create the per-video `roncoder.json` skeleton
   and a placeholder `.nfo`:

   ```
   ruby /var/home/ron/projects/roncoding/standalone-file.rb "<video path>"
   ```

   This contains all work to the folder holding the video (matching
   `roncoder.rb`'s behavior) and is safe to re-run -- it reuses the
   existing `roncoder.json` if one's already there instead of resetting it.

2. **Thumbnail.** If the user gave one, skip to step 2e. Also check the
   video's own folder first -- an image file already sitting next to the
   video (not one this skill generated, i.e. not matching
   `<video-basename>[.jpg|-fanart.jpg|-logo.jpg]`) is very likely a
   thumbnail someone already picked out; `Read` it to confirm it's a real
   cover/thumbnail image, and if so treat it the same as a user-provided
   one and skip to step 2e.

   a. **Official cover art beats everything else -- check for it before
      extracting any frames, not just when convenient.** Ron has said he
      prefers official art where possible; treat that as the default, not
      a nice-to-have. If the product/source is identifiable (Penguin
      Magic, theory11, Vanishing Inc, the performer's own site, etc.),
      look there first:

      - `WebFetch` on the product page often gets blocked (Penguin Magic
        and Vanishing Inc 403 every time, confirmed repeatedly). When that
        happens, don't give up -- try `curl` on the page's `og:image` meta
        tag instead, which works even when `WebFetch` doesn't (theory11's
        Shopify-hosted store, for example): `curl -sL "<product url>" |
        grep -oE '<meta property="og:image" content="[^"]+"'`. Also try
        `WebSearch` for a direct image URL (Penguin Magic's CDN image
        URLs, e.g. `images.penguinmagic.com/images/products/...`, often
        turn up directly in search results even though the product page
        itself is unreachable).
      - `Read` whatever candidate you find to confirm it's actually
        cover/box art (not an unrelated banner, the performer's headshot,
        or a generic site logo) before using it.
      - If you truly can't find anything after a genuine attempt, fall
        back to frame extraction (2b onward) -- but that's the fallback,
        not the first move.

   b. If no official cover art is available, fall back to extracting a
      frame from the video. Get the video's duration first (e.g.
      `mediainfo "<video>"`, look for the `Duration` line, same parsing
      `roncoder.rb`'s `get_duration` does).

   c. Sample candidate frames across the video and build contact sheets to
      review efficiently, same method as `rip-review`:
      - First check for a title-card-style intro: one frame per second for
        the first 60 seconds (`ffmpeg -y -ss $t -i "<video>" -frames:v 1
        -q:v 2 out.jpg`), montaged into a contact sheet with
        `magick montage`.
      - If nothing clearly card-like turns up there (a plausible outcome
        for content that isn't chaptered lecture-style, e.g. a single
        interview or performance clip), fall back to sampling evenly across
        the *entire* duration (e.g. 12-16 frames spread from 5% to 95% of
        the runtime) and montage those instead, looking for a
        well-composed, representative frame (performer in frame, not a
        blink/transition/black frame).

   d. Read the contact sheet(s), then `Read` the one or two best full-size
      candidates to confirm before picking a final frame. Extract just that
      one frame to a scratch file, e.g.:

      ```
      ffmpeg -y -ss <seconds> -i "<video>" -frames:v 1 -q:v 2 /tmp/standalone-review-thumb.jpg
      ```

   e. Re-run with the thumbnail (whether user-provided, official cover
      art, or one you extracted):

      ```
      ruby /var/home/ron/projects/roncoding/standalone-file.rb "<video path>" "<thumbnail path>"
      ```

   f. Clean up any scratch frames/contact sheets you created.

3. **Metadata (best-effort).** Same approach and the same helper script as
   `rip-review` (see that skill's Metadata step for the full rationale) --
   summarized here:

   a. **Title.** If the user gave a display title, use it as the trick/
      lesson name, but prefix the `.nfo` title with whichever single
      entity this library's own file/folder naming already credits it
      to -- a specific person or pair of people (`"Garrett Thomas - Ring
      Thing"`), or a publishing company/label when that's the more
      prominent brand (`"theory11 - Five"`, `"Penguin Magic - Best
      Slights for Beginners"`) -- rather than just the bare trick name
      ("Ring Thing", "Five"). When a company publishes a specific named
      performer's technique, this library's existing convention is
      `"Company - Title by Performer"` (e.g. "Penguin Magic - Torched and
      Restored by Brent Braun") -- match that same shape. Skip any prefix
      only when there's no single clear entity to credit (an anthology,
      a panel, three or more performers with no headline company) -- in
      that case just use the plain title. Otherwise, a reasonable guess
      from the filename is fine as a starting point, but say so in the
      summary.

      **Exception: multi-part series/collections.** If this video is one
      part of a multi-video series or collection that already has its own
      named parent folder (e.g. splitting one long video into several
      per-segment items, each in its own subfolder under a shared
      collection folder -- see the Heinous Collection split as the
      precedent), don't prefix the individual parts' titles. The
      containing folder/collection name already carries the performer,
      same reasoning as why a disc's per-chapter titles don't repeat the
      disc's own performer -- only a genuinely standalone single item
      (its own top-level entry with nothing else identifying the creator)
      needs the inline prefix.

   b. **Performer name.** Use what's given, or web search for it. Normalize
      it (strip apostrophes/punctuation not present in this library's
      existing headshot filenames, e.g. "Michael O'Brien" -> stored as
      "Michael OBrien") so the auto-generated `.nfo` thumb URL
      (`actor['name'].gsub(/ /, '-')`) matches the real filename. Stage
      names keep every word capitalized.

   c. **Year and genre.** Web search store listings/release info for a
      year. For genre, infer from what the content actually is -- this
      library covers magic, cooking, lockpicking, and likely more over
      time; don't default to "Magic" if it's clearly something else.

   d. **Director/writer.** Only if the user told you directly or a source
      explicitly credits someone -- don't stretch from a weak inference.

   e. **Apply findings**, without `--force` (never overwrite metadata a
      human already filled in):

      ```
      ruby /var/home/ron/projects/roncoding/apply-metadata.rb \
        --title "Display Title" \
        --year YYYY \
        --genre "Genre" \
        [--director "Name"] [--writer "Name"] \
        --actor-name "Firstname Lastname" \
        --role "Self"
      ```

      This works against `standalone-file.rb`'s config the same as it does
      for a disc's `roncoder.json` -- it checks for a top-level `metadata`
      key first, falling back to `global_config.metadata`.

   f. **Headshot.** Compute the expected path:
      `/home/ron/projects/www.javaop.com/headshots/<Name-With-Dashes>.jpg`.
      If it already exists, leave it alone and note that in the summary.
      Otherwise web search for a photo and download it:

      ```
      curl -Lo "/home/ron/projects/www.javaop.com/headshots/<Name-With-Dashes>.jpg" "<candidate image URL>"
      ```

      This is a separate git repo -- adding a file to its working tree is
      fine, but never `git add`/`commit`/`push` there. If nothing
      reasonable turns up, say so instead of guessing.

4. **Re-run `standalone-file.rb` one final time** after applying metadata,
   so the `.nfo` reflects everything found:

   ```
   ruby /var/home/ron/projects/roncoding/standalone-file.rb "<video path>" "<thumbnail path>"
   ```

5. **Report a summary**: the thumbnail timestamp chosen (and why, if a
   title card vs. a representative frame), and the metadata findings
   (title, year, genre, performer, headshot status) -- clearly labeled as
   best-effort. `plot` is not attempted -- still manual.

## Things this skill must never do

- Never re-encode or otherwise modify the video file itself.
- Never overwrite a metadata field a human already filled in -- don't pass
  `--force` to `apply-metadata.rb` unless the user explicitly asks to
  overwrite.
- Never overwrite an existing headshot file.
- Never run `git add`/`commit`/`push` in the `www.javaop.com` repo (or
  anywhere) -- adding the headshot file to its working tree is as far as
  this goes.
