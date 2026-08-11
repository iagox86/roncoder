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
  opt :out, 'Output PDF path', type: :string, default: File.join(File.dirname(File.expand_path(__FILE__)), 'library-review.pdf')
end

HEADSHOTS_DIR = '/home/ron/projects/www.javaop.com/headshots'
LINK_COLOR = '0000EE'
NOTE_COLOR = 'B00000'
NOTE_BG = 'FFF0F0'
SHORT_DURATION_SECONDS = 60

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
  rows
end

def chapter_poster_path(folder, chapter_row, config)
  title_num = chapter_row[:title_num]
  chapter_num = chapter_row[:chapter_num]
  base = if chapter_num
    '%02d-%02d %s' % [title_num.to_i, chapter_num.to_i, chapter_row[:data]['title']]
  else
    '%02d %s' % [title_num.to_i, chapter_row[:data]['title']]
  end
  File.join(folder, config['out_dir'] || 'out', "#{ base }.jpg")
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

Prawn::Document.generate(OPTS[:out], page_size: 'LETTER', margin: 36) do |pdf|
  items.each_with_index do |item, idx|
    pdf.start_new_page unless idx.zero?

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
      File.join(folder, config['out_dir'] || 'out', 'folder.jpg')
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

    next unless item[:disc]

    chapters = sorted_chapters(config)

    pdf.start_new_page
    unit = config['split_chapters'] ? 'chapters' : 'titles'
    pdf.text "#{ title } -- #{ chapters.length } #{ unit }", size: 12, style: :bold
    pdf.move_down 6

    # Thumbnail sits right next to the title in the same row -- deliberately
    # a long table rather than a separate contact-sheet overview, so title
    # and thumbnail are always side by side for review.
    rows = [['', '#', 'Title', 'Sort title', 'Thumb offset', 'Duration', 'Note']]
    short_duration_rows = []
    chapters.each_with_index do |row, i|
      data = row[:data]
      poster = chapter_poster_path(folder, row, config)
      thumb = small_thumbnail(poster, [60, 90])
      duration = data.dig('info', 'duration')
      short_duration_rows << (i + 1) if parse_duration_seconds(duration)&.< (SHORT_DURATION_SECONDS)
      rows << [
        thumb ? { image: thumb, fit: [50, 75] } : '',
        row[:chapter_num] ? "#{ row[:title_num] }-#{ row[:chapter_num] }" : row[:title_num],
        data['title'],
        data['sort_title'] || '',
        data['thumbnail_offset'] || '',
        duration || '',
        data['note'] || '',
      ]
    end

    pdf.table(rows, header: true, width: pdf.bounds.width, cell_style: { size: 7, padding: 4, valign: :center }) do |t|
      t.row(0).font_style = :bold
      t.row(0).background_color = 'DDDDDD'
      t.column(0).width = 58
      t.column(6).width = 190
      rows.each_with_index do |r, i|
        next if i.zero? || (r[6].to_s.empty? && !short_duration_rows.include?(i))

        t.row(i).background_color = NOTE_BG
        t.row(i).text_color = NOTE_COLOR
      end
    end
  end
end

SCRATCH_FILES.each { |f| File.delete(f) if File.exist?(f) }

puts "Wrote #{ OPTS[:out] }".green
