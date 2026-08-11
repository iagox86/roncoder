require 'json'
require 'rainbow/refinement'
require 'optimist'

using Rainbow

def atomic_write(path, content)
  tmp_path = "#{ path }.tmp.#{ Process.pid }"
  File.write(tmp_path, content)
  File.rename(tmp_path, path)
end

OPTS = Optimist.options do
  banner "Usage: #{ $PROGRAM_NAME } [--title TEXT] [--year YYYY] [--genre NAME] [--director NAME] [--writer NAME] [--plot TEXT] [--actor-name NAME ...] [--role ROLE ...] [--force]"
  opt :title, 'Disc/video display title', type: :string
  opt :year, 'Release year', type: :integer
  opt :genre, 'Genre (e.g. Magic, Cooking, Lockpicking)', type: :string
  opt :director, 'Director name', type: :string
  opt :writer, 'Writer name', type: :string
  opt :plot, 'Plot/synopsis text', type: :string
  opt :actor_name, 'Performer name (repeatable for multiple performers)', type: :strings
  opt :role, 'Role for the matching --actor-name, by position (defaults to "Self")', type: :strings
  opt :force, 'Overwrite even if metadata looks human-edited', default: false
end

unless File.exist?('roncoder.json')
  puts "No 'roncoder.json' in the current directory!".red
  exit 1
end

CONFIG = JSON.parse(File.read('roncoder.json'))
metadata = CONFIG['metadata'] || CONFIG.dig('global_config', 'metadata')

if metadata.nil?
  puts "No 'metadata' section (checked top-level and global_config) in roncoder.json!".red
  exit 1
end

def actors_untouched?(actors)
  actors.is_a?(Array) && actors.length == 1 && actors.first['name'] == '' && actors.first['role'] == 'Self'
end

def default_title(config)
  if config['dvd']
    File.basename(config['dvd'], '.iso')
  elsif config['video']
    File.basename(config['video'], File.extname(config['video']))
  end
end

if OPTS[:title]
  untouched = CONFIG['title'].nil? || CONFIG['title'] == default_title(CONFIG)
  if !OPTS[:force] && !untouched
    puts "Skipping title: already set (#{ CONFIG['title'].inspect }); use --force to overwrite".yellow
  else
    CONFIG['title'] = OPTS[:title]
    puts "Set title: #{ OPTS[:title] }".green
  end
end

if OPTS[:year]
  if !OPTS[:force] && metadata['year'] && metadata['year'] != 0
    puts "Skipping year: already set (#{ metadata['year'] }); use --force to overwrite".yellow
  else
    metadata['year'] = OPTS[:year]
    puts "Set year: #{ OPTS[:year] }".green
  end
end

%w[genre director writer plot].each do |field|
  value = OPTS[field.to_sym]
  next if value.nil?

  if !OPTS[:force] && metadata[field] && !metadata[field].empty?
    puts "Skipping #{ field }: already set (#{ metadata[field].inspect }); use --force to overwrite".yellow
  else
    metadata[field] = value
    puts "Set #{ field }: #{ value }".green
  end
end

if OPTS[:actor_name] && !OPTS[:actor_name].empty?
  if !OPTS[:force] && !actors_untouched?(metadata['actor'])
    puts "Skipping actor(s): already set (#{ metadata['actor'].to_json }); use --force to overwrite".yellow
  else
    metadata['actor'] = OPTS[:actor_name].each_with_index.map do |name, i|
      {
        'name' => name,
        'role' => (OPTS[:role] && OPTS[:role][i]) || 'Self',
      }
    end
    puts "Set actor(s): #{ metadata['actor'].to_json }".green
  end
end

atomic_write('roncoder.json', JSON.pretty_generate(CONFIG))
