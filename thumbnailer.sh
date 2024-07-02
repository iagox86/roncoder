#!/bin/bash

set -euo pipefail

# Print errors in red
err() {
  echo -ne '\e[31m\e[1m' # Red + Bold
  echo -e "$@"
  echo -ne '\e[0m'

  exit 1
}

if [ "$#" -ne 3 ]; then
  err "Usage: $0 <video> <thumbnail> <offset>"
fi

VIDEO_FILE=$1
THUMBNAIL_FILE=$2
OFFSET=$3

echo "Ripping thumbnail from $VIDEO_FILE to $THUMBNAIL_FILE @ offset $OFFSET"

ffmpeg -y -ss $OFFSET -i "$VIDEO_FILE" -frames:v 1 -q:v 2 "$THUMBNAIL_FILE"
