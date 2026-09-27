require 'json'
require 'prawn'
require 'prawn/table'
require 'optimist'
require 'rainbow/refinement'
require 'uri'
require 'tmpdir'

using Rainbow

OPTS = Optimist.options do
  banner "Usage: #{ $PROGRAM_NAME } [--scan-dir DIR] [--out FILE]"
  opt :scan_dir, 'Directory to scan for roncoder.json files', type: :string, default: File.join(File.dirname(File.expand_path(__FILE__)), 'working')
  opt :out, 'Write one combined PDF to this path instead of a review.pdf per disc/video folder', type: :string
end

HEADSHOTS_DIR = '/home/ron/projects/www.javaop.com/headshots'
LINK_COLOR = '0000EE'
NOTE_COLOR = 'B00000'
NOTE_BG = 'FFF0F0'
CONFIRMED_COLOR = '007000'
# Under this, a chapter is likely a stub/phantom marker rather than real
# content (see CLAUDE.md's crop_mode section for a worked example of a
# genuinely broken ~34ms chapter) -- flag it for a human glance rather than
# silently trusting it. 60s flagged too much legitimate short content
# (intros, closing credits, etc).
SHORT_DURATION_SECONDS = 15
CONFIRMED_BY_LABELS = {
  'dvd_menu' => 'DVD menu',
  'title_card' => 'Title card',
  'manual' => 'Manual',
  'other' => 'Other source',
}.freeze

# roncoder.rb's get_duration stores mediainfo's own duration text with spaces
# stripped, e.g. "4min50s", "16min35s", "39s808ms" -- parse it back into
# seconds so we can flag suspiciously short (likely broken) rips.
def parse_duration_seconds(str)
  return nil if str.nil? || str.empty? || str == '-1'

  units = { 'h' => 3600, 'min' => 60, 's' => 1, 'ms' => 0.001 }
  total = str.scan(/(\d+(?:\.\d+)?)(h|min|s|ms)/).sum { |value, unit| value.to_f * units[unit] }
  total.zero? ? nil : total
end

def find_headshot(name)
  return nil if name.nil? || name.empty?

  base = name.gsub(' ', '-')
  %w[.jpg .jpeg .png].each do |ext|
    path = File.join(HEADSHOTS_DIR, "#{ base }#{ ext }")
    return path if File.exist?(path)
  end

  nil
end

def metadata_for(config)
  config['metadata'] || config.dig('global_config', 'metadata') || {}
end

def file_url(path)
  'file://' + URI::DEFAULT_PARSER.escape(File.expand_path(path))
end

def sorted_chapters(config)
  rows = []
  config['titles'].keys.sort_by(&:to_i).each do |t|
    title_config = config['titles'][t]
    chapters = title_config['chapters']
    if chapters
      chapters.keys.sort_by(&:to_i).each do |c|
        rows << { title_num: t, chapter_num: c, data: chapters[c] }
      end
    else
      # split_chapters: false -- one row per title, no chapter component
      rows << { title_num: t, chapter_num: nil, data: title_config }
    end
  end

  # Simulates actual Jellyfin/Kodi playback order rather than raw disc/title
  # order: sort by sort_title when set, otherwise by the same base_filename
  # string the .nfo's own sorttitle falls back to when sort_title is unset --
  # so a disc like Hundy 500 (whose sort_title deliberately reorders across
  # title boundaries to match the DVD's own menu order) previews in the table
  # the same way it'll actually play.
  rows.sort_by { |row| [row[:data]['sort_title'] || base_filename(row), base_filename(row)] }
end

# Mirrors roncoder.rb's own sanitize_filename -- the actual output filename
# has this applied (NTFS-safe even though everything runs on Linux day to
# day), but roncoder.json's title text keeps the original punctuation
# (colons and all) for full display fidelity in the .nfo. Reconstructing a
# poster path straight from the raw title text (no sanitizing) silently
# missed every chapter whose card text had a colon in it -- e.g. "Performance:
# Rosediction" -- since the real file on disk is "Performance - Rosediction".
def sanitize_filename(str)
  str
    .gsub('/', '-')
    .gsub('\\', '-')
    .gsub(':', ' -')
    .gsub(/[?*]/, '')
    .gsub('"', "'")
    .gsub('<', '(')
    .gsub('>', ')')
    .gsub('|', '-')
    .gsub(/[\x00-\x1f]/, '')
    .gsub(/\s+/, ' ')
    .strip
    .sub(/\.+\z/, '')
end

# Mirrors roncoder.rb's own global_config -> title -> chapter merge cascade
# (a shallow `.merge`, same as roncoder.rb's own do_rip) for a single scalar
# field -- chapters relying on the disc-wide default (no per-chapter
# override) otherwise showed up blank in the PDF instead of the value
# actually in effect.
def effective_field(config, row, field)
  data = row[:data]
  return data[field] if data.key?(field) && !data[field].nil?

  if row[:chapter_num]
    title_config = config.dig('titles', row[:title_num]) || {}
    return title_config[field] if title_config.key?(field) && !title_config[field].nil?
  end

  config.dig('global_config', field)
end

# The base filename roncoder.rb itself derives a title/chapter's output files
# from -- also what the .nfo's <sorttitle> falls back to when sort_title is
# unset (see sorted_chapters).
def base_filename(chapter_row)
  title_num = chapter_row[:title_num]
  chapter_num = chapter_row[:chapter_num]
  sanitized_title = sanitize_filename(chapter_row[:data]['title'])
  if chapter_num
    '%02d-%02d %s' % [title_num.to_i, chapter_num.to_i, sanitized_title]
  else
    '%02d %s' % [title_num.to_i, sanitized_title]
  end
end

def chapter_poster_path(folder, chapter_row, config)
  File.join(folder, config['out_dir'] || "./#{ sanitize_filename(config['title']) }", "#{ base_filename(chapter_row) }.jpg")
end

SCRATCH_FILES = []

# Prawn embeds the source image's full resolution regardless of the display
# size given via `fit:`/`width:` -- it only scales how the image is drawn,
# not the embedded file size. For a table with one image per row (up to ~80
# rows on the bigger discs), that means a full-size ~150KB poster embedded
# 80 times over. Pre-shrink an actual small copy instead, so the PDF stays a
# reasonable size.
def small_thumbnail(path, box)
  return nil unless File.exist?(path)

  tmp = File.join(Dir.tmpdir, "review-thumb-#{ Process.pid }-#{ rand(1_000_000) }.jpg")
  system('magick', path, '-resize', "#{ box[0] }x#{ box[1] }", tmp, out: File::NULL, err: File::NULL)
  return nil unless File.exist?(tmp)

  SCRATCH_FILES << tmp
  tmp
end

items = Dir.glob(File.join(OPTS[:scan_dir], '**', 'roncoder.json')).sort.map do |json_path|
  folder = File.dirname(json_path)
  config = JSON.parse(File.read(json_path))
  { folder: folder, config: config, disc: !!config['titles'] }
end

if items.empty?
  puts "No roncoder.json files found under #{ OPTS[:scan_dir] }".red
  exit 1
end

puts "Found #{ items.length } items:".green
items.each { |i| puts "  - #{ File.basename(i[:folder]) } (#{ i[:disc] ? 'disc' : 'standalone' })" }

def render_item(pdf, item)
  config = item[:config]
  folder = item[:folder]
  metadata = metadata_for(config)
  title = config['title'] || File.basename(folder)

  pdf.text title, size: 18, style: :bold
  pdf.text item[:disc] ? 'DISC' : 'STANDALONE FILE', size: 9, color: '888888'
  pdf.move_down 4
  pdf.formatted_text [{ text: File.basename(folder), link: file_url(folder), color: LINK_COLOR, underline: true, size: 10 }]
  pdf.move_down 8

  # Cover art: folder.jpg for a disc, the video's own poster for standalone
  cover = if item[:disc]
    File.join(folder, config['out_dir'] || "./#{ sanitize_filename(config['title']) }", 'folder.jpg')
  else
    Dir.glob(File.join(folder, '*.jpg')).reject { |f| f =~ /-fanart\.jpg$|-logo\.jpg$/ }.first
  end
  if cover && File.exist?(cover)
    pdf.image cover, width: 110
    pdf.move_down 8
  end

  pdf.text "Year: #{ metadata['year'] || '(none)' }    Genre: #{ metadata['genre'] || '(none)' }", size: 10
  pdf.text "Director: #{ metadata['director'].to_s.empty? ? '(none)' : metadata['director'] }    Writer: #{ metadata['writer'].to_s.empty? ? '(none)' : metadata['writer'] }", size: 10
  plot = metadata['plot'].to_s
  if plot.empty?
    pdf.move_down 4
    pdf.text '(no plot)', size: 8, color: 'CC0000'
  else
    pdf.move_down 4
    pdf.text plot, size: 8, color: '666666'
  end
  pdf.move_down 8

  actors = (metadata['actor'] || []).reject { |a| a['name'].to_s.empty? }
  if actors.any?
    actor_rows = actors.map do |actor|
      headshot = find_headshot(actor['name'])
      image_cell = headshot ? { image: headshot, fit: [36, 36] } : 'no headshot'
      [image_cell, "#{ actor['name'] } (#{ actor['role'] })"]
    end
    pdf.table(actor_rows, cell_style: { borders: [], padding: [2, 6, 2, 0] }) do |t|
      t.column(0).width = 44
    end
    pdf.move_down 8
  end

  return unless item[:disc]

  chapters = sorted_chapters(config)

  pdf.start_new_page
  unit = config['split_chapters'] ? 'chapters' : 'titles'
  pdf.text "#{ title } -- #{ chapters.length } #{ unit }", size: 12, style: :bold
  pdf.move_down 6

  # Thumbnail sits right next to the title in the same row -- deliberately
  # a long table rather than a separate contact-sheet overview, so title
  # and thumbnail are always side by side for review.
  rows = [['', '#', 'Title', 'Sort title', 'Thumb offset', 'Duration', 'Confirmed', 'Note']]
  flagged_rows = []
  confirmed_rows = []
  chapters.each_with_index do |row, i|
    data = row[:data]
    poster = chapter_poster_path(folder, row, config)
    thumb = small_thumbnail(poster, [60, 90])
    duration = data.dig('info', 'duration')
    duration_seconds = parse_duration_seconds(duration)
    manual_thumbnail = effective_field(config, row, 'manual_thumbnail')
    thumb_offset_display =
      if effective_field(config, row, 'rip_thumbnail') == false && manual_thumbnail
        "shared (#{ File.basename(manual_thumbnail) })"
      else
        effective_field(config, row, 'thumbnail_offset') || ''
      end

    # A red-flagged row must always show *why* -- never highlight without
    # an explanation in the cell itself (a short-duration flag used to
    # paint the row red with a blank Note column, which just looked like
    # an unexplained error).
    note = data['note']
    if note.nil? && duration_seconds && duration_seconds < SHORT_DURATION_SECONDS
      note = "Short chapter (#{ duration }) -- worth a quick check"
    end
    flagged_rows << (i + 1) if note

    confirmed_by = data['confirmed_by']
    confirmed_rows << (i + 1) if confirmed_by

    rows << [
      thumb ? { image: thumb, fit: [50, 75] } : '',
      row[:chapter_num] ? "#{ row[:title_num] }-#{ row[:chapter_num] }" : row[:title_num],
      data['title'],
      data['sort_title'] || '',
      thumb_offset_display,
      duration || '',
      confirmed_by ? "Confirmed: #{ CONFIRMED_BY_LABELS[confirmed_by] || confirmed_by }" : '',
      note || '',
    ]
  end

  pdf.table(rows, header: true, width: pdf.bounds.width, cell_style: { size: 7, padding: 4, valign: :center }) do |t|
    t.row(0).font_style = :bold
    t.row(0).background_color = 'DDDDDD'
    t.column(0).width = 58
    t.column(6).width = 90
    t.column(7).width = 150
    flagged_rows.each do |i|
      t.row(i).background_color = NOTE_BG
      t.row(i).text_color = NOTE_COLOR
    end
    confirmed_rows.each do |i|
      t.row(i).column(6).text_color = CONFIRMED_COLOR
    end
  end
end

if OPTS[:out]
  Prawn::Document.generate(OPTS[:out], page_size: 'LETTER', margin: 36) do |pdf|
    items.each_with_index do |item, idx|
      pdf.start_new_page unless idx.zero?
      render_item(pdf, item)
    end
  end
  puts "Wrote #{ OPTS[:out] }".green
else
  items.each do |item|
    out_path = File.join(item[:folder], 'review.pdf')
    Prawn::Document.generate(out_path, page_size: 'LETTER', margin: 36) { |pdf| render_item(pdf, item) }
    puts "Wrote #{ out_path }".green
  end
end

SCRATCH_FILES.each { |f| File.delete(f) if File.exist?(f) }
