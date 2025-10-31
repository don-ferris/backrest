# backrest
Fully self-contained, interactive backup/restore disk (front-end for partclone + dd).
Boots directly into script's main menu.
Backs up to/restores from /imgstore on same disk
System (OS, all dependencies, and backup restore script, backrest.sh) lives in 10 GB partition, leaving the remainder of the disk for backup images.
Options for backing up:
 - full disk (dd - including free space)
 - full disk (partclone - partition by partition, excluding free space)
 - boot sector (dd - first 10 MiB of disk)
Backup images automatically compressed to save space on /imgstore
