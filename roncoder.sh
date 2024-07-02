#!/bin/bash

set -euo pipefail

# Print errors in red
err() {
  echo -ne '\e[31m\e[1m' # Red + Bold
  echo -e "$@"
  echo -ne '\e[0m'

  exit 1
}

# These are probably fine
CD=${CD:-/dev/sr0}
MOUNT=${MOUNT:-/mnt/dvd}

echo "Unmounting $MOUNT, just in case"
sudo umount "$MOUNT" || true

if [ -z ${TITLES+x} ]; then
  echo "Please set the TITLES variable to a list of titles to rip"
  echo "Trying to get list of titles..."
  echo

  echo "TITLES=\$(seq 1 $(lsdvd "$CD" 2>/dev/null | grep -Eo "^Title: ([0-9]+)" | cut -c8- | tail -n1)) <...>"
  exit 1
fi


echo "Mounting $CD to $MOUNT"
sudo mount "$CD" "$MOUNT" -o uid=ron -o loop || err "Couldn't mount the DVD!"

RIP_DIR=${RIP_DIR:-$MOUNT/VIDEO_TS}
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PRESETS=${PRESETS:-"$SCRIPT_DIR/presets.json"}

echo
echo "Ripping from $RIP_DIR with presets $PRESETS"

PREVIEW=${PREVIEW:-true}
VIDEO_DIR=${VIDEO_DIR:-./videos}
THUMBNAIL_DIR=${THUMBNAIL_DIR:-./thumbnails}
RESULT_FILE=${RESULT_FILE:-./output.txt}
rm -f "$RESULT_FILE"

# You probably want to set these
CROP_TOP=${CROP_TOP:-0}
CROP_BOTTOM=${CROP_BOTTOM:-0}
CROP_LEFT=${CROP_LEFT:-0}
CROP_RIGHT=${CROP_RIGHT:-0}
QUALITY=${QUALITY:-19}
THUMBNAIL_OFFSET=${THUMBNAIL_OFFSET:-3}

echo "Quality = $QUALITY"
echo "Crop (top:bottom:left:right) = $CROP_TOP:$CROP_BOTTOM:$CROP_LEFT:$CROP_RIGHT"

RIP_VIDEO=${RIP_VIDEO:-true}
RIP_THUMBNAIL=${RIP_THUMBNAIL:-true}

FRAMES=''
if [ "$PREVIEW" = "true" ] ; then
  PREVIEW_START=${PREVIEW_START:-1000}
  PREVIEW_END=${PREVIEW_END:-2000}
  FRAMES=" --start-at frames:$PREVIEW_START --stop-at frames:$PREVIEW_END "

  echo "Preview from frame $PREVIEW_START to $PREVIEW_END"
fi

mkdir -p $VIDEO_DIR
mkdir -p $THUMBNAIL_DIR

for i in $TITLES; do
  VIDEO_FILE="$VIDEO_DIR/$i.mp4"
  THUMBNAIL_FILE="$THUMBNAIL_DIR/$i.jpg"

  if [ "$RIP_VIDEO" = "true" ]; then
    echo "Ripping title $i from $RIP_DIR to $VIDEO_FILE"

    # Rip the video
    set -x
    flatpak run --command=HandBrakeCLI fr.handbrake.ghb \
      --json \
      --preset-import-file "$PRESETS" \
      --preset Ron \
      --quality "$QUALITY" \
      $FRAMES \
      --crop-mode custom \
      --crop $CROP_TOP:$CROP_BOTTOM:$CROP_LEFT:$CROP_RIGHT \
      -i "$RIP_DIR" \
      --aencoder copy:aac \
      -t "$i" \
      -o "$VIDEO_FILE" 2>/dev/null
    set +x

    mediainfo "$VIDEO_FILE" | grep '^Bit rate   ' | head -n1 | sed "s/^/$i => /" | tee -a $RESULT_FILE
  fi

  if [ "$RIP_THUMBNAIL" = "true" ]; then
    echo "Ripping thumbnail from $VIDEO_FILE to $THUMBNAIL_FILE @ offset $THUMBNAIL_OFFSET"

    $SCRIPT_DIR/thumbnailer "$VIDEO_DIR/$i.mp4" "$THUMBNAIL_FILE" "$THUMBNAIL_OFFSET"
  fi
  echo
done

sudo umount "$MOUNT" || true
