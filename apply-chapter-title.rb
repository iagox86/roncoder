require 'json'
require 'rainbow/refinement'
require 'optimist'

using Rainbow

def atomic_write(path, content)
  tmp_path = "#{ path }.tmp.#{ Process.pid }"
  File.write(tmp_path, content)
  File.rename(tmp_path, path)
end

CONFIRMED_BY_VALUES = %w[dvd_menu title_card manual other]

OPTS = Optimist.options do
  banner "Usage: #{ $PROGRAM_NAME } --title N [--chapter N] [--name TEXT] [--sort-title TEXT] [--thumbnail-offset MS] [--year YYYY] [--premiered YYYY-MM-DD] [--note TEXT] [--confirmed-by dvd_menu|title_card|manual|other] [--force]"
  opt :title, 'Title number', type: :integer, required: true
  opt :chapter, 'Chapter number (omit for a non-split title)', type: :integer
  opt :name, 'Proposed chapter/title text (e.g. read off a title card)', type: :string
  opt :sort_title, 'Proposed sort_title (e.g. a zero-padded episode number) for when narrative order differs from disc order', type: :string
  opt :thumbnail_offset, 'Proposed thumbnail offset, e.g. "12500ms"', type: :string
  opt :year, 'Per-title/chapter release year override (e.g. an individual production date read off a disc menu), overriding the disc-wide metadata year for just this title/chapter', type: :integer
  opt :premiered, 'Per-title/chapter exact release date (e.g. an individual production date read off a disc menu), format YYYY-MM-DD', type: :string
  opt :note, 'Free-text note flagging something a human should double-check (not used by roncoder.rb itself, just for review tooling)', type: :string
  opt :confirmed_by, "How --name was confirmed, for the review PDF's green confirmation column: #{ CONFIRMED_BY_VALUES.join(', ') } (not used by roncoder.rb itself)", type: :string
  opt :force, 'Overwrite even if the field looks human-edited', default: false
end

if OPTS[:confirmed_by] && !CONFIRMED_BY_VALUES.include?(OPTS[:confirmed_by])
  puts "--confirmed-by must be one of: #{ CONFIRMED_BY_VALUES.join(', ') }".red
  exit 1
end

unless File.exist?('roncoder.json')
  puts "No 'roncoder.json' in the current directory!".red
  exit 1
end

CONFIG = JSON.parse(File.read('roncoder.json'))

title_config = CONFIG['titles'] && CONFIG['titles'][OPTS[:title].to_s]
if title_config.nil?
  puts "No such title: #{ OPTS[:title] }".red
  exit 1
end

if OPTS[:chapter]
  target = title_config['chapters'] && title_config['chapters'][OPTS[:chapter].to_s]
  if target.nil?
    puts "No such chapter: #{ OPTS[:title] }-#{ OPTS[:chapter] }".red
    exit 1
  end
  default_title = 'Title %02d chapter %02d' % [OPTS[:title], OPTS[:chapter]]
else
  target = title_config
  default_title = 'Title %02d' % [OPTS[:title]]
end

if OPTS[:name]
  if !OPTS[:force] && target['title'] != default_title
    puts "Skipping title for #{ OPTS[:title] }-#{ OPTS[:chapter] }: already customized (#{ target['title'].inspect }); use --force to overwrite".yellow
  else
    target['title'] = OPTS[:name]
    puts "Set title for #{ OPTS[:title] }-#{ OPTS[:chapter] }: #{ OPTS[:name].inspect }".green
  end
end

if OPTS[:sort_title]
  if !OPTS[:force] && !target['sort_title'].nil?
    puts "Skipping sort_title for #{ OPTS[:title] }-#{ OPTS[:chapter] }: already set (#{ target['sort_title'].inspect }); use --force to overwrite".yellow
  else
    target['sort_title'] = OPTS[:sort_title]
    puts "Set sort_title for #{ OPTS[:title] }-#{ OPTS[:chapter] }: #{ OPTS[:sort_title] }".green
  end
end

if OPTS[:thumbnail_offset]
  # roncoder.rb passes this straight to `ffmpeg -ss`, which reads a bare number as *seconds* --
  # a caller passing "3000" meaning 3000ms would silently seek to 3000 seconds instead.
  thumbnail_offset = OPTS[:thumbnail_offset]
  if thumbnail_offset =~ /\A\d+\z/
    thumbnail_offset = "#{ thumbnail_offset }ms"
  end

  if !OPTS[:force] && !target['thumbnail_offset'].nil?
    puts "Skipping thumbnail_offset for #{ OPTS[:title] }-#{ OPTS[:chapter] }: already set (#{ target['thumbnail_offset'].inspect }); use --force to overwrite".yellow
  else
    target['thumbnail_offset'] = thumbnail_offset
    puts "Set thumbnail_offset for #{ OPTS[:title] }-#{ OPTS[:chapter] }: #{ thumbnail_offset }".green
  end
end

if OPTS[:year]
  target['metadata'] ||= {}
  if !OPTS[:force] && !target['metadata']['year'].nil?
    puts "Skipping year for #{ OPTS[:title] }-#{ OPTS[:chapter] }: already set (#{ target['metadata']['year'].inspect }); use --force to overwrite".yellow
  else
    target['metadata']['year'] = OPTS[:year]
    puts "Set year for #{ OPTS[:title] }-#{ OPTS[:chapter] }: #{ OPTS[:year] }".green
  end
end

if OPTS[:premiered]
  target['metadata'] ||= {}
  if !OPTS[:force] && !target['metadata']['premiered'].nil?
    puts "Skipping premiered for #{ OPTS[:title] }-#{ OPTS[:chapter] }: already set (#{ target['metadata']['premiered'].inspect }); use --force to overwrite".yellow
  else
    target['metadata']['premiered'] = OPTS[:premiered]
    puts "Set premiered for #{ OPTS[:title] }-#{ OPTS[:chapter] }: #{ OPTS[:premiered] }".green
  end
end

if OPTS[:note]
  if !OPTS[:force] && !target['note'].nil?
    puts "Skipping note for #{ OPTS[:title] }-#{ OPTS[:chapter] }: already set (#{ target['note'].inspect }); use --force to overwrite".yellow
  else
    target['note'] = OPTS[:note]
    puts "Set note for #{ OPTS[:title] }-#{ OPTS[:chapter] }: #{ OPTS[:note] }".green
  end
end

if OPTS[:confirmed_by]
  if !OPTS[:force] && !target['confirmed_by'].nil?
    puts "Skipping confirmed_by for #{ OPTS[:title] }-#{ OPTS[:chapter] }: already set (#{ target['confirmed_by'].inspect }); use --force to overwrite".yellow
  else
    target['confirmed_by'] = OPTS[:confirmed_by]
    puts "Set confirmed_by for #{ OPTS[:title] }-#{ OPTS[:chapter] }: #{ OPTS[:confirmed_by] }".green
  end
end

atomic_write('roncoder.json', JSON.pretty_generate(CONFIG))
