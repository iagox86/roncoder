require 'date'
require 'json'
require 'fileutils'
require 'tempfile'
require 'rainbow/refinement'

using Rainbow
SCRIPT_DIR = File.dirname(File.expand_path(__FILE__))

if ARGV.length < 2
  puts "Usage: #{ $PROGRAM_NAME } <video> <thumbnail>"
  exit 1
end

VIDEO = ARGV[0]
unless File.file?(VIDEO)
  puts "No such video file: #{ VIDEO }".red
  exit 1
end

THUMBNAIL = ARGV[1]
unless File.file?(THUMBNAIL)
  puts "No such thumbnail file: #{ THUMBNAIL }".red
  exit 1
end

VIDEO_DIR = File.dirname(VIDEO)
VIDEO_NAME = File.basename(VIDEO, File.extname(VIDEO))
THUMBNAIL_EXT = File.extname(THUMBNAIL)

THUMBNAIL_POSTER_SIZE = '1000x1500'
THUMBNAIL_FANART_SIZE = '1920x1080'

# Do the thumbnail
puts "Resizing thumbnail #{ THUMBNAIL } into #{ VIDEO_DIR }..."

thumbnail_file = File.join(VIDEO_DIR, "#{ VIDEO_NAME }.jpg")
system("magick \"#{ THUMBNAIL }\" -resize #{ THUMBNAIL_POSTER_SIZE } -background none -gravity center -extent #{ THUMBNAIL_POSTER_SIZE } \"#{ thumbnail_file }\"")

fanart_file = File.join(VIDEO_DIR, "#{ VIDEO_NAME }-fanart.jpg")
system("magick \"#{ THUMBNAIL }\" -resize #{ THUMBNAIL_FANART_SIZE } -background none -gravity center -extent #{ THUMBNAIL_FANART_SIZE } \"#{ fanart_file }\"")

logo_file = File.join(VIDEO_DIR, "#{ VIDEO_NAME }-logo.jpg")
system("magick \"#{ THUMBNAIL }\" -resize #{ THUMBNAIL_POSTER_SIZE } -background none -gravity center -extent #{ THUMBNAIL_POSTER_SIZE } \"#{ logo_file }\"")

NFO_FILE = File.join(VIDEO_DIR, "#{ VIDEO_NAME }.nfo")
puts "Creating .nfo file: #{ NFO_FILE }"

nfo = [
  '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>',
  '<movie>',
  "  <title>#{ VIDEO_NAME }</title>",
  "  <sorttitle>#{ VIDEO_NAME }</sorttitle>",
  '  <plot></plot>',
  '  <genre></genre>',
  '  <year></year>',
  '  <director></director>',
  '  <writer></writer>',
  '  <actor>',
  '    <name></name>',
  '    <role></role>',
  '    <thumb>https://www.javaop.com/headshots/TODO.jpg</thumb>',
  '  </actor>',
  '</movie>',
]

File.write(NFO_FILE, nfo.join("\n"))
