#!/bin/bash

set -euo pipefail

# Print errors in red
err() {
  echo -ne '\e[31m\e[1m' # Red + Bold
  echo -e "$@"
  echo -ne '\e[0m'

  exit 1
}

# Get the directory of this script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Set up the very basic stuff
DVD=${DVD:-/dev/sr0}
MOUNT=${MOUNT:-/mnt/dvd}
RIP_DIR=${RIP_DIR:-$MOUNT/VIDEO_TS}

RIP_VIDEO=${RIP_VIDEO:-true}

echo "Source:"
echo "* DVD = $DVD"
echo "* Mount dir (MOUNT) = $MOUNT"
echo "* Directory to rip from (RIP_DIR) = $RIP_DIR"

if [ -z ${LOOP+x} ]; then
  if [[ $DVD == "/dev/"* ]]; then
    LOOP=''
    echo "* Detected that you're using a real DVD device! If it should be loopback, use LOOP='-o loop'"
  else
    LOOP='-o loop'
    echo "* Detected that you're using a loopback file! If it should be a device, use LOOP=''"
  fi
fi

echo
echo "(Will attempt to create the mount dir, if needed, then mount the disc)"
echo
echo "Press <enter> to confirm..."
read

# Create the directory then mount it
sudo mkdir -p "$MOUNT"
sudo umount "$MOUNT" || true

sudo mount "$DVD" "$MOUNT" -o uid=ron $LOOP || err "Couldn't mount the DVD!"

echo
echo "Video settings (RIP_VIDEO=true / RIP_VIDEO=false to toggle)":
RIP_VIDEO=${RIP_VIDEO:-true}
if [ "$RIP_VIDEO" = "true" ]; then
  echo -e '* Rip the DVD = \e[32m\e[1mENABLED\e[0m'

  RESULT_FILE=${RESULT_FILE:-./output.txt}
  echo "* Result file (RESULT_FILE) = $RESULT_FILE"

  PRESETS_FILE=${PRESETS_FILE:-"$SCRIPT_DIR/presets.json"}
  echo "* Presets file (PRESETS_FILE) = $PRESETS_FILE"

  VIDEO_DIR=${VIDEO_DIR:-$PWD/videos}
  echo "* Video output directory: $VIDEO_DIR"

  QUALITY=${QUALITY:-19}
  echo -e "* Quality (QUALITY) = \e[34m$QUALITY\e[0m"

  CROP_TOP=${CROP_TOP:-0}
  CROP_BOTTOM=${CROP_BOTTOM:-0}
  CROP_LEFT=${CROP_LEFT:-0}
  CROP_RIGHT=${CROP_RIGHT:-0}
  echo -e "* Crop (CROP_TOP:CROP_BOTTOM:CROP_LEFT:CROP_RIGHT) = \e[34m$CROP_TOP:$CROP_BOTTOM:$CROP_LEFT:$CROP_RIGHT\e[0m"

  SPLIT_CHAPTERS=${SPLIT_CHAPTERS:-false}
  echo "* Split chapters (SPLIT_CHAPTERS) = $SPLIT_CHAPTERS"

  if [ -z ${TITLES+x} ]; then
    TITLES=$(seq -s ' ' 1 $(lsdvd "$DVD" 2>/dev/null | grep '^Title' | sed -r 's/^Title: ([0-9]*),.*/\1/' | cut -d\  -f2 | tail -n1))
  fi
  echo "* Titles (TITLES) = $TITLES"

  PREVIEW=${PREVIEW:-true}
  FRAMES=''

  echo
  echo "Preview settings (toggle with PREVIEW=true / PREVIEW=false)"
  if [ "$PREVIEW" = "true" ] ; then
    echo -e '* Preview = \e[31m\e[1mENABLED\e[0m'

    PREVIEW_START=${PREVIEW_START:-0}
    PREVIEW_END=${PREVIEW_END:-2000}
    FRAMES=" --start-at frames:$PREVIEW_START --stop-at frames:$PREVIEW_END "

    echo "* Preview frames (PREVIEW_START + PREVIEW_END) = $PREVIEW_START - $PREVIEW_END"
  fi

  if [ "$PREVIEW" = "true" && "$SPLIT_CHAPTERS" = "true" ]]; then
    err "Unfortunately, PREVIEW and SPLIT_CHAPTERS are not compatible!"
  fi
else
  echo -e '* Rip the DVD = \e[31m\e[1mDISABLED\e[0m'
fi

RIP_THUMBNAIL=${RIP_THUMBNAIL:-true}
echo
echo "Thumbnail settings (toggle with RIP_THUMBNAIL=true / RIP_THUMBNAIL=false)"
if [ "$RIP_THUMBNAIL" = "true" ]; then
  echo -e '* Rip the thumbnail = \e[32m\e[1mENABLED\e[0m'

  THUMBNAIL_DIR=${THUMBNAIL_DIR:-$PWD/thumbnails}
  THUMBNAIL_OFFSET=${THUMBNAIL_OFFSET:-3}

  echo "* Output dir (THUMBNAIL_DIR) = $THUMBNAIL_DIR"
  echo -e "* Offset in seconds (THUMBNAIL_OFFSET) = \e[34m$THUMBNAIL_OFFSET\e[0m"
else
  echo -e '* Rip the thumbnail = \e[31m\e[1mDISABLED\e[0m'
fi

echo
echo "(Press <enter> if that looks right)"
read

mkdir -p $VIDEO_DIR
mkdir -p $THUMBNAIL_DIR
rm -f "$RESULT_FILE"

for TITLE in $TITLES; do
  if [ "$SPLIT_CHAPTERS" = "true" ]; then
    CHAPTERS=$(seq -s ' ' 1 $(lsdvd "$DVD" 2>/dev/null | grep -E "^Title: 0*$TITLE," | grep -Eo 'Chapters: [0-9]*' | cut -d\  -f2))
  fi

  if [ "$SPLIT_CHAPTERS" = "true" ]; then
    for CHAPTER in $CHAPTERS; do
      VIDEO_FILE="$VIDEO_DIR/$TITLE-$CHAPTER.mp4"

      if [ "$RIP_VIDEO" = "true" ]; then
        echo "Ripping title $TITLE chapter $CHAPTER to $VIDEO_FILE..."

        flatpak run --command=HandBrakeCLI fr.handbrake.ghb \
          --json \
          --preset-import-file "$PRESETS_FILE" \
          --preset Ron \
          --quality "$QUALITY" \
          --crop-mode custom \
          --crop $CROP_TOP:$CROP_BOTTOM:$CROP_LEFT:$CROP_RIGHT \
          -i "$RIP_DIR" \
          --aencoder copy:aac \
          -t "$TITLE" \
          -c "$CHAPTER" \
          -o "$VIDEO_FILE"

        mediainfo "$VIDEO_FILE" | grep '^Bit rate   ' | head -n1 | sed "s/^/$TITLE-$CHAPTER => /" | tee -a $RESULT_FILE
      fi

      if [ "$RIP_THUMBNAIL" = "true" ]; then
        THUMBNAIL_FILE="$THUMBNAIL_DIR/$TITLE-$CHAPTER.jpg"
        echo "Creating thumbnail from $VIDEO_FILE to $THUMBNAIL_FILE @ $THUMBNAIL_OFFSET seconds"

        ffmpeg -y -ss $THUMBNAIL_OFFSET -i "$VIDEO_FILE" -frames:v 1 -q:v 2 "$THUMBNAIL_FILE"
      fi
    done
  else
    VIDEO_FILE="$VIDEO_DIR/$TITLE.mp4"

    if [ "$RIP_VIDEO" = "true" ]; then
      echo "Ripping title $TITLE to $VIDEO_FILE..."

      flatpak run --command=HandBrakeCLI fr.handbrake.ghb \
        --json \
        --preset-import-file "$PRESETS_FILE" \
        --preset Ron \
        --quality "$QUALITY" \
        $FRAMES \
        --crop-mode custom \
        --crop $CROP_TOP:$CROP_BOTTOM:$CROP_LEFT:$CROP_RIGHT \
        -i "$RIP_DIR" \
        --aencoder copy:aac \
        -t "$TITLE" \
        -o "$VIDEO_FILE" 2>/dev/null

      mediainfo "$VIDEO_FILE" | grep '^Bit rate   ' | head -n1 | sed "s/^/$TITLE => /" | tee -a $RESULT_FILE
    fi

    if [ "$RIP_THUMBNAIL" = "true" ]; then
      THUMBNAIL_FILE="$THUMBNAIL_DIR/$TITLE.jpg"
      echo "Creating thumbnail from $VIDEO_FILE to $THUMBNAIL_FILE @ $THUMBNAIL_OFFSET seconds"

      ffmpeg -y -ss $THUMBNAIL_OFFSET -i "$VIDEO_FILE" -frames:v 1 -q:v 2 "$THUMBNAIL_FILE"
    fi
  fi
done

sudo umount "$MOUNT" || true
