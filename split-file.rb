require 'date'
require 'json'
require 'fileutils'
require 'tempfile'
require 'rainbow/refinement'
require 'optimist'

using Rainbow
SCRIPT_DIR = File.dirname(File.expand_path(__FILE__))
FAILED_SPLITS = []

# Write-then-rename so a killed/interrupted process can never leave
# roncoder.json truncated or half-written.
def atomic_write(path, content)
  tmp_path = "#{ path }.tmp.#{ Process.pid }"
  File.write(tmp_path, content)
  File.rename(tmp_path, path)
end

# This runs on Linux day-to-day, but output titles are transcribed straight
# off DVD title cards (which often read like "Category: Subject") and the
# library sometimes gets copied to non-Linux filesystems -- so keep actual
# output filenames NTFS-safe regardless of what punctuation made it into
# roncoder.json's title text. Only used for the filename itself; the
# unmodified original text is still what lands in the .nfo's <title>, so
# display fidelity (colons and all) isn't lost, just the on-disk filename.
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

OPTS = Optimist.options do
  banner "Usage: #{ $PROGRAM_NAME } [options] <video file>"
  opt :dry_run, 'Validate configuration and describe splits, but never cut video/thumbnails', default: false
end

if ARGV.length != 1
  Optimist.die 'Expected exactly 1 argument: <video file>'
end

VIDEO_ARG = ARGV[0]
unless File.file?(VIDEO_ARG)
  puts "No such video file: #{ VIDEO_ARG }".red
  exit 1
end

REQUIRED_BINARIES = %w[ffmpeg mediainfo magick].freeze

def binary_available?(name)
  system("command -v #{ name } > /dev/null 2>&1")
end

missing_binaries = REQUIRED_BINARIES.reject { |bin| binary_available?(bin) }
unless missing_binaries.empty?
  missing_binaries.each { |bin| puts "Missing required binary: #{ bin }".red }
  exit 1
end

# Contain all work to the folder holding the source video, same pattern as
# roncoder.rb/standalone-file.rb.
expanded_video = File.expand_path(VIDEO_ARG)
Dir.chdir(File.dirname(expanded_video))
VIDEO = File.basename(expanded_video)
VIDEO_NAME = File.basename(VIDEO, File.extname(VIDEO))

if File.exist?('roncoder.json')
  CONFIG = ::JSON.parse(File.read('roncoder.json'))
else
  CONFIG = {
    'title' => VIDEO_NAME,
    'video' => VIDEO,
    'tmp_dir' => './tmp',
    # out_dir isn't set here -- it's always derived from `title` (see below),
    # since a fresh config's title is still just the video's basename.
    'log_file' => './roncoder.log',
    'folder_thumbnail' => './folder.jpg',
    'global_config' => {
      'thumbnail_offset' => '500ms',
      'thumbnail_poster_size' => '1000x1500',
      'thumbnail_fanart_size' => '1920x1080',
      'metadata' => {
        'year' => 0,
        'plot' => '',
        'genre' => '',
        'director' => '',
        'writer' => '',
        'actor' => [
          'name' => '',
          'role' => 'Self',
        ],
      },
    },
    'titles' => {},
  }

  puts "No 'roncoder.json' found; creating one with a placeholder title of #{ CONFIG['title'].inspect }.".green
  atomic_write('roncoder.json', JSON.pretty_generate(CONFIG))
end

# Always derived from the current title, same reasoning as roncoder.rb --
# see its comment next to the equivalent line.
CONFIG['out_dir'] = "./#{ sanitize_filename(CONFIG['title']) }"

if CONFIG['titles'].nil? || CONFIG['titles'].empty?
  puts 'No splits configured yet.'.green
  puts "There's no equivalent of lsdvd here -- add one entry per segment to".green
  puts "'titles' in roncoder.json by hand (or have an agent find the cut points".green
  puts 'via frame search), e.g.:'.green
  puts '  "1": { "title": "Segment Name", "start": 68.0, "end": 368.0 }'.green
  puts "'start'/'end' are in seconds from the start of the source video.".green
  puts 'Re-run once at least one split is populated.'.green
  exit
end

def log(text = '', display: true)
  if display
    puts text
  end

  unless CONFIG['log_file']
    return
  end

  f = File.new(CONFIG['log_file'], 'a')
  f.puts("#{ DateTime.now } #{ text }")
  f.close
end

# A shared top-level 'video' is the common case (one file being cut into
# several segments), but a title can override it with its own 'video' --
# e.g. a disc that bundles several already-separate source clips (see
# cut_video) rather than one file to split. Only enforce existence here for
# the shared case; a per-title override is checked in cut_video instead.
if CONFIG['video'] && !File.exist?(CONFIG['video'])
  log "Missing source video: #{ CONFIG['video'] }".red
  exit 1
end

unless OPTS[:dry_run]
  FileUtils.mkdir_p(CONFIG['tmp_dir'], verbose: true)

  if CONFIG['out_dir'].nil? || CONFIG['out_dir'].empty?
    log 'Missing out_dir config!'.red
    exit 1
  end
  FileUtils.rm_rf(CONFIG['out_dir'], verbose: true)
  FileUtils.mkdir_p(CONFIG['out_dir'], verbose: true)
end

# Same mediainfo-based parsing as roncoder.rb, reused here to both drive the
# skip-if-already-cut check and to populate 'info' the same way disc rips
# do (so generate-review-pdf.rb's duration parsing/short-clip flagging just
# works for split items with no changes needed).
def get_bit_rate(file)
  `mediainfo "#{ file }"`.split(/\r?\n/).each do |line|
    if line =~ /^Bit rate     +: ([0-9]+(?:\.[0-9]+)?(?: [0-9]+)*) ?kb/
      return Regexp.last_match(1).gsub(/ /, '').to_i
    end
  end

  return -1
end

def get_duration(file)
  `mediainfo "#{ file }"`.split(/\r?\n/).each do |line|
    if line =~ /^Duration     +: (.*)/
      return Regexp.last_match(1).gsub(/ /, '')
    end
  end

  return -1
end

def get_tmp_filename(num, config)
  File.join(CONFIG['tmp_dir'], '%02d.%s-%s.mp4' % [num.to_i, config['start'], config['end']])
end

# Cutting is plain ffmpeg (re-encode, not stream copy) rather than
# HandBrake -- there's no crop/quality-bitrate-target loop here since the
# source is already a finished consumer-quality file, just a re-encode to
# get a frame-accurate cut. Cache key includes start/end so editing a cut
# point invalidates the tmp/ cache and forces a redo, same purpose as
# roncoder.rb's crop_cache_key.
def cut_video(num, config)
  outfile = get_tmp_filename(num, config)
  # config['video'] lets a title point at its own already-separate source
  # file instead of the collection's shared one -- see the note above the
  # top-level existence check.
  source_video = config['video'] || CONFIG['video']
  log("Cutting split #{ num } (#{ config['start'] }s - #{ config['end'] }s) from #{ source_video } -> #{ outfile }".green)

  if File.exist?(outfile) && get_duration(outfile) != -1
    log "Already cut; skipping: #{ outfile }".cyan
    return outfile
  end

  unless source_video && File.exist?(source_video)
    log "Missing source video for split #{ num }: #{ source_video.inspect }".red
    return nil
  end

  duration = config['end'].to_f - config['start'].to_f
  if duration <= 0
    log "Invalid start/end for split #{ num } (start=#{ config['start'] }, end=#{ config['end'] })!".red
    return nil
  end

  # -ss before -i (fast seek) then -t for duration -- avoids -to's confusing
  # interaction with a seeked input timeline.
  system(<<~FFMPEG)
    ffmpeg -y -ss #{ config['start'] } -i "#{ source_video }" -t #{ duration } \
      -c:v libx264 -crf 18 -preset medium -c:a aac -movflags +faststart \
      "#{ outfile }"
  FFMPEG

  if File.exist?(outfile) && get_duration(outfile) != -1
    log "Done @ #{ outfile }".green
    return outfile
  else
    log "Failed @ #{ outfile }!!".red
    FAILED_SPLITS << num
    return nil
  end
end

def do_thumbnail(config, base_filename, video_file)
  base_thumbnail = nil
  if config['manual_thumbnail']
    log("Using manual thumbnail: #{ config['manual_thumbnail'] }")
    base_thumbnail = config['manual_thumbnail'].gsub(/%%TITLE%%/, config['title'])
  else
    log("Ripping thumbnail at offset #{ config['thumbnail_offset'] }")
    tempfile = Tempfile.create(['thumbnail', '.jpg'])
    tempfile.close

    system("ffmpeg -y -ss #{ config['thumbnail_offset'] } -i \"#{ video_file }\" -frames:v 1 -q:v 2 \"#{ tempfile.to_path }\"")
    base_thumbnail = tempfile.to_path
  end

  if base_thumbnail.nil? || !File.exist?(base_thumbnail)
    log "No thumbnail available for #{ base_filename }; skipping poster/fanart/logo".yellow
    return
  end

  thumbnail_file = File.join(CONFIG['out_dir'], "#{ base_filename }.jpg")
  system("magick \"#{ base_thumbnail }\" -resize #{ config['thumbnail_poster_size'] } -background none -gravity center -extent #{ config['thumbnail_poster_size'] } \"#{ thumbnail_file }\"")

  fanart_file = File.join(CONFIG['out_dir'], "#{ base_filename }-fanart.jpg")
  system("magick \"#{ base_thumbnail }\" -resize #{ config['thumbnail_fanart_size'] } -background none -gravity center -extent #{ config['thumbnail_fanart_size'] } \"#{ fanart_file }\"")

  logo_file = File.join(CONFIG['out_dir'], "#{ base_filename }-logo.jpg")
  system("magick \"#{ base_thumbnail }\" -resize #{ config['thumbnail_poster_size'] } -background none -gravity center -extent #{ config['thumbnail_poster_size'] } \"#{ logo_file }\"")

  if tempfile
    File.unlink(tempfile)
  end
end

# Lenient like standalone-file.rb's do_nfo (skip empty fields/year-0/blank
# actor names) rather than roncoder.rb's stricter version -- a split item's
# metadata is closer in spirit to a standalone item (evolving, often
# incomplete for e.g. an intro clip) than to a disc's, where everything is
# expected upfront.
def do_nfo(config, base_filename)
  nfo_file = File.join(CONFIG['out_dir'], "#{ base_filename }.nfo")
  log("Creating .nfo file: #{ nfo_file }")

  metadata = config['metadata'] || {}

  nfo = [
    '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>',
    '<movie>',
    "  <title>#{ config['title'] }</title>",
  ]

  if config['sort_title']
    nfo << "  <sorttitle>#{ config['sort_title'] }</sorttitle>"
  else
    nfo << "  <sorttitle>#{ base_filename }</sorttitle>"
  end

  %w[plot genre year premiered director writer].each do |key|
    next if key == 'year' && (metadata[key].nil? || metadata[key] == 0)

    if metadata[key] && (!metadata[key].is_a?(String) || !metadata[key].empty?)
      if metadata[key].is_a?(String) && metadata[key].include?("\n")
        nfo << "  <#{ key }><![CDATA[#{ metadata[key] }]]></#{ key }>"
      else
        nfo << "  <#{ key }>#{ metadata[key] }</#{ key }>"
      end
    end
  end

  metadata['actor']&.each do |actor|
    next if actor['name'].nil? || actor['name'].empty?

    nfo << '  <actor>'
    %w[name role].each do |key|
      nfo << "    <#{ key }>#{ actor[key] }</#{ key }>"
    end
    thumbnail = "https://www.javaop.com/headshots/#{ actor['name'].gsub(/ /, '-') }.jpg"
    nfo << "    <thumb>#{ thumbnail }</thumb>"
    puts
    puts "REMINDER: Ensure that #{ thumbnail } works!".yellow.underline
    puts
    nfo << '  </actor>'
  end
  nfo << '</movie>'

  File.write(nfo_file, nfo.join("\n"))
end

def describe_split(num, config)
  duration = config['end'].to_f - config['start'].to_f
  base_filename = '%02d %s' % [num.to_i, sanitize_filename(config['title'])]

  puts "Split #{ num }: #{ config['start'] }s - #{ config['end'] }s (#{ duration.round(1) }s)".cyan
  puts "  would cut into: #{ get_tmp_filename(num, config) }".cyan
  puts "  would produce:  #{ File.join(CONFIG['out_dir'], "#{ base_filename }.mp4") }".cyan
end

begin
  CONFIG['titles'].each_pair do |num, title_config|
    if title_config['start'].nil? || title_config['end'].nil?
      log "Skipping split #{ num }: no start/end set yet".yellow
      next
    end

    # Same untouched-default placeholder apply-chapter-title.rb's --title
    # (no --chapter) case expects, so it can safely rename this later.
    title_config['title'] ||= 'Title %02d' % [num.to_i]

    config = JSON.parse(CONFIG['global_config'].to_json).merge(title_config.compact)
    # Per-split metadata override (e.g. just a year) should layer on top of
    # the collection-wide metadata, not replace it wholesale -- same reason
    # as roncoder.rb's equivalent merge.
    config['metadata'] = JSON.parse(CONFIG['global_config']['metadata'].to_json)
                              .merge((title_config['metadata'] || {}).compact)

    if OPTS[:dry_run]
      describe_split(num, config)
      next
    end

    outfile = cut_video(num, config)
    if outfile.nil?
      log "Split #{ num } failed; skipping thumbnail/nfo".red
      next
    end

    title_config['info'] ||= {}
    title_config['info']['bit_rate'] = get_bit_rate(outfile)
    title_config['info']['duration'] = get_duration(outfile)

    base_filename = '%02d %s' % [num.to_i, sanitize_filename(config['title'])]
    log("Base filename: #{ base_filename }")

    FileUtils.cp(outfile, File.join(CONFIG['out_dir'], "#{ base_filename }.mp4"), verbose: true)
    do_thumbnail(config, base_filename, outfile)
    do_nfo(config, base_filename)

    atomic_write('roncoder.json', JSON.pretty_generate(CONFIG))
  end

  if OPTS[:dry_run]
    puts
    puts 'Dry run complete - no video/thumbnails were cut.'.green
  else
    if CONFIG['folder_thumbnail'].nil? || CONFIG['folder_thumbnail'].empty? || !File.exist?(CONFIG['folder_thumbnail'])
      log "Missing the folder thumbnail: #{ CONFIG['folder_thumbnail'] }".red
      exit 1
    end

    FileUtils.cp(CONFIG['folder_thumbnail'], File.join(CONFIG['out_dir'], "folder#{ File.extname(CONFIG['folder_thumbnail']) }"), verbose: true)

    unless FAILED_SPLITS.empty?
      log 'The following splits failed:'.red
      log FAILED_SPLITS.to_s.red
    end
  end
ensure
  unless OPTS[:dry_run]
    atomic_write('roncoder.json', JSON.pretty_generate(CONFIG))
  end
end

puts
puts 'All done?'.green
puts
if CONFIG['title']
  puts "rsync -rv out/ ron@home:/data/external/media/videos/Magic/Lectures/'#{ CONFIG['title'] }'/".green
end
