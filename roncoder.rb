require 'date'
require 'json'
require 'fileutils'
require 'tempfile'
require 'rainbow/refinement'

using Rainbow
SCRIPT_DIR = File.dirname(File.expand_path(__FILE__))
FAILED_RIPS = []

if File.exist?('roncoder.json')
  CONFIG = ::JSON.parse(File.read('roncoder.json'))
else
  CONFIG = {
    'title' => nil,
    'dvd' => nil,
    'handbrake_config' => File.join(SCRIPT_DIR, 'presets.json'),
    'tmp_dir' => './tmp',
    'thumbnail_tmp_dir' => './thumbnails',
    'out_dir' => './out',
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
      'thumbnail_offset' => "3000ms",
      'thumbnail_preview' => true,
      'thumbnail_poster_size' => '1000x1500',
      'thumbnail_fanart_size' => '1920x1080',
      'metadata' => {
        'year' => 0,
        'plot' => '',
        'genre' => 'Magic',
        'director' => '',
        'writer' => '',
        'actor' => [
          'name' => '',
          'role' => 'Self',
        ],
      },
      'crop' => {
        'top' => 0,
        'bottom' => 0,
        'left' => 0,
        'right' => 0,
      },
    }
  }

  puts "What's the full path to the ISO or drive (like /dev/sr0)?"
  CONFIG['dvd'] = $stdin.gets&.chomp
  if CONFIG['dvd'].nil? || CONFIG['dvd'].empty?
    CONFIG['dvd'] = '/dev/sr0'
  end

  File.write('roncoder.json', JSON.pretty_generate(CONFIG))
  puts "Wrote default 'roncoder.json', edit it and run again!".green
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
  f.puts("#{ DateTime.now.to_s } #{ text }")
  f.close
end

if !File.exist?(CONFIG['handbrake_config'])
  log "Missing handbrake config: #{ CONFIG['handbrake_config'] }".red
  exit 1
end

if !File.exist?(CONFIG['dvd'])
  log "Missing DVD file: #{ CONFIG['dvd'] }".red
  exit 1
end

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

if CONFIG['titles'].nil? || CONFIG['titles'].empty?
  CONFIG['titles'] ||= {}

  title_output = `lsdvd #{ CONFIG['dvd'] } 2>/dev/null`

  if title_output.nil? || title_output.empty?
    log "Failed to run lsdvd!".red
    exit 1
  end

  title_output.split(/\r?\n/).each do |l|
    log("lsdvd line: #{ l.to_s }", display: false)
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
            'title' => "Title %02d chapter %02d" % [title, c],
          }
        end
      else
        CONFIG['titles'][title] = {
          'title' => "Title %02d" % [title],
          'length' => length,
        }
      end
    end
  end

  puts "Configured the chapters/titles - have a look to make sure it's okay!".green
  puts "NOTE: chapters/titles can override the global_config!".green
  File.write('roncoder.json', JSON.pretty_generate(CONFIG))
  exit
end

def rip_video(config, title, chapter = nil)
  log("Ripping title #{ title } / chapter #{ chapter || 'n/a' } @ quality #{ config['quality'] }".green)
  outfile = get_tmp_filename(title: title, chapter: chapter, config: config)
  log("...into outfile #{ outfile }".green)

  if File.exist?(outfile)
    log "Already ripped; skipping: #{ outfile }".cyan
    return outfile
  end

  log "Ripping: #{ outfile }.....".green
  system(<<~EOF
    flatpak run --command=HandBrakeCLI fr.handbrake.ghb \
      --json \
      --preset-import-file "#{ CONFIG['handbrake_config'] }" \
      --preset Ron \
      --quality "#{ config['quality'] }" \
      --crop-mode custom \
      --crop #{ config['crop']['top'] }:#{ config['crop']['bottom'] }:#{ config['crop']['left'] }:#{ config['crop']['right'] } \
      -i "#{ CONFIG['dvd'] }" \
      --aencoder copy:aac \
      -t "#{ title }" \
      #{ chapter.nil? ? '' : "-c \"#{ chapter }\"" } \
      -o "#{ outfile }"
    EOF
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

def get_bit_rate(file)
  `mediainfo "#{ file }"`.split(/\r?\n/).each do |line|
    if line =~ /^Bit rate    [ ]+: ([0-9]+ [0-9]*) ?kb/
      return Regexp.last_match(1).gsub(/ /, '').to_i
    end
  end

  return -1
end

def get_duration(file)
  `mediainfo "#{ file }"`.split(/\r?\n/).each do |line|
    if line =~ /^Duration    [ ]+: (.*)/
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
      log "Failed to get bitrate for #{ outfile }!".red
      exit 1
    end

    if bit_rate < config['min_bit_rate']
      log "Bitrate is too low: #{ bit_rate}".cyan

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
      log "Bitrate is too high: #{ bit_rate}".cyan

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

  %w[plot genre year director writer].each do |key|
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

def get_tmp_filename(title:, chapter:, config:)
  if chapter.nil?
    outfile = File.join(CONFIG['tmp_dir'], "%02d.%d.%d:%d:%d:%d.mp4" % [title, config['quality'], config['crop']['top'], config['crop']['bottom'], config['crop']['left'], config['crop']['right']])
  else
    outfile = File.join(CONFIG['tmp_dir'], "%02d-%02d.%d.%d:%d:%d:%d.mp4" % [title, chapter, config['quality'], config['crop']['top'], config['crop']['bottom'], config['crop']['left'], config['crop']['right']])
  end
end

def do_rip(title:, chapter:, config:, updateable_config:)
  log("Starting rip for title #{ title } chapter #{ chapter || 'n/a' }".green)
  log("Config: #{ config.to_json }", display: false)

  updateable_config['info'] ||= {}
  updateable_config['info']['tmp_file']

  if config['auto_quality']
    log("Ripping with automatic quality")
    outfile, quality = rip_video_with_bitrate_target(config, title&.to_i, chapter&.to_i)
    updateable_config['quality'] = quality || config['quality']
    log("Ripped into #{ outfile } @ quality #{ quality }")
  else
    log("Ripping with configured quality")
    outfile = rip_video(config, title&.to_i, chapter&.to_i)
  end

  if outfile.nil?
    log "Rip failed!".red
    return
  end

  updateable_config['info']['bit_rate'] = get_bit_rate(outfile)
  updateable_config['info']['duration'] = get_duration(outfile)

  if chapter.nil?
    base_filename = "%02d %s" % [title, config['title']]
  else
    base_filename = "%02d-%02d %s" % [title, chapter, config['title']]
  end

  log("Base filename: #{ base_filename }")

  FileUtils.cp(outfile, File.join(CONFIG['out_dir'], "#{ base_filename }.mp4"), verbose: true)
  do_thumbnail(config, base_filename, outfile)
  do_nfo(config, base_filename)
end

begin
  CONFIG['titles'].each_pair do |title, title_config|
    outfile = nil
    if CONFIG['split_chapters']
      title_config['chapters'].each_pair do |chapter, chapter_config|
        # Ensure no stale config is around
        config = JSON.parse(CONFIG['global_config'].to_json)
          .merge(title_config.compact)
          .merge(chapter_config.compact)

        do_rip(
          title: title,
          chapter: chapter,
          config: config,
          updateable_config: chapter_config,
        )
        File.write('roncoder.json', JSON.pretty_generate(CONFIG))
      end
    else
      do_rip(
        title: title,
        chapter: nil,
        config: config,
        updateable_config: title_config,
      )
      File.write('roncoder.json', JSON.pretty_generate(CONFIG))
    end
  end

  if CONFIG['folder_thumbnail'].nil? || CONFIG['folder_thumbnail'].empty? || !File.exist?(CONFIG['folder_thumbnail'])
    log "Missing the folder thumbnail: #{ CONFIG['folder_thumbnail'] }".red
    exit 1
  end

  FileUtils.cp(CONFIG['folder_thumbnail'], File.join(CONFIG['out_dir'], "folder#{ File.extname(CONFIG['folder_thumbnail']) }"), verbose: true)

  unless FAILED_RIPS.empty?
    log "The following titles/chapters failed to rip:".red
    log FAILED_RIPS.to_s.red
  end
ensure
  File.write('roncoder.json', JSON.pretty_generate(CONFIG))
end

puts
puts "All done?".green
puts
if CONFIG['title']
  puts "rsync -rv out/ ron@home:/data/external/media/videos/Magic/Lectures/'#{ CONFIG['title'] }'/".green
end
