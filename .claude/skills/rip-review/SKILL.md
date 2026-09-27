---
name: rip-review
description: Hands-off post-rip pass for a roncoder.rb disc folder. Runs the default rip, inspects each chapter's opening frames to detect a title card, reads the on-screen text, and sets the chapter title + thumbnail_offset in roncoder.json. Also makes a best-effort attempt at metadata -- disc title, release year, genre, plot/synopsis, performer name(s), a headshot in the www.javaop.com repo, and DVD cover art -- via DVD packaging text and web search, for human review. Does not touch cropping (left to HandBrake's --crop-mode auto).
---

# rip-review

Automates the tedious part of `roncoder.rb`'s review loop: looking at each
chapter's video to find a title card and typing its text into
`roncoder.json`, plus a best-effort pass at filling in metadata (title,
year, genre, plot, performer, headshot, cover art) via DVD packaging text
and web search. Cropping is left alone (HandBrake's `--crop-mode auto`
handles it).

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

- Requires `roncoder.json` to exist. If it doesn't, run
  `ruby roncoder.rb <path>` first -- this single invocation now creates the
  config AND discovers titles/chapters via `lsdvd` in one shot.
- The disc's `split_chapters` setting (chapter-per-file vs title-per-file) is
  not assumed -- it's a real decision to make per disc, by actually ripping
  both ways and comparing the output. See Step 2.
- `out/` throughout this document is shorthand for the disc's actual output
  folder -- `roncoder.rb` now derives `out_dir` from `CONFIG['title']`
  (e.g. `./Torn and Restored Tissue/`, not literally `./out/`), so it's
  upload-ready without a manual rename. Substitute the real folder name
  when actually running these commands.

## Steps

1. **cd into the disc folder.** If given an `.iso` path, `cd` to its
   containing directory; if given a folder, `cd` into it directly. All the
   commands below assume you're running from inside that folder, next to
   `roncoder.json`.

2. **Decide the split strategy, then get a default rip to inspect.**

   a. If `roncoder.json` doesn't exist yet, run:

      ```
      ruby /var/home/ron/projects/roncoding/roncoder.rb .
      ```

      (Or whatever path you were given.) This creates the config AND
      discovers titles/chapters via `lsdvd` in one shot, then exits without
      ripping -- it uses whatever `split_chapters` default the config
      template currently has (`true`).

   b. **Don't trust `lsdvd`'s title/chapter counts or lengths blindly** --
      cross-check with HandBrake's own scanner before committing to a real
      rip. `lsdvd` can be flatly wrong (seen in practice: a bogus
      single-chapter/9.9-second title where the real disc was a full hour
      with 29 real chapters) or structurally misleading (a "title" that
      turned out to be a duplicate/alias of another title's content minus
      its intro chapter, confirmed by matching per-chapter durations):

      ```
      flatpak run --command=HandBrakeCLI fr.handbrake.ghb --scan -i <iso> -t 0
      ```

      Check real title count, real chapter count per title, and real
      per-chapter durations. Wildly uneven chapter lengths aren't
      automatically noise to collapse away -- they're often one distinct
      topic/routine per chapter, which is exactly the granularity you want.
      A `7z l <iso>` listing of `VIDEO_TS/VTS_*.VOB` sizes is a useful
      independent cross-check: one VTS per title with wildly different sizes
      across titles is strong evidence of genuinely separate titles (not
      just chapters within one continuous feature); a single shared VTS
      split only by the 1GB-per-file limit is evidence of one continuous
      title regardless of what the chapter count claims.

   c. **Rip it both ways and compare the real output before committing --
      don't decide from scan numbers alone.** A scan-reported "0-duration"
      chapter turned out, when actually encoded, to be a genuinely broken
      ~34-millisecond file (ffmpeg couldn't even pull a thumbnail frame from
      it) -- that's a stronger confirmation than trusting the number. Flip
      `roncoder.json`'s `split_chapters` and reshape `titles` to match
      (nested `chapters` sub-hash per title when `true`; flat
      `{title, length}` per title when `false` -- match the exact shape
      `roncoder.rb`'s own discovery code produces for each mode), rip both,
      and look at what actually lands in `out/`:

      - Prefer whichever mode gives **one file per distinct concept** --
        normally the thing each concept's own on-screen title card
        announces. Too-fine splitting looks like several files that are
        really just one trick's card + demo + explanation, artificially cut
        apart. Too-coarse splitting looks like one file that visibly jumps
        between unrelated topics/title cards with no split at that boundary.
      - This varies disc to disc, not just chapter vs. title in the
        abstract -- some discs are naturally chapter-per-concept (many
        short, unevenly-timed chapters within one continuous title, e.g. a
        lecture recorded straight through with a new chapter marker dropped
        in at each new trick), others are naturally title-per-concept (each
        concept authored as its own separate VTS/title, e.g. a menu-driven
        disc where each topic is its own selectable item).
        `roncoder.json`'s `split_chapters` is a single switch for the whole
        disc, not settable per-title, so this is a whole-disc decision.
      - Once decided, delete the losing mode's `out/` files and its
        chapter-or-title-level `tmp/` cache files (cheap to regenerate later
        if the decision ever gets revisited) and keep the winning mode's
        `roncoder.json` shape.

   Rips of a full disc can take a long time (well past a normal command
   timeout) -- run each in the background and poll/wait rather than
   blocking.

   **Do not run `apply-chapter-title.rb` or `apply-metadata.rb` while a
   `roncoder.rb` rip is still running in the background.** `roncoder.rb`
   loads `roncoder.json` into memory once at startup and rewrites the whole
   file after every chapter (and again on exit), so any edit the helper
   scripts make while a rip is in flight gets silently clobbered the next
   time `roncoder.rb` saves. Wait until the rip process has fully exited
   before running either helper script, then proceed to step 3.

3. **For each chapter in `roncoder.json`'s `titles.<N>.chapters.<M>`:**

   **First, before iterating chapters: run `extract-dvd-menu.rb` on the
   whole disc up front -- this is now the recommended default, not a
   last-resort fallback for card-less chapters.** Confirmed on the
   2026-08-12 originals2-batch2 pass (Romaine + Garrett Thomas discs) to
   catch real errors that frame-by-frame reading alone missed or got
   wrong, at low cost (one `dvdunauthor` decode per disc, reused for the
   whole pass): it resolved the single most stubborn card-less chapter in
   that batch (a 27-minute Garrett Thomas chapter with zero on-screen
   caption despite exhaustive sampling -- a dedicated "Explanations" menu
   page named it directly), corrected an invented placeholder title, and
   caught a genuine disc-authoring inconsistency between a menu label and
   its chapter's own on-screen card. See `working/originals2-status.md`'s
   "extract-dvd-menu.rb cross-check" section for the full writeup. Run:

   ```
   ruby /var/home/ron/projects/roncoding/extract-dvd-menu.rb <iso>
   ```

   No `--out-dir` needed -- it defaults to a `dvd-menu-<basename>` folder
   next to the ISO itself (same containment pattern as `roncoder.rb`), so
   the report lands inside the disc's own `working/` folder regardless of
   which directory you ran the command from, instead of cluttering the
   repo root. Only pass `--out-dir` if you want it somewhere else.

   Then read **every** menu page screenshot in its output dir (not just pages
   linked from card-less chapters) before starting the per-chapter frame
   pass below -- many discs have a "Performances"/"Explanations"-style
   split where the SAME trick gets two different chapters (a bare
   performance clip and a separate explained breakdown), and the menu is
   often the only place that distinction is named. Use the menu's
   button-to-chapter mapping (see step i2 below for the mechanics and the
   validated ~92% accuracy/known caveats) as a primary source alongside
   each chapter's own on-screen card, not only when the card search comes
   up empty -- cross-check the two against each other rather than trusting
   either alone, and prefer the on-screen card's exact wording when the two
   disagree (the menu button is often an abbreviated/inconsistent label,
   not necessarily the authoritative text). If the disc's chapter
   boundaries come back all `0:00:00.000` in the report (seen on some
   discs with non-standard authoring, unlike the tool's original Meir
   Yedid validation disc), don't trust the automatic boundary/offset
   detection -- the menu page screenshots and button->chapter-number
   mapping are still useful on their own, just verify button counts
   against visible on-screen item counts more carefully.

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

   c2. **A title card can also sit at the END of the PRECEDING chapter,
      announcing the one that follows, rather than at the start of its own
      chapter.** Confirmed in practice on "Who's Afraid of Invisible
      Thread": the "Erectile Bill" card appeared in the last ~10% of
      chapter 11's file, not anywhere in chapter 12 itself (the chapter it
      names) -- and, undetected at the time, this exact pattern is what
      caused a real cascading mislabeling bug across that whole disc (see
      `working/originals2-status.md`): a forward-only search on short
      chapters kept running past their own end and grabbing the *next*
      trick's card instead, so every other chapter ended up holding the
      wrong name. If step c's forward search of *this* chapter's first 60s
      comes up empty, before falling through to the DVD menu (3i2) or
      flagging for manual review (3i), also sample the last ~15-30 seconds
      of the *preceding* chapter's already-ripped file
      (`out/NN-(MM-1) <title>.mp4`) with the same contact-sheet approach --
      **but only if that preceding chapter is itself at least ~15-30
      seconds long** (check with `mediainfo`). A shorter preceding chapter
      doesn't have room to safely sample "the last 15-30 seconds" without
      running past its own start and misattributing a card that actually
      belongs to the chapter *before* it instead -- skip the backward check
      entirely in that case and fall through to 3i2/3i as usual.
      If a card naming this chapter's content turns up there, use it for
      the title text, *and* see c3 below to actually use that same frame as
      this chapter's thumbnail image too -- `--thumbnail-offset` alone
      can't reach it (that offset is always relative to this chapter's own
      output file), but `roncoder.rb` has a separate mechanism for exactly
      this.

   c3. **Reuse a card image across chapters via `manual_thumbnail` when one
      physical card covers more than one chapter -- e.g. a Method chapter
      and its paired Performance chapter for the same trick, which often
      share a single on-screen card rather than each getting its own.**
      `roncoder.rb` already supports this (`rip_thumbnail`/`manual_thumbnail`
      in `global_config`, checked in `do_thumbnail` -- see `roncoder.rb`
      around line 370): when a chapter's `rip_thumbnail` is `false` and
      `manual_thumbnail` points at an existing image file, that file is
      used directly as the poster/fanart/logo source instead of grabbing a
      frame from the chapter's own video via `thumbnail_offset`. No code
      changes needed to use this -- it just isn't wired up by
      `apply-chapter-title.rb`, so set it by editing `roncoder.json`
      directly.

      Procedure (validated on all 11 Method/Performance pairs of "Who's
      Afraid of Invisible Thread", 10 of which shared a real card):
      1. Find the chapter that actually has the legible card (per c/c2
         above) and extract that exact frame at full source resolution
         into a stable location in the disc folder, e.g.
         `card-frames/chNN.jpg` (one file per shared card, NOT per chapter
         -- multiple chapters can point at the same file).
      2. For every chapter that shares this card (the one whose own file
         has it, and any sibling chapter(s) whose card actually lives
         elsewhere per c2), set in `roncoder.json`:
         ```json
         "rip_thumbnail": false,
         "manual_thumbnail": "./card-frames/chNN.jpg"
         ```
      3. Re-run `roncoder.rb` to regenerate the poster/fanart/logo from
         that source image (cheap -- cache hit on the video, this is pure
         thumbnail/nfo regen).
      Don't force a shared card onto a chapter that genuinely never shows
      one anywhere on the disc (confirmed in practice: one of the 11 pairs
      on Invisible Thread had no card for its trick at all) -- fall back to
      a representative action frame from that chapter's own file instead,
      same as step d's normal fallback.

      If you build a review PDF afterward, note that `generate-review-pdf.rb`
      shows `shared (chNN.jpg)` in the thumbnail-offset column for any
      chapter using this mechanism, instead of a numeric offset (which
      would be stale/misleading -- `rip_thumbnail: false` means
      `thumbnail_offset` is completely ignored, so don't leave a leftover
      value there either; strip it when applying this).

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

   e. **Drop bundled non-content, don't just label it.** Some discs bundle
      genuinely unrelated material alongside the real content -- an FBI
      anti-piracy warning screen, or trailers/previews for other, different
      products (seen in practice: a promo disc where 13 of 14 titles turned
      out to be ads for unrelated releases with only 1 being the disc's own
      advertised content; another disc with 2 titles that were trailers for
      two different, unrelated DVDs by the same performer). If a
      title/chapter's card identifies it as this kind of thing, don't
      apply a title and keep it -- delete that title/chapter entry from
      `roncoder.json` entirely (after the rest of the disc is done, `rm` its
      now-unwanted files from `out/` and its cached encode(s) from `tmp/`
      too) so it doesn't end up in the library as a labeled item. This is
      different from a short chapter that's still genuinely part of *this*
      disc's own presentation -- an opening title card, a brief intro, a
      credits/thank-you reel, a "contact me" card -- keep those even though
      they're short, they're not promotional material for something else.

   f. **Episode numbering.** If the card includes an explicit number (e.g.
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

   g. Clean up the text before passing it as `--name`: join multiple lines
      with a single space, collapse repeated whitespace, trim. Don't worry
      about filesystem-unsafe characters here -- `roncoder.rb`/`split-file.rb`
      now sanitize the actual output filename automatically (a
      `sanitize_filename` helper: `:` becomes ` -`, `?`/`*` are dropped,
      `"` becomes `'`, `<`/`>` become `(`/`)`, `|` becomes `-`, etc. --
      NTFS-safe even though this runs on Linux day-to-day, in case the
      library ever gets copied to a non-Linux filesystem). Pass the card's
      text through as-transcribed, punctuation and all (e.g.
      `"Episode 1: Pad Thai"`) -- the `.nfo`'s `<title>` keeps full display
      fidelity (colon and all), only the on-disk filename gets the
      substitution (`"01 Episode 1 - Pad Thai.mp4"`).

   h. Apply the result with the helper script (it re-checks the
      untouched-default condition itself, so it's safe to call even if you
      re-run this skill later). **Always pass `--confirmed-by` when the name
      came from a trusted source** (`title_card` for an on-screen card,
      `dvd_menu` for the disc's menu, `manual` when Ron gave it directly,
      `other` for anything else solid, e.g. a corroborating product
      listing) -- this drives the green "Confirmed" column in the review
      PDF, added 2026-08-13 specifically so a human skimming the PDF can
      tell a solidly-sourced name apart from a guess at a glance. Leave it
      unset for anything you're inferring/guessing rather than reading
      directly (and use `--note` instead to explain the uncertainty, per
      step i below):

      ```
      ruby /var/home/ron/projects/roncoding/apply-chapter-title.rb \
        --title N --chapter M \
        --name "Sanitized Title" \
        --thumbnail-offset "4000ms" \
        --confirmed-by title_card \
        [--sort-title "Episode 04: Hail Seitan"]
      ```

      On a `split_chapters: false` disc there's no chapter nesting -- each
      title N is one flat `{title, length}` entry and one output file
      `out/NN <title>.mp4` (no `-MM` chapter suffix in the filename). Omit
      `--chapter` entirely; the script supports this ("omit for a non-split
      title") and operates directly on `titles.<N>` instead of
      `titles.<N>.chapters.<M>`. Everything else in this step (frame
      extraction, contact sheets, sanitization, the "already customized"
      skip-check) works the same either way.

      Use the timestamp (in ms) of whichever candidate frame you picked as
      `--thumbnail-offset`.

      **`--note` is for things that need a human's attention, not for
      explaining how confidently-sourced names were confirmed** -- that's
      what `--confirmed-by` and the PDF's green column are for. Getting
      this backwards (writing a provenance note on every single
      confidently-named chapter) happened on the 2026-08-12 originals2-
      batch2 pass and had to be cleaned up after the fact: ~40 notes down
      to 4 real ones. Reserve `--note` for: a genuine guess/inference
      (no card, no menu, judgment call from context), an unresolved
      ambiguity (unidentified person/content), a disc-authoring
      inconsistency worth flagging, or something technically wrong with
      the chapter. Don't write one just to record which source confirmed a
      name you're actually confident in.

   i. If no legible title card was found in any candidate frame, don't call
      the helper script for that chapter yet -- check the menu report
      already pulled at the start of step 3 (see i2 below) before giving
      up and flagging it for manual
      review.

   i2. **No card? Check the menu report -- this is now a validated,
      trustworthy primary method, not just a hint.** Many of these discs
      have a chapter-select menu whose button labels are exactly the names
      missing from card-less chapters. This should already be pulled from
      the lead-in to step 3 above; if it wasn't (e.g. this chapter was
      hit before that guidance existed, or the up-front run was skipped),
      run it now:
      `ruby /var/home/ron/projects/roncoding/extract-dvd-menu.rb <iso>`
      decodes the disc's menu structure (via `dvdunauthor`) into exact
      chapter boundaries (in both disc-native and roncoder-equivalent
      numbering -- see below), a button->chapter mapping for every menu
      page, and one screenshot per menu page *and* per bonus/hidden PGC --
      run it once per disc (not per chapter) and reuse its output
      (`menu-report.md`/`.json` in the disc's own `dvd-menu-<basename>/`
      folder, next to its `roncoder.json`) for the rest of the pass. Read each menu page's screenshot to get the actual button
      text (the tool can't recover that -- it's pixels in the menu video,
      not disc metadata) -- **button order matches on-screen top-to-bottom
      order** (validated across every page of a real disc via a live
      `libdvdnav` walk), so line up the Nth visible item with button N and
      apply its already-computed roncoder-equivalent chapter number
      directly via `apply-chapter-title.rb --confirmed-by dvd_menu`.

      Validated end-to-end against a hand-built, real-navigation answer
      key on one disc: 24 of 26 checked items matched exactly with zero
      manual clicking (~92%) -- high enough to trust as the primary
      source, not something requiring full manual cross-validation from
      scratch every time. Two things worth knowing before trusting it
      blindly:
      - **The chapter-numbering offset is what makes this work, and
        getting it wrong looks exactly like a tool bug.** A disc's real
        chapter count (matching what a player's own chapter menu shows,
        e.g. VLC's Playback > Chapter) can be higher than what
        `roncoder.rb`/HandBrake ever numbered, when real content sits in
        separate `<pgc>`s HandBrake's scan never found at all (seen in
        practice: a hidden logo bumper + 3 real bonus trailers pushed
        every real chapter's disc-native number 4 higher than
        `roncoder.rb`'s own numbering for the exact same chapter -- this
        was originally, wrongly, written up as "the button decompile is
        unreliable," when the decompile was correct all along and the
        real problem was comparing two different numbering schemes
        without translating between them). `extract-dvd-menu.rb` now
        computes this offset automatically and reports both numbers --
        always use the roncoder-equivalent one with
        `apply-chapter-title.rb`. If a disc's total real chapter count
        (per the tool's report) disagrees with what VLC's own chapter
        menu shows, that's the signal to re-check this, not to distrust
        the button data wholesale.
      - **Residual known gap:** on the one disc this has been fully
        validated against, one tightly-packed adjacent pair of chapters
        came out swapped by one position, cause not fully root-caused. A
        light spot-check (read the actual chapter's ripped frame, confirm
        it matches the button's expected content) is still worth doing on
        short, closely-spaced chapters -- full skepticism isn't warranted
        anymore, but a quick sanity glance still is.
      - Multiple menu pages can legitimately cover the *same* underlying
        tricks at different entry points (seen in practice: a
        "Performances" page linking to each trick's short reveal chapter,
        and a separate "Methods" page linking to the same tricks'
        full-explanation chapters) -- both are real, valid navigation
        paths into the same routine, not a conflict to resolve.
      - Bonus/hidden PGCs the tool surfaces are not automatically part of
        the library -- read their screenshots and apply the usual
        "drop bundled non-content" judgment (3e above) same as any other
        chapter.
      - A menu button that points to a chapter with no corresponding named
        item on *any* menu page does still happen -- a disc can have a
        real, reachable chapter that's simply unlabeled everywhere. If so,
        that chapter genuinely has no official name and step 3i's
        manual-review flag is the right outcome.
      This only works when there's a menu-select structure to decode in the
      first place -- straight-to-content discs with no interactive menu at
      all still just fall through to 3i's manual-review flag.

   j. Delete the scratch frames for this chapter once you're done with it.

4. **After all chapters are processed:**

   a. Set the disc-level display title (decoupled from per-chapter output
      filenames -- this only affects `CONFIG['title']`, used for `out_dir`
      (the actual output folder name, browsable in a file manager), the
      final rsync-destination hint, and the review PDF's disc header, not
      any per-chapter `.nfo`). **Format it as `<Performer Name> -
      <marketing title>`** (Ron's standing preference, confirmed
      2026-08-11: "always have 'name - title' when we create the
      project") -- e.g. `Bob White - Torn and Restored Tissue`, not just
      `Torn and Restored Tissue`. This needs the performer name, so
      resolve that via step 5a *first* if it isn't already known, then
      come back and set the combined title here:

      ```
      ruby /var/home/ron/projects/roncoding/apply-metadata.rb --title "<Performer Name> - <marketing title from Inputs>" [--force]
      ```

      Skip the prefix (just use the marketing title alone) when it would
      be redundant or awkward -- a title that already names the performer
      (e.g. "Jim Steinmeyer's Palingenesia") or a genuine multi-performer
      panel disc where no single name fits. `--force` is only needed if
      this runs a second time after `title` was already set once (e.g.
      correcting an earlier plain title to add the performer prefix).

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

   d. **Director/writer.** Use what the user told you directly, or what a
      store listing explicitly credits, if either exists. Otherwise,
      **default both to the sole performer's name** when there's exactly
      one credited performer and no other director/writer information
      turns up -- these are one-person lecture discs, the performer
      effectively wrote and directed their own presentation, and Ron's
      explicit preference is to fill this in rather than leave it blank
      when there's no other information (confirmed 2026-08-11, applied
      retroactively to all 4 originals2-batch discs). Only leave these
      blank for a human when there's genuine ambiguity -- e.g. a
      multi-performer/panel disc where it's not obvious who directed it.

   e. **Plot.** Attempt this now rather than leaving it purely manual --
      prefer the DVD case's own synopsis text over a web search when one
      exists (the back cover's descriptive paragraph(s), which also often
      double as good source material for step 3's title cards/routine
      names). If no case exists (e.g. a bare promo disc with only the disc
      face photographed, no jewel case), fall back to a synopsis assembled
      from web search -- store listings, forum threads, etc. -- same
      best-effort spirit as the rest of this step. Write it as a single
      paragraph (no embedded newlines needed -- `do_nfo` only reaches for a
      CDATA block if the text contains one). This gets set at the disc-wide
      `global_config.metadata.plot` level, same as year/genre/actor, so
      every chapter/title's `.nfo` shares the one synopsis -- there's no
      per-chapter plot field.

   f. **Apply what you found**, without `--force` (never overwrite metadata
      a human already filled in):

      ```
      ruby /var/home/ron/projects/roncoding/apply-metadata.rb \
        --year YYYY \
        --genre "Genre" \
        --plot "Synopsis paragraph..." \
        [--director "Name"] [--writer "Name"] \
        --actor-name "Firstname Lastname" ["Second Performer" ...] \
        --role "Self" ["Role Two" ...]
      ```

      (`--director`/`--writer`/`--role` are all optional; omitted roles
      default to `"Self"`.) The script only writes fields that are still
      at their untouched default, same safety pattern as
      `apply-chapter-title.rb`.

   g. **Headshot.** Compute the expected path:
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

   h. **Folder art (DVD cover).** Web search for the DVD's cover (store
      listing product image is usually the best source). If `folder.jpg`
      doesn't already exist in the disc folder, download the best
      candidate:

      ```
      curl -Lo folder.jpg "<candidate image URL>"
      ```

      Never overwrite an existing `folder.jpg` without asking first --
      **but watch for a specific trap**: the earlier disc-cataloging phase
      of this project (identifying unlabeled ISOs from physical media) left
      a webcam/phone photo of Ron holding the disc/case as a placeholder
      `folder.jpg` on several discs *before* this skill ever ran on them.
      Since that file "already exists," this step silently never even
      attempts a real search, and the placeholder photo quietly becomes the
      permanent cover art. Confirmed in practice: 4 originals2-batch discs
      sat with a holding-the-case photo as their `folder.jpg` well after
      their full rip-review pass, discovered only when Ron asked for
      "official" art directly (2026-08-11). This step can't safely
      auto-detect "placeholder photo" vs. "a human deliberately chose this
      artwork" from the file alone -- so always call this out explicitly in
      the final summary (step 7) whenever `folder.jpg` already existed
      going in, e.g. "folder art: already present (unclear if this is real
      cover art or a cataloging placeholder -- say the word if you want a
      proper web-art search)", rather than silently reporting it as
      "already present" and done.

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
   findings -- disc title, year, genre, plot source (DVD case / web search /
   not found), performer name(s), headshot status (already present /
   downloaded from <source> / not found), folder art status (downloaded
   from <source> / not found / **already present -- unclear if real cover
   art or a cataloging placeholder, see 5h**) -- clearly labeled as
   best-effort. Remind them to:
   - Look over the disc's output folder (named after the disc's title, not
     a generic `out/` -- `roncoder.rb` derives it from `CONFIG['title']`)
     for anything the auto-crop got wrong
   - Confirm the thumbnails/titles actually look right
   - Verify the metadata this skill filled in, plot included -- it's a
     best-effort synopsis (from the case or a web search), not guaranteed
     accurate

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
