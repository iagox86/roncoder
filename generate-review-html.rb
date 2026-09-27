require 'json'
require 'optimist'
require 'rainbow/refinement'
require 'pathname'
require 'base64'
require 'cgi'

using Rainbow

# HTML counterpart to generate-review-pdf.rb -- same data/judgment calls
# (title/sort_title/thumb-offset/duration/confirmed/note per chapter, same
# disc-level metadata block), but every chapter's video is click-to-play
# instead of a static thumbnail, so review doesn't need HandBrake/VLC open
# separately. Doesn't replace review.pdf -- both are written side by side.

OPTS = Optimist.options do
  banner "Usage: #{ $PROGRAM_NAME } [--scan-dir DIR] [--out FILE]"
  opt :scan_dir, 'Directory to scan for roncoder.json files', type: :string, default: File.join(File.dirname(File.expand_path(__FILE__)), 'working')
  opt :out, 'Write one combined HTML file to this path instead of a review.html per disc/video folder', type: :string
end

HEADSHOTS_DIR = '/home/ron/projects/www.javaop.com/headshots'
NOTE_COLOR = '#B00000'
NOTE_BG = '#FFF0F0'
CONFIRMED_COLOR = '#007000'
# Under this, a chapter is likely a stub/phantom marker rather than real
# content (see CLAUDE.md's crop_mode section for a worked example of a
# genuinely broken ~34ms chapter) -- flag it for a human glance rather than
# silently trusting it. Matches generate-review-pdf.rb's own threshold.
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
      rows << { title_num: t, chapter_num: nil, data: title_config }
    end
  end

  rows.sort_by { |row| [row[:data]['sort_title'] || base_filename(row), base_filename(row)] }
end

# Mirrors roncoder.rb's own sanitize_filename -- roncoder.json's title text
# keeps original punctuation (colons and all), but the real output filename
# on disk has this applied (NTFS-safe), so reconstructing a path straight
# from the raw title silently misses anything with a colon etc.
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
# for a single scalar field -- a chapter relying on the disc-wide default
# (no per-chapter override) otherwise shows up blank.
def effective_field(config, row, field)
  data = row[:data]
  return data[field] if data.key?(field) && !data[field].nil?

  if row[:chapter_num]
    title_config = config.dig('titles', row[:title_num]) || {}
    return title_config[field] if title_config.key?(field) && !title_config[field].nil?
  end

  config.dig('global_config', field)
end

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

def chapter_video_path(folder, chapter_row, config)
  File.join(folder, config['out_dir'] || "./#{ sanitize_filename(config['title']) }", "#{ base_filename(chapter_row) }.mp4")
end

# Relative path from the directory the HTML file will actually live in to an
# arbitrary file elsewhere on disk. Only the *relationship* between the two
# paths is baked into the page -- so as long as a disc's internal structure
# (roncoder.json + its out_dir) travels together as a unit, the links keep
# resolving no matter where the whole folder gets moved to afterward.
def rel(html_dir, target)
  Pathname.new(File.expand_path(target)).relative_path_from(Pathname.new(File.expand_path(html_dir))).to_s
end

# Headshots live in a separate repo entirely (www.javaop.com), not inside
# the disc's own folder -- a relative path to them would break the moment
# the disc folder moves, since the two locations don't travel together.
# They're small (individual headshot photos, not full-length video), so
# base64-embedding them directly is the actually-portable option here,
# unlike chapter video/thumbnails which stay as relative paths.
def headshot_data_uri(path)
  return nil unless path && File.exist?(path)

  ext = File.extname(path).delete_prefix('.').downcase
  ext = 'jpeg' if ext == 'jpg'
  "data:image/#{ ext };base64,#{ Base64.strict_encode64(File.binread(path)) }"
end

def h(str)
  CGI.escapeHTML(str.to_s)
end

STYLE = <<~CSS
  :root {
    --bg: #f4f5f7;
    --surface: #ffffff;
    --border: #e4e6ea;
    --text: #1f2328;
    --text-muted: #6b7280;
    --note-bg: #fdf2f2;
    --note-bg-hover: #fbe8e8;
    --note-text: #{ NOTE_COLOR };
    --note-border: #f3c9c9;
    --confirmed-bg: #eafbf1;
    --confirmed-text: #{ CONFIRMED_COLOR };
    --confirmed-border: #bfe9d1;
    --radius: 10px;
  }
  * { box-sizing: border-box; }
  body {
    font-family: system-ui, -apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
    margin: 0; padding: 32px; color: var(--text); background: var(--bg); line-height: 1.45;
  }
  .disc {
    max-width: 1400px; margin: 0 auto 28px; background: var(--surface);
    border: 1px solid var(--border); border-radius: var(--radius); padding: 24px 28px;
    box-shadow: 0 1px 3px rgba(16, 24, 40, 0.06);
  }
  h1 { font-size: 21px; margin: 0 0 4px; font-weight: 650; letter-spacing: -0.01em; }
  .badge {
    display: inline-block; font-size: 10px; font-weight: 700; color: var(--text-muted);
    letter-spacing: 0.08em; text-transform: uppercase; background: var(--bg);
    border: 1px solid var(--border); border-radius: 4px; padding: 2px 7px;
  }
  .folder-name {
    font-size: 12px; color: var(--text-muted); margin: 6px 0 16px;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  .meta-line { font-size: 13px; margin: 3px 0; }
  .meta-line b { color: var(--text-muted); font-weight: 600; }
  .plot { font-size: 12.5px; color: var(--text-muted); margin-top: 8px; max-width: 800px; }
  .plot.missing { color: var(--note-text); font-style: italic; }
  .cover {
    width: 140px; float: left; margin: 0 18px 10px 0; border-radius: 8px;
    box-shadow: 0 1px 4px rgba(16, 24, 40, 0.18);
  }
  .meta-block { overflow: hidden; }
  .actors { display: flex; flex-wrap: wrap; gap: 8px; margin: 14px 0 2px; clear: both; }
  .actor {
    display: flex; align-items: center; gap: 7px; font-size: 12px; background: var(--bg);
    border: 1px solid var(--border); border-radius: 999px; padding: 3px 11px 3px 3px;
  }
  .actor img { width: 26px; height: 26px; object-fit: cover; border-radius: 50%; }
  .actor .no-headshot { width: 26px; height: 26px; background: #e5e7eb; border-radius: 50%; }
  table.chapters { border-collapse: separate; border-spacing: 0; width: 100%; margin-top: 20px; clear: both; }
  table.chapters caption { text-align: left; font-weight: 650; margin-bottom: 8px; font-size: 14px; }
  table.chapters th, table.chapters td {
    padding: 9px 10px; font-size: 12.5px; text-align: left; vertical-align: middle;
    border-bottom: 1px solid var(--border);
  }
  table.chapters thead th {
    background: var(--bg); color: var(--text-muted); font-weight: 650; font-size: 11px;
    text-transform: uppercase; letter-spacing: 0.04em; position: sticky; top: 0; z-index: 1;
    border-bottom: 1px solid var(--border);
  }
  table.chapters tbody tr:hover td { background: #fafbfc; }
  table.chapters tr.flagged td { background: var(--note-bg); }
  table.chapters tr.flagged:hover td { background: var(--note-bg-hover); }
  .note-text { color: var(--note-text); }
  .cell-clamp { max-width: 420px; word-wrap: break-word; overflow-wrap: break-word; }
  .tag { display: inline-block; font-size: 11px; font-weight: 650; border-radius: 999px; padding: 2px 10px; white-space: nowrap; }
  .tag.confirmed { background: var(--confirmed-bg); color: var(--confirmed-text); border: 1px solid var(--confirmed-border); }
  .thumb-cell {
    position: relative; width: 104px; height: 68px; cursor: pointer; background: #111;
    border-radius: 7px; overflow: hidden; box-shadow: 0 1px 2px rgba(16, 24, 40, 0.15);
    transition: transform 0.12s ease, box-shadow 0.12s ease;
  }
  .thumb-cell:hover { transform: scale(1.04); box-shadow: 0 3px 8px rgba(16, 24, 40, 0.25); }
  .thumb-cell img { display: block; width: 100%; height: 100%; object-fit: cover; }
  .thumb-cell .play-overlay {
    position: absolute; inset: 0; display: flex; align-items: center; justify-content: center;
    background: rgba(0, 0, 0, 0.18);
  }
  .thumb-cell .play-icon {
    width: 30px; height: 30px; border-radius: 50%; background: rgba(255, 255, 255, 0.94);
    color: #111; display: flex; align-items: center; justify-content: center;
    font-size: 12px; box-shadow: 0 1px 3px rgba(0, 0, 0, 0.35);
  }
  .thumb-cell.no-thumb { background: #2b2e33; }
  .thumb-cell.no-thumb .play-overlay { background: transparent; }
  .thumb-cell.no-thumb .play-icon {
    width: auto; height: auto; border-radius: 4px; background: rgba(255, 255, 255, 0.12);
    color: #ccc; padding: 4px 8px; font-size: 10px; text-transform: uppercase; letter-spacing: 0.04em;
  }
  .inline-video {
    display: block; max-width: 480px; max-height: 320px; border-radius: 8px;
    box-shadow: 0 2px 10px rgba(16, 24, 40, 0.3); background: #000;
  }
CSS

SCRIPT = <<~JS
  document.querySelectorAll('.thumb-cell').forEach(function (cell) {
    cell.addEventListener('click', function () {
      if (!cell.dataset.video) {
        return;
      }
      var video = document.createElement('video');
      video.className = 'inline-video';
      video.src = cell.dataset.video;
      video.controls = true;
      video.autoplay = true;
      if (cell.dataset.poster) {
        video.poster = cell.dataset.poster;
      }
      cell.replaceWith(video);
    });
  });
JS

def render_thumb_cell(html_dir, folder, row, config)
  poster = chapter_poster_path(folder, row, config)
  video = chapter_video_path(folder, row, config)
  has_poster = File.exist?(poster)
  has_video = File.exist?(video)

  unless has_video
    return '<div class="thumb-cell no-thumb"><div class="play-overlay"><span class="play-icon">no video</span></div></div>'
  end

  video_rel = h(rel(html_dir, video))
  if has_poster
    poster_rel = h(rel(html_dir, poster))
    <<~HTML
      <div class="thumb-cell" data-video="#{ video_rel }" data-poster="#{ poster_rel }">
        <img src="#{ poster_rel }" loading="lazy" alt="">
        <div class="play-overlay"><span class="play-icon">&#9658;</span></div>
      </div>
    HTML
  else
    <<~HTML
      <div class="thumb-cell no-thumb" data-video="#{ video_rel }">
        <div class="play-overlay"><span class="play-icon">&#9658; play</span></div>
      </div>
    HTML
  end
end

def render_item_html(item, html_dir)
  config = item[:config]
  folder = item[:folder]
  metadata = metadata_for(config)
  title = config['title'] || File.basename(folder)

  out = +''
  out << "<div class=\"disc\">\n"
  out << "<h1>#{ h(title) }</h1>\n"
  out << "<div class=\"badge\">#{ item[:disc] ? 'DISC' : 'STANDALONE FILE' }</div>\n"
  out << "<div class=\"folder-name\">#{ h(File.basename(folder)) }</div>\n"

  out << "<div class=\"meta-block\">\n"

  cover = if item[:disc]
    File.join(folder, config['out_dir'] || "./#{ sanitize_filename(config['title']) }", 'folder.jpg')
  else
    Dir.glob(File.join(folder, '*.jpg')).reject { |f| f =~ /-fanart\.jpg$|-logo\.jpg$/ }.first
  end
  if cover && File.exist?(cover)
    out << "<img class=\"cover\" src=\"#{ h(rel(html_dir, cover)) }\" alt=\"cover\">\n"
  end

  out << "<div class=\"meta-line\"><b>Year:</b> #{ h(metadata['year'] || '(none)') } &nbsp; <b>Genre:</b> #{ h(metadata['genre'] || '(none)') }</div>\n"
  out << "<div class=\"meta-line\"><b>Director:</b> #{ h(metadata['director'].to_s.empty? ? '(none)' : metadata['director']) } &nbsp; <b>Writer:</b> #{ h(metadata['writer'].to_s.empty? ? '(none)' : metadata['writer']) }</div>\n"

  plot = metadata['plot'].to_s
  if plot.empty?
    out << "<div class=\"plot missing\">(no plot)</div>\n"
  else
    out << "<div class=\"plot\">#{ h(plot) }</div>\n"
  end
  out << "</div>\n"

  actors = (metadata['actor'] || []).reject { |a| a['name'].to_s.empty? }
  if actors.any?
    out << "<div class=\"actors\">\n"
    actors.each do |actor|
      headshot = headshot_data_uri(find_headshot(actor['name']))
      img = headshot ? "<img src=\"#{ headshot }\" alt=\"\">" : '<div class="no-headshot"></div>'
      out << "<div class=\"actor\">#{ img }<span>#{ h(actor['name']) } (#{ h(actor['role']) })</span></div>\n"
    end
    out << "</div>\n"
  end

  unless item[:disc]
    out << "</div>\n"
    return out
  end

  chapters = sorted_chapters(config)
  unit = config['split_chapters'] ? 'chapters' : 'titles'

  out << "<table class=\"chapters\">\n"
  out << "<caption>#{ h(title) } -- #{ chapters.length } #{ unit }</caption>\n"
  out << "<thead><tr><th></th><th>#</th><th>Title</th><th>Sort title</th><th>Thumb offset</th><th>Duration</th><th>Confirmed</th><th>Note</th></tr></thead>\n"
  out << "<tbody>\n"

  chapters.each do |row|
    data = row[:data]
    duration = data.dig('info', 'duration')
    duration_seconds = parse_duration_seconds(duration)
    manual_thumbnail = effective_field(config, row, 'manual_thumbnail')
    thumb_offset_display =
      if effective_field(config, row, 'rip_thumbnail') == false && manual_thumbnail
        "shared (#{ File.basename(manual_thumbnail) })"
      else
        effective_field(config, row, 'thumbnail_offset') || ''
      end

    note = data['note']
    if note.nil? && duration_seconds && duration_seconds < SHORT_DURATION_SECONDS
      note = "Short chapter (#{ duration }) -- worth a quick check"
    end

    confirmed_by = data['confirmed_by']
    confirmed_label = confirmed_by ? "Confirmed: #{ CONFIRMED_BY_LABELS[confirmed_by] || confirmed_by }" : ''
    row_num = row[:chapter_num] ? "#{ row[:title_num] }-#{ row[:chapter_num] }" : row[:title_num]

    out << "<tr class=\"#{ note ? 'flagged' : '' }\">\n"
    out << "<td>#{ render_thumb_cell(html_dir, folder, row, config) }</td>\n"
    out << "<td>#{ h(row_num) }</td>\n"
    out << "<td>#{ h(data['title']) }</td>\n"
    out << "<td>#{ h(data['sort_title'] || '') }</td>\n"
    out << "<td>#{ h(thumb_offset_display) }</td>\n"
    out << "<td>#{ h(duration || '') }</td>\n"
    confirmed_html = confirmed_by ? "<span class=\"tag confirmed\">#{ h(confirmed_label) }</span>" : ''
    note_html = note ? "<span class=\"cell-clamp note-text\">#{ h(note) }</span>" : ''

    out << "<td>#{ confirmed_html }</td>\n"
    out << "<td>#{ note_html }</td>\n"
    out << "</tr>\n"
  end

  out << "</tbody>\n</table>\n"
  out << "</div>\n"
  out
end

def wrap_document(title, body)
  <<~HTML
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>#{ h(title) }</title>
    <style>
    #{ STYLE }
    </style>
    </head>
    <body>
    #{ body }
    <script>
    #{ SCRIPT }
    </script>
    </body>
    </html>
  HTML
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

if OPTS[:out]
  html_dir = File.dirname(File.expand_path(OPTS[:out]))
  body = items.map { |item| render_item_html(item, html_dir) }.join("\n")
  File.write(OPTS[:out], wrap_document('Review', body))
  puts "Wrote #{ OPTS[:out] }".green
else
  items.each do |item|
    out_path = File.join(item[:folder], 'review.html')
    html_dir = item[:folder]
    title = item[:config]['title'] || File.basename(item[:folder])
    File.write(out_path, wrap_document(title, render_item_html(item, html_dir)))
    puts "Wrote #{ out_path }".green
  end
end
