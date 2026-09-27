require 'rexml/document'
require 'json'
require 'fileutils'
require 'tmpdir'
require 'rainbow/refinement'
require 'optimist'

using Rainbow

# For when a chapter has no on-screen title card (or the rip-review skill
# already gave up on one) but the disc's own DVD menu structure still knows
# exactly which chapter each named menu button jumps to -- this reads that
# structure directly out of the disc instead of needing it transcribed by
# hand from watching the menu in a player. Validated end-to-end against a
# hand-built, real-navigation answer key (see working/originals2-status.md's
# "Who's Afraid of Invisible Thread" writeup) -- once the chapter-numbering
# offset below is accounted for, this matched real menu button targets on
# 24 of 26 checked items with zero manual clicking.
#
# `dvdunauthor` (part of the dvdauthor package) decodes a DVD-Video
# structure back into a `dvdauthor.xml` project file, which includes the
# exact millisecond chapter boundaries and the literal VM commands each menu
# button executes (e.g. "jump title 1 chapter 12"). It does NOT recover the
# button's on-screen TEXT -- that's burned into the menu's background video
# as pixels, not stored as real metadata anywhere on the disc -- so this
# script also grabs one still frame per menu page for a human (or a vision
# model) to read the labels from.
#
# **Button list order == on-screen top-to-bottom order.** Validated on
# every menu page of the Invisible Thread disc (root menu, Performances,
# Techniques, Methods, Bonus Features) via a live libdvdnav walk that also
# pulled real highlight-area Y-coordinates -- button 1 was always the
# topmost item, button 2 next, etc., matching dvdunauthor's own <button>
# listing order exactly. This script trusts that correspondence rather than
# separately building/running the libdvdnav C tool every time (real, but
# heavier, ground truth if this assumption ever needs re-checking on a
# stranger disc) -- if a report's button count doesn't match the number of
# visible lines in its screenshot, that's the signal this assumption broke
# and the harder libdvdnav path is worth falling back to.
#
# **The chapter-numbering offset.** A disc's *real* chapter count (matching
# what a player's own chapter menu shows, e.g. VLC's Playback > Chapter)
# can be higher than what `roncoder.rb`/HandBrake ever numbered, if extra
# content sits in separate <pgc>s outside the one big PGC HandBrake's scan
# actually found (seen in practice: 4 hidden single-cell PGCs -- a logo
# bumper plus 3 real bonus trailers for unrelated products -- pushed every
# real chapter's disc-native number 4 higher than roncoder.rb's own
# numbering for the exact same chapter). This script computes that offset
# automatically (summing the cell-counts of every *other* title-domain PGC
# that precedes the main one) and reports button targets in both raw
# disc-native numbering and roncoder-equivalent (offset-corrected)
# numbering -- use the roncoder-equivalent number when calling
# apply-chapter-title.rb.
#
# dvdunauthor has no option to skip re-muxing the actual title video (it
# always extracts everything into .vob files in the current directory) --
# for a ~4GB disc that's a lot of redundant I/O and disk space, since we
# already have the real rip from roncoder.rb. This script always cleans up
# every extracted .vob after pulling what it needs from them.

OPTS = Optimist.options do
  banner "Usage: #{ $PROGRAM_NAME } <iso-or-device-path> [--out-dir DIR]"
  opt :out_dir, 'Where to write the report + frame images (default: ./dvd-menu-<basename>)', type: :string
end

if ARGV.length != 1
  Optimist.die 'Expected exactly one argument: the ISO path or DVD device'
end

DISC_PATH = File.expand_path(ARGV[0])

unless File.exist?(DISC_PATH) || DISC_PATH.start_with?('/dev/')
  puts "No such file: #{ DISC_PATH }".red
  exit 1
end

%w[dvdunauthor ffmpeg].each do |bin|
  unless system("command -v #{ bin } > /dev/null 2>&1")
    puts "Missing required binary: #{ bin }".red
    exit 1
  end
end

basename = File.basename(DISC_PATH, '.*')
# Same containment pattern as roncoder.rb: an ISO file has a containing
# folder (the disc's own working/ dir) to land the report in regardless of
# where this script was invoked from; a raw device path (e.g. /dev/sr0)
# doesn't, so that case falls back to the invocation directory.
default_out_dir = if File.file?(DISC_PATH)
                     File.join(File.dirname(DISC_PATH), "dvd-menu-#{ basename }")
                   else
                     "./dvd-menu-#{ basename }"
                   end
OUT_DIR = File.expand_path(OPTS[:out_dir] || default_out_dir)
FileUtils.mkdir_p(OUT_DIR)

def grab_frame(vob_file, out_path, seek: nil)
  args = ['ffmpeg', '-y']
  args += ['-ss', seek.to_s] if seek
  args += ['-i', vob_file, '-frames:v', '1', '-q:v', '2', out_path]
  system(*args, out: File::NULL, err: File::NULL)
  File.exist?(out_path) ? out_path : nil
end

Dir.mktmpdir('dvdunauthor-') do |scratch|
  Dir.chdir(scratch) do
    puts "Decoding #{ DISC_PATH } with dvdunauthor (this re-muxes the whole disc, takes a while)...".green
    system('dvdunauthor', DISC_PATH, out: File::NULL, err: File::NULL)

    unless File.exist?('dvdauthor.xml')
      puts 'dvdunauthor did not produce dvdauthor.xml -- decode failed (encrypted disc? unusual structure?)'.red
      exit 1
    end

    doc = REXML::Document.new(File.read('dvdauthor.xml'))

    # All title-domain PGCs, in document order. The one with the most cells
    # is what roncoder.rb/HandBrake actually numbered as chapters 1..N;
    # every *other* one is content HandBrake's scan never saw at all.
    title_pgcs = REXML::XPath.match(doc, '//titleset/titles/pgc')
    main_pgc = title_pgcs.max_by { |pgc| REXML::XPath.match(pgc, './/cell').length }
    main_index = title_pgcs.index(main_pgc)

    # Offset = disc-native chapter number minus roncoder-equivalent chapter
    # number. Only PGCs *before* the main one in document order push the
    # main content's own native numbering upward -- ones after it don't
    # affect this offset (though they're still worth surfacing below).
    offset = title_pgcs[0...main_index].sum { |pgc| REXML::XPath.match(pgc, './/cell').length }

    chapters = []
    cells = REXML::XPath.match(main_pgc, './/cell')
    cells.each_with_index do |cell, i|
      start = cell.attributes['start']
      stop = cell.attributes['end'] || (cells[i + 1] && cells[i + 1].attributes['start'])
      chapters << { roncoder_number: i + 1, disc_native_number: i + 1 + offset, start: start, end: stop }
    end

    # Every *other* title-domain PGC (bonus/hidden content HandBrake's scan
    # never found) gets one representative screenshot too, so it's at least
    # visible rather than silently invisible. These are usually small
    # single-cell PGCs, so grab a frame partway in rather than at 0/1s,
    # which on discs like this just shows a shared intro bumper repeating.
    other_pgcs = title_pgcs.each_with_index.reject { |pgc, i| i == main_index }
    bonus_segments = other_pgcs.map do |pgc, i|
      vob = REXML::XPath.first(pgc, './/vob')
      next nil unless vob

      vob_file = vob.attributes['file']
      next nil unless File.exist?(vob_file)

      duration = `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "#{ vob_file }" 2>/dev/null`.strip.to_f
      seek = duration > 20 ? (duration * 0.2).round : 1
      frame_path = File.join(OUT_DIR, "bonus-pgc#{ i + 1 }.jpg")
      frame = grab_frame(vob_file, frame_path, seek: seek)
      { pgc_index: i + 1, duration_seconds: duration.round(1), frame: frame }
    end.compact

    # Every <pgc> under a <menus> block (vmgm or titleset) that has a
    # <buttons> table is one menu "page" -- its background vob is the
    # image to screenshot, and each <button>'s body is the literal VM
    # command(s) it runs when pressed. Button list order is trusted to
    # match on-screen top-to-bottom order (see file header).
    menu_pages = []
    REXML::XPath.match(doc, '//menus/pgc').each do |pgc|
      vob = REXML::XPath.first(pgc, './/vob')
      next unless vob

      vob_file = vob.attributes['file']
      buttons = REXML::XPath.match(vob, './/buttons/button')
      next if buttons.empty?

      button_targets = buttons.map do |button|
        name = button.attributes['name']
        commands = button.text.to_s.strip
        if commands =~ /jump\s+title\s+(\d+)\s+chapter\s+(\d+)/
          title_num, disc_chapter = Regexp.last_match(1).to_i, Regexp.last_match(2).to_i
          roncoder_chapter = disc_chapter - offset
          chapter_info = chapters.find { |c| c[:roncoder_number] == roncoder_chapter }
          {
            button: name, target: 'chapter', title: title_num,
            disc_native_chapter: disc_chapter, roncoder_chapter: roncoder_chapter,
            chapter_info: chapter_info,
          }
        elsif commands =~ /jump\s+pgc\s+(\d+)/
          { button: name, target: 'submenu', pgc: Regexp.last_match(1).to_i }
        else
          { button: name, target: 'other', raw: commands }
        end
      end

      menu_pages << { vob_file: vob_file, buttons: button_targets }
    end

    # One still frame per menu page. These vobs are DVD "infinite pause"
    # stills (a single cell with pause="inf" -- the whole menu screen is
    # just one displayed-indefinitely frame, not moving video), often well
    # under a second of actual encoded content -- so seek to 0, not into
    # the middle like a normal video clip, or ffmpeg finds nothing there.
    menu_pages.each do |page|
      next unless File.exist?(page[:vob_file])

      frame_path = File.join(OUT_DIR, "#{ File.basename(page[:vob_file], '.vob') }.jpg")
      page[:frame] = grab_frame(page[:vob_file], frame_path)
    end

    report = {
      disc: DISC_PATH,
      chapter_numbering_offset: offset,
      chapters: chapters,
      bonus_segments: bonus_segments,
      menu_pages: menu_pages,
    }
    File.write(File.join(OUT_DIR, 'menu-report.json'), JSON.pretty_generate(report))

    lines = ["# DVD menu report for #{ File.basename(DISC_PATH) }", '']
    lines << "Chapter numbering offset: **#{ offset }** (disc-native chapter number = roncoder chapter number + #{ offset })"
    lines << ''
    lines << '## Chapters (roncoder numbering -- what apply-chapter-title.rb expects)'
    chapters.each { |c| lines << "- Chapter #{ c[:roncoder_number] } (disc-native #{ c[:disc_native_number] }): #{ c[:start] } - #{ c[:end] || '(end)' }" }

    if bonus_segments.any?
      lines << ''
      lines << '## Bonus/hidden content (separate PGCs the main rip never touched)'
      lines << '(Not part of the main chapter numbering -- read each frame to see what it actually is before deciding whether it belongs in the library at all.)'
      bonus_segments.each do |seg|
        lines << "- PGC #{ seg[:pgc_index] } (#{ seg[:duration_seconds] }s)#{ seg[:frame] ? " -- frame: #{ seg[:frame] }" : ' -- (no frame extracted)' }"
      end
    end

    lines << ''
    lines << '## Menu pages'
    lines << '(Read the frame image for each page to get the actual button text -- not stored as data on the disc. ' \
             'Button order is assumed to match on-screen top-to-bottom order -- sanity-check the button count against the visible item count.)'
    menu_pages.each do |page|
      lines << ''
      lines << "### #{ File.basename(page[:vob_file]) }#{ page[:frame] ? " -- frame: #{ page[:frame] }" : ' -- (no frame extracted)' }"
      page[:buttons].each do |b|
        target = case b[:target]
        when 'chapter'
          ci = b[:chapter_info]
          if ci
            "-> roncoder chapter #{ b[:roncoder_chapter] } / disc-native #{ b[:disc_native_chapter] } (#{ ci[:start] } - #{ ci[:end] || '(end)' })"
          else
            "-> disc-native chapter #{ b[:disc_native_chapter] } (roncoder-equivalent #{ b[:roncoder_chapter] } -- outside the main chapter range, likely bonus content or a dead link, see above)"
          end
        when 'submenu'
          "-> submenu (pgc #{ b[:pgc] })"
        else
          "-> #{ b[:raw] }"
        end
        lines << "- button #{ b[:button] } #{ target }"
      end
    end
    File.write(File.join(OUT_DIR, 'menu-report.md'), lines.join("\n"))
  end
end

puts "Wrote #{ File.join(OUT_DIR, 'menu-report.md') }".green
puts "Wrote #{ File.join(OUT_DIR, 'menu-report.json') }".green
puts 'Next: read each menu page frame to get button text (top-to-bottom = button order), then apply via apply-chapter-title.rb using the roncoder chapter numbers.'.green
