# BackRest — Release Notes (v1.0)

Release: v1.0  
Created: 2025-10-24

## Overview
BackRest v1.0 is the initial implementation of a backup/restore tool on one fully self-contained external SSD. The bootable OS (Ubuntu Server 22.04), backrest.sh script and all dependencies live within a small 10GB partition. The remaining space on the disk is configured as /imgstore - a large partition for storing backup images. On boot-up, the system configures networking (in case internet access is required for anything), logs in as user backrest (root), runs and displays the results of a self-test, then displays the BackRest main menu. 

This document summarizes the features and functionality implemented in v1.0.

## Primary goals
- Make it easy to create and restore images of local drives/partitions without memorizing long dd/partclone command lines.
- Reduce risk of accidental device overwrite by restricting writes to a controlled image directory.
- Provide basic progress/feedback to the user and a simple, keyboard-driven menu interface.

## Key features (v1.0)

- Interactive TTY-based menu
  - A compact, single-screen text menu prompts the operator for high-level actions (Backup / Restore).
  - Menu navigation uses one-key selectors (single-character keys) to pick drives/partitions and image files.

- Device and partition discovery
  - Detects local block devices and partitions and lists them for operator selection.
  - Presents each detected item with a concise label (device name, basic model, and size) so the user can choose the correct source/target.

- Backup modes
  - Boot-sector backup:
    - Captures the boot sector (bootloader + partition table area) to a small image file (boot-sector capture sized to include partition table and bootloader).
    - Intended for quick capture of boot metadata (useful for very fast recovery scenarios).
  - Full-device raw image (dd):
    - Creates a complete raw image of a whole disk device using dd, writing to an image file in the image store.
    - Suitable for full-drive clones; will copy all bytes, including unused space.
  - Partition-by-partition images:
    - Provides the operator the ability to image partitions individually. (In v1.0 the front-end orchestrates imaging; the implementation uses low-level tools.)
  - Filename and destination safety:
    - Operator provides a descriptive filename base for each backup.
    - All images are written into the fixed image store directory ("/imgstore") on the same drive; the script enforces that destination resolution stays inside the image store directory to prevent accidental device writes.

- Restore modes
  - Restore an image file to a selected block device or partition.
  - The restore flow lists available image files in the image store to pick the source image, then lists available block devices as targets for the restore.
  - The script prompts for explicit confirmation before overwriting a target device.

- Atomic/tempfile write behavior
  - Writes are performed to temporary files inside an image store subdir (usually a .tmp location) and atomically moved into place once the write completes successfully. This reduces risk of partial images being mistaken for valid images.

- Progress reporting
  - Backup and restore operations display a progress indicator and ETA to give the operator feedback during long-running operations.
  - When available, pipe progress tools are used to estimate throughput and time remaining.

- Audible notification
  - A short notification bell (audible) is played when backup or restore operations complete so the operator is alerted even if not watching the screen.

- Minimal environmental assumptions
  - v1.0 is written to work with standard low-level tools available on common Linux systems (e.g., dd).
  - The script checks for and attempts to use progress helpers where present.

- Safety and explicit confirmations
  - Critical operations that overwrite devices require explicit confirmation via interactive prompts.
  - The UI emphasizes single-key, obvious selections and prompts the operator before destructive actions.

- Logging
  - Per-operation logs are written (timestamped) for audit and troubleshooting. Logs are stored under the BackRest directory tree (under `/root/backrest/logs` by convention in later revisions).
  - Log behavior in v1.0 captures the essential stdout/stderr for operations to help diagnose failed backups/restores.

## Intended usage
- Run the script on a real TTY (the script is interactive and expects a terminal).
- Use Backup to capture images (choose disk or partition and select the appropriate backup mode).
- Use Restore to write an image back to a device; confirm carefully before proceeding.
- Images are stored under `/imgstore` on the same drive — ensure that directory exists and has sufficient free space before starting big operations.

## File locations (v1.0 expectations)
- Image store directory: `/imgstore` (primary image storage location)
- Script: single-file script distributed to a system location (e.g., `/usr/local/sbin/backrest.sh`)
- Logs: a BackRest directory is created under the operator's root-area to store logs; specific log paths may vary in later revisions.

## Limitations and notes (v1.0)
- v1.0 is an initial implementation focusing on core functionality. It does not include advanced dependency bootstrapping, a comprehensive settings menu, or detailed manifests — those features are introduced in later revisions.
- The script assumes root privileges for device access and for operations such as dd and writes to system locations.
- Imaging operations copy device data; an operator should ensure the selected target and source are correct to avoid data loss.
- Progress accuracy depends on the availability of helper utilities (pv, etc.). If not present, dd will run without a more granular progress display.

## Troubleshooting hints (v1.0)
- Ensure `/imgstore` exists and is writable by the script (run as root).
- If the script cannot list devices or partitions, confirm lsblk and related utilities exist on the system.
- If operations fail, inspect per-operation logs (present under the BackRest script's log directory) for the tool output used by dd or other imaging utilities.

## Summary
v1.0 provides a pragmatic, interactive wrapper for low-level imaging tools, offering:
- discovery and selection of disks/partitions,
- controlled image storage to `/imgstore`,
- options to capture boot sectors, raw device images, or per-partition images,
- progress feedback and audible completion notification,
- atomic writes and per-operation logs to aid safety and troubleshooting.

This is the foundational release on which subsequent improvements (menu refinements, dependency management, settings, and self-test features) are built.
