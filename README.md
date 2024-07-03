I wrote this scripts to help me rip educational DVDs into the cleanest possible
format. I dunno if others will find them handy, but I see these as notes to
Future Ron. If you find this useful, enjoy!

Note that at least some of the folder names I use are important for steps to
work!

## Requirements

This script assumes you have the rough set of tools that I do:

* `ffmpeg`
* `lsdvd`
* `mediainfo`
* `fr.handbrake.ghb` installed in `flatpak`

## Rip the DVD to a file

It's worthwhile ripping an ISO to a file, since I often find myself
experimenting, and my DVD reader is slow (probably they all are :) ).

To find your DVD device, use `blkid`:

```
$ blkid | grep 'udf'
/dev/sr0: UUID="32b76f7000000000" LABEL="VERNON_REVELATIONS_1_2" BLOCK_SIZE="2048" TYPE="udf"
```

I suggest working from the `working/` directory, which should be in
`.gitignore` To rip a DVD, I like to put them all into a folder called
`working/originals/`:

```
mkdir -p working/originals/
sudo dd if=/dev/sr0 of="working/originals/VERNON_REVELATIONS_1_2.iso"
```

That'll take awhile (~10 minutes for my drive). :)

## Explore the DVD

I use `lsdvd` to get titles:

```
$ lsdvd originals/Dai\ Vernon\ Revalations\ -\ Volumes\ 1+2.iso 
libdvdread: Encrypted DVD support unavailable.
libdvdread: Zero check failed in src/ifo_read.c:567 for vmgi_mat->zero_3 : 0x00000000010000000000000000000000000000
Disc Title: VERNON_REVELATIONS_1_2
Title: 01, Length: 01:52:34.500 Chapters: 36, Cells: 36, Audio streams: 01, Subpictures: 01
Title: 02, Length: 00:03:06.567 Chapters: 05, Cells: 05, Audio streams: 01, Subpictures: 01
Title: 03, Length: 00:00:00.500 Chapters: 01, Cells: 01, Audio streams: 01, Subpictures: 01
```

It seems to vary whether they use chapters or titles. Decide what you want to
rip!

## Create a preview

Still working in `working/`, run `../roncoder.sh` and start figuring out
settings! All settings are passed via environmental variables and have fairly
good defaults (I hope!):

```
Source:
* DVD = /dev/sr0
* Mount dir (MOUNT) = /mnt/dvd
* Directory to rip from (RIP_DIR) = /mnt/dvd/VIDEO_TS
* Detected that you're using a real DVD device! If it should be loopback, use LOOP='-o loop'

(Will attempt to create the mount dir, if needed, then mount the disc)

Press <enter> to confirm...
```

You will likely want to set DVD to your disk:

```
Source:
* DVD = originals/VERNON_REVELATIONS_1_2.iso
* Mount dir (MOUNT) = /mnt/dvd
* Directory to rip from (RIP_DIR) = /mnt/dvd/VIDEO_TS
* Detected that you're using a loopback file! If it should be a device, use LOOP=''

(Will attempt to create the mount dir, if needed, then mount the disc)

Press <enter> to confirm...
```

The rest of the settings should be fine, so hit enter:

```
Video settings (RIP_VIDEO=true / RIP_VIDEO=false to toggle):
* Rip the DVD = ENABLED
* Result file (RESULT_FILE) = ./output.txt
* Presets file (PRESETS_FILE) = /home/ron/projects/magic/roncoding/presets.json
* Video output directory: /home/ron/projects/magic/roncoding/working/videos
* Quality (QUALITY) = 19
* Crop (CROP_TOP:CROP_BOTTOM:CROP_LEFT:CROP_RIGHT) = 0:0:0:0
* Split chapters (SPLIT_CHAPTERS) = true
* Titles (TITLES) = 01 02 03 

Preview settings (toggle with PREVIEW=true / PREVIEW=false)
* Preview = ENABLED
* Preview frames (PREVIEW_START + PREVIEW_END) = 0 - 2000

Thumbnail settings (toggle with RIP_THUMBNAIL=true / RIP_THUMBNAIL=false)
* Rip the thumbnail = ENABLED
* Output dir (THUMBNAIL_DIR) = /home/ron/projects/magic/roncoding/working/thumbnails
* Offset in seconds (THUMBNAIL_OFFSET) = 3

(Press <enter> if that looks right)
```

By default, you'll get:

* A *preview* (first 2000 frames) of the video in the `./videos` directory
* All titles
* All chapters
* A thumbnail (@ 3seconds) in the `./thumbnails` directory
* No cropping
* Quality 19 (a decent default)
* My presets file, which I copied from a site I respect
* Output information to `./output.txt`

If you want chapters to be split, you won't be able to preview - you'll just
have to set `PREVIEW=FALSE SPLIT_CHAPTERS=true` and wait longer. Limitation of
the tools, unfortunately!

Make sure the title/chapters are correct, then go ahead and hit enter! You can
change basically everything with the environmental variables listed in the
information block.

It'll print a lot of information, and will hopefully eventually finish.

## Making it nice

Once you have the previews, open up one or more, and determine:

* Which titles + chapters you actually want to rip
* Check the edges for black or blurry and set the `CROP_*` variables accordingly
* Check the `output.txt` file - you want bitrates between roughly 1500 and 2500
* Make sure the thumbnails are correct. You may have to do a custom thumbnail
  for each video, or even generate them by hand - nothing we can do there,
  unfortunately

There's no easy way to change single files in the rip, so you want things to be
correct on-average. If there are substantially different settings required,
you'll have to run this twice settings `TITLES` accordingly.

## Ripping forreal

Once you get it all the way you want it, set `PREVIEW=false` and let 'er rip!
Be sure to check `output.txt` again, as the whole files might be different.

You'll need to make sure that the titles/chapters are in the order you want, as
well, which is kind of a pain.

## Titles

You'll have to do titles the hard way, unfortunately. Create a folder called
`titles/` and files named in the same way as `videos/` and `thumbnails/`,
except with `.txt` extensions. Put the titles in those files.

It'll look something like this:

```
$ ls *
thumbnails:
10.jpg  12.jpg  14.jpg  16.jpg  18.jpg  1.jpg   21.jpg  2.jpg  4.jpg  6.jpg  8.jpg
11.jpg  13.jpg  15.jpg  17.jpg  19.jpg  20.jpg  22.jpg  3.jpg  5.jpg  7.jpg  9.jpg

titles:
10.txt  12.txt  14.txt  16.txt  18.txt  1.txt   21.txt  2.txt  4.txt  6.txt  8.txt
11.txt  13.txt  15.txt  17.txt  19.txt  20.txt  22.txt  3.txt  5.txt  7.txt  9.txt

videos:
10.mp4  12.mp4  14.mp4  16.mp4  18.mp4  1.mp4   21.mp4  2.mp4  4.mp4  6.mp4  8.mp4
11.mp4  13.mp4  15.mp4  17.mp4  19.mp4  20.mp4  22.mp4  3.mp4  5.mp4  7.mp4  9.mp4
```

## Metadata

Copy the `metadata.nfo` file from this project into the base folder. Fill out
everything except for `NN` and `Title`, those are filled in automatically based
on the `titles/` directory.

## Finalize

Once that's all done, just run `../finalize.sh`. That should put everything
together!

## Some notes

Random thoughts:

* Ripping thumbnails without videos is fine, provided the video files are
  already ripped
