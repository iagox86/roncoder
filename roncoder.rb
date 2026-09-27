require 'date'
require 'json'
require 'fileutils'
require 'tempfile'
require 'rainbow/refinement'
require 'optimist'

using Rainbow
SCRIPT_DIR = File.dirname(File.expand_path(__FILE__))
FAILED_RIPS = []

# Write-then-rename so a killed/interrupted process can never leave
# roncoder.json truncated or half-written -- the rename is atomic, so the
# file on disk is always either the old complete version or the new one.
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
  banner "Usage: #{ $PROGRAM_NAME } [options] <media file or folder>"
  opt :dry_run, 'Validate configuration and discover titles/chapters, but never rip video/thumbnails', default: false
end

if ARGV.length > 1
  Optimist.die 'Too many arguments'
end

MEDIA_PATH = if ARGV.empty?
  puts "What's the full path to the ISO, drive (like /dev/sr0), or a folder containing exactly one .iso?"
  input = $stdin.gets&.chomp
  input.nil? || input.empty? ? '/dev/sr0' : input
else
  ARGV[0]
end

# Contain all work (roncoder.json, tmp/out dirs, etc) to the folder that
# holds the media: for a folder argument, that's the folder itself (which
# must hold exactly one .iso); for a regular file (an .iso), that's the
# folder containing it. A drive device (like /dev/sr0) has no meaningful
# containing folder, so work stays in whatever folder we were invoked from.
if File.directory?(MEDIA_PATH)
  Dir.chdir(File.expand_path(MEDIA_PATH))

  isos = Dir.glob('*.iso')
  if isos.length != 1
    puts "Expected exactly one .iso file in #{ MEDIA_PATH }, found #{ isos.length }".red
    exit 1
  end

  DVD_FILE = isos.first
elsif File.file?(MEDIA_PATH)
  expanded = File.expand_path(MEDIA_PATH)
  Dir.chdir(File.dirname(expanded))

  DVD_FILE = File.basename(expanded)
else
  DVD_FILE = MEDIA_PATH
end

REQUIRED_BINARIES = %w[lsdvd mediainfo magick ffmpeg flatpak].freeze
REQUIRED_FLATPAK_APPS = %w[fr.handbrake.ghb].freeze

def binary_available?(name)
  system("command -v #{ name } > /dev/null 2>&1")
end

def flatpak_app_available?(app_id)
  `flatpak list --app --columns=application 2>/dev/null`.split("\n").include?(app_id)
end

missing_binaries = REQUIRED_BINARIES.reject { |bin| binary_available?(bin) }
missing_apps = REQUIRED_FLATPAK_APPS.reject { |app| flatpak_app_available?(app) }

unless missing_binaries.empty? && missing_apps.empty?
  missing_binaries.each { |bin| puts "Missing required binary: #{ bin }".red }
  missing_apps.each { |app| puts "Missing required flatpak app: #{ app } (try: flatpak install #{ app })".red }
  exit 1
end

if File.exist?('roncoder.json')
  CONFIG = ::JSON.parse(File.read('roncoder.json'))
else
  CONFIG = {
    'title' => File.basename(DVD_FILE, '.iso'),
    'dvd' => nil,
    'handbrake_config' => File.join(SCRIPT_DIR, 'presets.json'),
    'tmp_dir' => './tmp',
    'thumbnail_tmp_dir' => './thumbnails',
    # out_dir isn't set here -- it's always derived from `title` (see below),
    # since a fresh config's title is still just an ISO-basename placeholder.
    'log_file' => './roncoder.log',
    'split_chapters' => true,
    'folder_thumbnail' => './folder.jpg',
    'global_config' => {
      'auto_quality' => true,
      'min_quality' => 15,
      'max_quality' => 25,
      'quality' => 20,
      'min_bit_rate' => 1500,
      'max_bit_rate' => 2500,
      'rip_thumbnail' => true,
      'manual_thumbnail' => nil,
      # 'rip_video' => 'auto', # Not sure how/if I should handle this...
      'thumbnail_offset' => '3000ms',
      'thumbnail_preview' => true,
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
      'crop_mode' => 'auto',
      'crop' => {
        'top' => 0,
        'bottom' => 0,
        'left' => 0,
        'right' => 0,
      },
    }
  }

  CONFIG['dvd'] = DVD_FILE

  puts "No 'roncoder.json' found; creating one with a placeholder title of #{ CONFIG['title'].inspect }.".green
  atomic_write('roncoder.json', JSON.pretty_generate(CONFIG))
end

# Always derived from the current title (not a fixed default kept only at
# creation time) -- title is often just an ISO-basename placeholder on the
# first run and gets polished later via apply-metadata.rb, and out_dir
# should track that so the output folder is upload-ready (named after the
# disc, not the generic "out") without a separate manual rename step.
CONFIG['out_dir'] = "./#{ sanitize_filename(CONFIG['title']) }"

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

unless File.exist?(CONFIG['handbrake_config'])
  log "Missing handbrake config: #{ CONFIG['handbrake_config'] }".red
  exit 1
end

unless File.exist?(CONFIG['dvd'])
  log "Missing DVD file: #{ CONFIG['dvd'] }".red
  exit 1
end

unless OPTS[:dry_run]
  # Keep the temp dir
  FileUtils.mkdir_p(CONFIG['tmp_dir'], verbose: true)

  # Delete the out_dir if it exists
  if CONFIG['out_dir'].nil? || CONFIG['out_dir'].empty?
    log 'Missing out_dir config!'.red
    exit 1
  end
  FileUtils.rm_rf(CONFIG['out_dir'], verbose: true)
  FileUtils.mkdir_p(CONFIG['out_dir'], verbose: true)

  # Delete the thumbnail_tmp_dir if it exists
  if CONFIG['thumbnail_tmp_dir'].nil? || CONFIG['thumbnail_tmp_dir'].empty?
    log 'Missing thumbnail_tmp_dir config!'.red
    exit 1
  end
  FileUtils.rm_rf(CONFIG['thumbnail_tmp_dir'], verbose: true)
  FileUtils.mkdir_p(CONFIG['thumbnail_tmp_dir'], verbose: true)
end

if CONFIG['titles'].nil? || CONFIG['titles'].empty?
  CONFIG['titles'] ||= {}

  title_output = `lsdvd \"#{ CONFIG['dvd'] }\" 2>/dev/null`

  if title_output.nil? || title_output.empty?
    log 'Failed to run lsdvd!'.red
    exit 1
  end

  title_output.split(/\r?\n/).each do |l|
    log("lsdvd line: #{ l }", display: false)
    if l =~ /^Title: ([0-9]+),.*Length: ([0-9:.]+).*Chapters: ([0-9]+),/
      title = Regexp.last_match(1).to_i
      length = Regexp.last_match(2)
      chapters = Regexp.last_match(3).to_i

      if CONFIG['split_chapters']
        CONFIG['titles'][title] = {
          'length' => length,
        }
        CONFIG['titles'][title]['chapters'] = {}

        1.upto(chapters) do |c|
          CONFIG['titles'][title]['chapters'][c] = {
            'title' => 'Title %02d chapter %02d' % [title, c],
          }
        end
      else
        CONFIG['titles'][title] = {
          'title' => 'Title %02d' % [title],
          'length' => length,
        }
      end
    end
  end

  puts "Configured the chapters/titles - have a look to make sure it's okay!".green
  puts 'NOTE: chapters/titles can override the global_config!'.green
  atomic_write('roncoder.json', JSON.pretty_generate(CONFIG))
  exit
end

def crop_args(config)
  # Missing crop_mode means this config predates the field entirely, back
  # when --crop-mode custom was the only behavior -- default to custom (not
  # auto) so old configs keep their original crop values and tmp/ cache
  # instead of silently switching modes underneath them.
  if config['crop_mode'] == 'auto'
    '--crop-mode auto'
  else
    "--crop-mode custom --crop #{ config['crop']['top'] }:#{ config['crop']['bottom'] }:#{ config['crop']['left'] }:#{ config['crop']['right'] }"
  end
end

def rip_video(config, title, chapter = nil)
  log("Ripping title #{ title } / chapter #{ chapter || 'n/a' } @ quality #{ config['quality'] }".green)
  outfile = get_tmp_filename(title: title, chapter: chapter, config: config)
  log("...into outfile #{ outfile }".green)

  if File.exist?(outfile) && get_duration(outfile) != -1
    log "Already ripped; skipping: #{ outfile }".cyan
    return outfile
  end

  if config['video']
    return rip_from_video_override(config, title, chapter, outfile)
  end

  log "Ripping: #{ outfile }.....".green
  system(<<~FLATPAK
    flatpak run --command=HandBrakeCLI fr.handbrake.ghb \
      --json \
      --preset-import-file "#{ CONFIG['handbrake_config'] }" \
      --preset Ron \
      --quality "#{ config['quality'] }" \
      #{ crop_args(config) } \
      -i "#{ CONFIG['dvd'] }" \
      --aencoder copy:aac \
      -t "#{ title }" \
      #{ chapter.nil? ? '' : "-c \"#{ chapter }\"" } \
      -o "#{ outfile }"
  FLATPAK
        )

  if File.exist?(outfile)
    log "Done @ #{ outfile }".green
    return outfile
  else
    log "Failed @ #{ outfile }!!".red
    FAILED_RIPS << {
      chapter: chapter,
      title: title,
    }

    return nil
  end
end

# A title/chapter can override the normal HandBrake DVD rip with 'video',
# pointing at an already-extracted source file instead of an -i/-t/-c
# HandBrake pull off CONFIG['dvd'] -- for content dvdunauthor/manual PGC
# analysis recovered that HandBrake's own disc scan never found as a
# rippable title/chapter at all (see the Mark Mason "Put & Take" recovery,
# where the real lecture lived in PGCs outside the one PGC HandBrake ever
# numbered as chapters). Same idea, and the same plain-ffmpeg re-encode
# settings, as split-file.rb's per-title 'video' override -- just reached
# from roncoder.rb's normal per-chapter rip loop instead of split-file.rb's
# cut loop, so it participates in the same tmp/ cache and out_dir rebuild as
# every other chapter on the disc.
def rip_from_video_override(config, title, chapter, outfile)
  source_video = config['video']
  unless source_video && File.exist?(source_video)
    log "Missing source video override for title #{ title } chapter #{ chapter || 'n/a' }: #{ source_video.inspect }".red
    FAILED_RIPS << {
      chapter: chapter,
      title: title,
    }
    return nil
  end

  log "Encoding from source video override: #{ source_video } -> #{ outfile }".green
  system(<<~FFMPEG)
    ffmpeg -y -i "#{ source_video }" \
      -c:v libx264 -crf 18 -preset medium -c:a aac -movflags +faststart \
      "#{ outfile }"
  FFMPEG

  if File.exist?(outfile) && get_duration(outfile) != -1
    log "Done @ #{ outfile }".green
    return outfile
  else
    log "Failed @ #{ outfile }!!".red
    FAILED_RIPS << {
      chapter: chapter,
      title: title,
    }
    return nil
  end
end

def get_bit_rate(file)
  # mediainfo reports space-grouped thousands for normal clips ("1 849
  # kb/s") but switches to a decimal fraction for very short/low-bitrate
  # ones ("11.9 kb/s") -- match both.
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

def rip_video_with_bitrate_target(config, title, chapter)
  outfile = rip_video(config, title, chapter)
  if outfile.nil?
    return nil
  end

  loop do
    bit_rate = get_bit_rate(outfile)
    if bit_rate == -1
      # A file mediainfo can't get a bitrate for is either a genuinely
      # tiny/degenerate chapter (real content, just very short) or a
      # HandBrake rip that silently failed (e.g. a NAV-packet read error
      # part-way through the disc) and left behind a near-empty stub --
      # those two cases look identical to get_bit_rate alone. Use duration
      # to tell them apart: a real chapter, however short, still has a
      # parseable duration; a failed rip doesn't. Only accept the former.
      if get_duration(outfile) == -1
        log "Failed to get bitrate OR duration for #{ outfile } -- looks like a failed rip, not a short chapter. Treating as failed.".red
        FAILED_RIPS << {
          chapter: chapter,
          title: title,
        }
        return nil
      end

      log "Failed to get bitrate for #{ outfile }, but duration looks valid -- accepting as a short/degenerate chapter.".red
      return outfile, config['quality']
    end

    if bit_rate < config['min_bit_rate']
      log "Bitrate is too low: #{ bit_rate }".cyan

      if config['quality'] <= config['min_quality']
        log "Bitrate is too log, but we've done all we can do!".red
        return outfile, config['quality']
      end

      config['quality'] -= 1
      outfile = rip_video(config, title, chapter)
      if outfile.nil?
        return nil
      end
    elsif bit_rate > config['max_bit_rate']
      log "Bitrate is too high: #{ bit_rate }".cyan

      if config['quality'] >= config['max_quality']
        log "Bitrate is too high, but we've done all we can do!".red
        return outfile, config['quality']
      end

      config['quality'] += 1
      outfile = rip_video(config, title, chapter)
      if outfile.nil?
        return nil
      end
    else
      log "Bitrate looks good: #{ bit_rate }".green
      return outfile, config['quality']
    end
  end
end

def do_thumbnail(config, base_filename, video_file)
  base_thumbnail = nil
  if config['rip_thumbnail']
    log("Ripping thumbnail at offset #{ config['thumbnail_offset'] }")
    tempfile = Tempfile.create(['thumbnail', '.jpg'])
    tempfile.close

    system("ffmpeg -y -ss #{ config['thumbnail_offset'] } -i \"#{ video_file }\" -frames:v 1 -q:v 2 \"#{ tempfile.to_path }\"")
    base_thumbnail = tempfile.to_path
  elsif config['manual_thumbnail']
    log("Using manual thumbnail: #{ config['manual_thumbnail'] }")
    base_thumbnail = config['manual_thumbnail'].gsub(/%%TITLE%%/, config['title'])
  end

  if base_thumbnail.nil?
    return
  end

  log("Copying original thumbnail to #{ CONFIG['thumbnail_tmp_dir'] }")
  FileUtils.cp(base_thumbnail, File.join(CONFIG['thumbnail_tmp_dir'], "#{ base_filename }#{ File.extname(base_thumbnail) }"), verbose: true)

  log("Resizing thumbnail into #{ CONFIG['out_dir'] }")

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

def do_nfo(config, base_filename)
  nfo_file = File.join(CONFIG['out_dir'], "#{ base_filename }.nfo")
  log("Creating .nfo file: #{ nfo_file }")

  metadata = config['metadata']
  if metadata.nil? || metadata.empty?
    log "Missing 'metadata' entry in the config file!".red
    exit 1
  end

  if config['metadata']['year'].nil? || config['metadata']['year'] == 0
    log "Please fill out the 'metadata' section".red
    exit 1
  end

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
    if config['metadata'][key] && (!config['metadata'][key].is_a?(String) || !config['metadata'][key].empty?)
      if config['metadata'][key].is_a?(String) && config['metadata'][key].include?("\n")
        nfo << "  <#{ key }><![CDATA[#{ config['metadata'][key] }]]></#{ key }>"
      else
        nfo << "  <#{ key }>#{ config['metadata'][key] }</#{ key }>"
      end
    end
  end

  config['metadata']['actor']&.each do |actor|
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

  nfo_file = File.join(CONFIG['out_dir'], "#{ base_filename }.nfo")
  File.write(nfo_file, nfo.join("\n"))
end

def crop_cache_key(config)
  # Same default as crop_args -- missing crop_mode means custom, not auto.
  if config['crop_mode'] == 'auto'
    'auto'
  else
    '%d:%d:%d:%d' % [config['crop']['top'], config['crop']['bottom'], config['crop']['left'], config['crop']['right']]
  end
end

def get_tmp_filename(title:, chapter:, config:)
  if chapter.nil?
    outfile = File.join(CONFIG['tmp_dir'], '%02d.%d.%s.mp4' % [title, config['quality'], crop_cache_key(config)])
  else
    outfile = File.join(CONFIG['tmp_dir'], '%02d-%02d.%d.%s.mp4' % [title, chapter, config['quality'], crop_cache_key(config)])
  end

  return outfile
end

def describe_rip(title:, chapter:, config:)
  outfile = get_tmp_filename(title: title, chapter: chapter, config: config)

  base_filename = if chapter.nil?
    '%02d %s' % [title, sanitize_filename(config['title'])]
  else
    '%02d-%02d %s' % [title, chapter, sanitize_filename(config['title'])]
  end

  puts "Title #{ title } chapter #{ chapter || 'n/a' }: quality #{ config['quality'] }, #{ crop_args(config) }".cyan
  puts "  would rip into: #{ outfile }".cyan
  puts "  would produce:  #{ File.join(CONFIG['out_dir'], "#{ base_filename }.mp4") }".cyan
end

def do_rip(title:, chapter:, config:, updateable_config:)
  log("Starting rip for title #{ title } chapter #{ chapter || 'n/a' }".green)
  log("Config: #{ config.to_json }", display: false)

  updateable_config['info'] ||= {}
  updateable_config['info']['tmp_file']

  if config['auto_quality']
    log('Ripping with automatic quality')
    outfile, quality = rip_video_with_bitrate_target(config, title&.to_i, chapter&.to_i)
    updateable_config['quality'] = quality || config['quality']
    log("Ripped into #{ outfile } @ quality #{ quality }")
  else
    log('Ripping with configured quality')
    outfile = rip_video(config, title&.to_i, chapter&.to_i)
  end

  if outfile.nil?
    log 'Rip failed!'.red
    return
  end

  updateable_config['info']['bit_rate'] = get_bit_rate(outfile)
  updateable_config['info']['duration'] = get_duration(outfile)

  if chapter.nil?
    base_filename = '%02d %s' % [title, sanitize_filename(config['title'])]
  else
    base_filename = '%02d-%02d %s' % [title, chapter, sanitize_filename(config['title'])]
  end

  log("Base filename: #{ base_filename }")

  FileUtils.cp(outfile, File.join(CONFIG['out_dir'], "#{ base_filename }.mp4"), verbose: true)
  do_thumbnail(config, base_filename, outfile)
  do_nfo(config, base_filename)
end

begin
  CONFIG['titles'].each_pair do |title, title_config|
    if CONFIG['split_chapters']
      title_config['chapters'].each_pair do |chapter, chapter_config|
        # Ensure no stale config is around
        config = JSON.parse(CONFIG['global_config'].to_json)
                     .merge(title_config.compact)
                     .merge(chapter_config.compact)
        # A per-title/chapter `metadata` override (e.g. just a `year`) should
        # layer on top of the disc-wide metadata, not replace it wholesale --
        # the outer `.merge`s above are shallow and would otherwise drop
        # genre/director/writer/actor for any title with its own year.
        config['metadata'] = JSON.parse(CONFIG['global_config']['metadata'].to_json)
                                  .merge((title_config['metadata'] || {}).compact)
                                  .merge((chapter_config['metadata'] || {}).compact)

        if OPTS[:dry_run]
          describe_rip(title: title, chapter: chapter, config: config)
        else
          do_rip(
            title: title,
            chapter: chapter,
            config: config,
            updateable_config: chapter_config,
          )
          atomic_write('roncoder.json', JSON.pretty_generate(CONFIG))
        end
      end
    else
      config = JSON.parse(CONFIG['global_config'].to_json)
                   .merge(title_config.compact)
      config['metadata'] = JSON.parse(CONFIG['global_config']['metadata'].to_json)
                                .merge((title_config['metadata'] || {}).compact)

      if OPTS[:dry_run]
        describe_rip(title: title, chapter: nil, config: config)
      else
        do_rip(
          title: title,
          chapter: nil,
          config: config,
          updateable_config: title_config,
        )
        atomic_write('roncoder.json', JSON.pretty_generate(CONFIG))
      end
    end
  end

  if OPTS[:dry_run]
    puts
    puts 'Dry run complete - no video/thumbnails were ripped.'.green
  else
    if CONFIG['folder_thumbnail'].nil? || CONFIG['folder_thumbnail'].empty? || !File.exist?(CONFIG['folder_thumbnail'])
      log "Missing the folder thumbnail: #{ CONFIG['folder_thumbnail'] }".red
      exit 1
    end

    FileUtils.cp(CONFIG['folder_thumbnail'], File.join(CONFIG['out_dir'], "folder#{ File.extname(CONFIG['folder_thumbnail']) }"), verbose: true)

    unless FAILED_RIPS.empty?
      log 'The following titles/chapters failed to rip:'.red
      log FAILED_RIPS.to_s.red
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
