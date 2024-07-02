#!/bin/bash

set -euo pipefail

POSTER_SIZE=1000x1500
FANART_SIZE=1920x1080

# Print errors in red
err() {
  echo -ne '\e[31m\e[1m' # Red + Bold
  echo -e "$@"
  echo -ne '\e[0m'

  exit 1
}

if [ ! -d thumbnails ] || [ ! -d titles ] || [ ! -d videos ]; then
  err "You must have the directories: thumbnails/, titles/, and videos/"
fi

if [ -d completed ]; then
  err "Please delete completed/ first"
fi

if [ ! -f metadata.nfo ]; then
  err "Please copy metadata.nfo into this directory, and fill it out (other than title)"
fi

mkdir -p completed

for video in videos/*; do
  basename=$(basename "$video" .mp4)
  title=$(cat "titles/$basename.txt" | sed 's/:/ -/g')
  thumbnail="thumbnails/$basename.jpg"
  metadata="metadata.nfo"
  number=$(printf "%02d" $basename)
  full_name="$number - $title"
  outfile="completed/$full_name"

  sed -e "s/NN/$number/g" -e "s/TITLE/$title/g" $metadata > "$outfile.nfo"
  magick "$thumbnail" -resize $POSTER_SIZE -background none -gravity center -extent $POSTER_SIZE "$outfile.jpg"
  magick "$thumbnail" -resize $FANART_SIZE -background none -gravity center -extent $FANART_SIZE "$outfile-fanart.jpg"

  magick "$thumbnail" -resize $POSTER_SIZE -background none -gravity center -extent $POSTER_SIZE "$outfile-logo.jpg"

  cp -v "$video" "$outfile.mp4"

  # If I need to embed metadata:
  # ffmpeg -i "$video" -i "$thumbnail" -map 0 -map 1 -c copy -c:v:1 jpg -disposition:v:1 attached_pic -metadata title="$full_name" completed/"$outfile".mp4; end
done

