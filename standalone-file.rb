require 'json'
require 'rainbow/refinement'
require 'optimist'

using Rainbow
SCRIPT_DIR = File.dirname(File.expand_path(__FILE__))

def atomic_write(path, content)
  tmp_path = "#{ path }.tmp.#{ Process.pid }"
  File.write(tmp_path, content)
  File.rename(tmp_path, path)
end

OPTS = Optimist.options do
  banner "Usage: #{ $PROGRAM_NAME } <video> [thumbnail]"
end

if ARGV.empty? || ARGV.length > 2
  Optimist.die 'Expected 1 or 2 arguments: <video> [thumbnail]'
end

VIDEO_ARG = ARGV[0]
unless File.file?(VIDEO_ARG)
  puts "No such video file: #{ VIDEO_ARG }".red
  exit 1
end

THUMBNAIL_ARG = ARGV[1]
if THUMBNAIL_ARG && !File.file?(THUMBNAIL_ARG)
  puts "No such thumbnail file: #{ THUMBNAIL_ARG }".red
  exit 1
end

REQUIRED_BINARIES = %w[magick].freeze

def binary_available?(name)
  system("command -v #{ name } > /dev/null 2>&1")
end

missing_binaries = REQUIRED_BINARIES.reject { |bin| binary_available?(bin) }
unless missing_binaries.empty?
  missing_binaries.each { |bin| puts "Missing required binary: #{ bin }".red }
  exit 1
end

# Contain all work to the folder holding the video, same as roncoder.rb.
expanded_video = File.expand_path(VIDEO_ARG)
expanded_thumbnail = THUMBNAIL_ARG && File.expand_path(THUMBNAIL_ARG)
Dir.chdir(File.dirname(expanded_video))
VIDEO = File.basename(expanded_video)
THUMBNAIL = expanded_thumbnail
VIDEO_NAME = File.basename(VIDEO, File.extname(VIDEO))

if File.exist?('roncoder.json')
  CONFIG = ::JSON.parse(File.read('roncoder.json'))
else
  CONFIG = {
    'title' => VIDEO_NAME,
    'video' => VIDEO,
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
  }

  puts "No 'roncoder.json' found; creating one with a placeholder title of #{ CONFIG['title'].inspect }.".green
  atomic_write('roncoder.json', JSON.pretty_generate(CONFIG))
end

def do_thumbnail(config, base_filename, thumbnail)
  if thumbnail.nil?
    puts 'No thumbnail given; skipping poster/fanart/logo generation.'.cyan
    return
  end

  puts "Resizing thumbnail #{ thumbnail }...".green

  thumbnail_file = "#{ base_filename }.jpg"
  system("magick \"#{ thumbnail }\" -resize #{ config['thumbnail_poster_size'] } -background none -gravity center -extent #{ config['thumbnail_poster_size'] } \"#{ thumbnail_file }\"")

  fanart_file = "#{ base_filename }-fanart.jpg"
  system("magick \"#{ thumbnail }\" -resize #{ config['thumbnail_fanart_size'] } -background none -gravity center -extent #{ config['thumbnail_fanart_size'] } \"#{ fanart_file }\"")

  logo_file = "#{ base_filename }-logo.jpg"
  system("magick \"#{ thumbnail }\" -resize #{ config['thumbnail_poster_size'] } -background none -gravity center -extent #{ config['thumbnail_poster_size'] } \"#{ logo_file }\"")
end

def do_nfo(config, base_filename)
  nfo_file = "#{ base_filename }.nfo"
  puts "Creating .nfo file: #{ nfo_file }".green

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

  %w[plot genre year director writer].each do |key|
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

do_thumbnail(CONFIG, VIDEO_NAME, THUMBNAIL)
do_nfo(CONFIG, VIDEO_NAME)

puts
puts 'All done?'.green
