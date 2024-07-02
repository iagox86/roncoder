I wrote this scripts to help me rip educational DVDs into the cleanest possible
format. I dunno if others will find them handy, but I see these as notes to
Future Ron. If you find this useful, enjoy!

Note that at least some of the folder names I use are important for steps to
work!

## Rip the DVD to a file

It's worthwhile ripping an ISO to a file, since I often find myself
experimenting, and my DVD reader is slow (probably they all are :) ).

To find your DVD device, use `blkid`:

```
$ blkid | grep 'udf'
/dev/sr0: UUID="32b76f7000000000" LABEL="VERNON_REVELATIONS_1_2" BLOCK_SIZE="2048" TYPE="udf"
```

To rip a DVD, I like to put them all into a folder called `originals/`:

```bash
mkdir -p originals/
sudo dd if=/dev/sr0 of="originals/VERNON_REVELATIONS_1_2.iso"
```

That'll take awhile. :)

## Explore the DVD


