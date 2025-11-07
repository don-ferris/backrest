# BackRest — Pseudocode Block Diagram (Recommended Functions)

This document lists recommended functions for BackRest, with short descriptions, inputs, outputs, and two execution-flow sections:
1. Interactive Mode (all branches starting at Main Menu)
2. Headless Mode (automated run)

Use this as a design blueprint for implementing the Python script.

------------------------
I. GLOBALS / CONSTANTS
- BACKREST_DIR: path to script directory
- LOGS_CFG_DIR: /logs-cfg
- IMGSTORE_DIR: /imgstore
- HEADLESS_CFG_PATH: /logs-cfg/headless.cfg
- HEADLESS_TIMEOUT: default 30 (seconds) — configurable via settings
- DEPENDS_FILE: $BACKREST_DIR/depends.lst
- BACKREST_DRV: path of the backrest drive device (determined at runtime)
- USER: "backrest"

------------------------
II. UTILITY & SYSTEM FUNCTIONS (mode independent)

1. init_environment()
- Description: Bootstrap runtime state and validate environment (called at script start).
- Inputs: None
- Outputs: dict runtime_state (contains paths, flags, loaded settings)
- Behavior: sets up logging handlers, reads settings file, sets default values.

2. check_mounts()
- Description: Ensure IMGSTORE_DIR and LOGS_CFG_DIR are mounted & writable.
- Inputs: None
- Outputs: True on OK, False otherwise (and logs error)
- Side-effects: logs and may raise fatal exception if required mounts missing (depending on settings).

3. setup_logging()
- Description: Configure logging to /logs-cfg/lastrun.log and console.
- Inputs: None
- Outputs: logging.Logger instance
- Side-effects: ensures archive directory exists for logs.

4. archive_lastrun_log()
- Description: Copy/rotate /logs-cfg/lastrun.log -> /logs-cfg/archive/YYYYMMDD-hhmm.log
- Inputs: None
- Outputs: archive path on success

5. read_dependencies(file=DEPENDS_FILE)
- Description: Read package/tool dependency list from depends.lst
- Inputs: file path (optional)
- Outputs: list of dependency strings

6. check_dependencies(continue_on_unmet=False)
- Description: Verify dependencies are installed.
- Inputs: continue_on_unmet (bool, respects Settings)
- Outputs: (ok:bool, missing:list)
- Side-effects: logs details, aborts or returns False if missing and not allowed to continue.

7. self_test()
- Description: Run non-destructive self-test (dependency checks + small network report)
- Inputs: None
- Outputs: summary dict (dependencies_ok, net_report)
- Side-effects: prints display-ready lines like "[OK] package" and interface info.

8. find_backrest_drive()
- Description: Scan block devices to identify drive containing partitions labeled LOGS_CFG and IMGSTORE, set BACKREST_DRV.
- Inputs: None
- Outputs: path string (e.g., /dev/sdb) or None
- Side-effects: sets global BACKREST_DRV and logs result.

9. validate_restore_target(target_device)
- Description: Check target_device is not BACKREST_DRV and is writable.
- Inputs: target_device path
- Outputs: (ok:bool, reason:str)

10. confirm_user(prompt, default=False)
- Description: Generic Y/n confirmation utility that accepts single keypress.
- Inputs: prompt string, default bool
- Outputs: bool (True if confirmed)

11. keypress_menu_select(menu_items, prompt, page_size=15)
- Description: Display menu_items with single-key selection, handle pagination, Esc to cancel.
- Inputs: menu_items list of (key,label,meta) tuples, prompt, page_size
- Outputs: selected item or None if canceled
- Behavior: case-insensitive keys; spacebar for next page; returns selection.

12. read_settings()
- Description: Read persisted settings (from /logs-cfg or $BACKREST_DIR).
- Inputs: None
- Outputs: settings dict

13. write_settings(settings)
- Description: Persist given settings to disk.
- Inputs: settings dict
- Outputs: True/False

14. human_readable_size(bytes)
- Description: Convert bytes to human string (MiB, GiB).
- Inputs: int bytes
- Outputs: string

------------------------
III. NETWORKING FUNCTIONS

15. list_network_interfaces()
- Description: Return list of physical interfaces and link states.
- Inputs: None
- Outputs: list of dicts: {name, link_state, ip, ssid(if wireless)}

16. config_network_from_cfg()
- Description: If /logs-cfg/cfg/10-<hostname>.netcfg.yaml exists, apply it (or use it as template).
- Inputs: None
- Outputs: True/False (applied or not found)

17. scan_wifi_ssids()
- Description: Use nmcli to list SSIDs and signal strengths.
- Inputs: None
- Outputs: list of SSID strings (or dicts with metadata)

18. config_wifi_interactive()
- Description: Interactive WiFi configuration: show SSID menu, prompt password, attempt connect, retry/change SSID on failure.
- Inputs: None
- Outputs: connection_result dict {ok:bool, ssid, ip}

19. test_network_connectivity()
- Description: Validate IP existence and ping a known host (1.1.1.1).
- Inputs: None
- Outputs: dict {has_ip:bool, ping_ok:bool}

20. write_netcfg_for_host(hostname)
- Description: Generate 10-<hostname>.netcfg.yaml into /logs-cfg/cfg to be reused.
- Inputs: hostname
- Outputs: path to file created

------------------------
IV. DISK / INVENTORY FUNCTIONS

21. scan_disks_and_partitions()
- Description: Produce inventory of block devices and partitions with vendor/model/capacity and filesystem metadata (used/total).
- Inputs: None
- Outputs: list of disks where each disk contains list of partitions (structured dict)
- Side-effects: used by inventory and menus.

22. save_inventory(path=LOGS_CFG_DIR/inventory.txt)
- Description: Save scan_disks_and_partitions() output to inventory file
- Inputs: path optional
- Outputs: True/False (and path)

23. get_imgstore_images()
- Description: List image files in IMGSTORE_DIR sorted by date/name with metadata (size, compressed, type)
- Inputs: pagination params optionally
- Outputs: list of image dicts

24. parse_image_metadata(image_path)
- Description: Determine backup type (dd/partclone/boot), compression, and stored hashes
- Inputs: image_path
- Outputs: metadata dict

------------------------
V. BACKUP & RESTORE CORE FUNCTIONS

25. backup_boot_sector(target_device, dest_path, compress=settings)
- Description: Use dd to save first 10 MiB from target_device to dest_path; optional compression and verification.
- Inputs: target_device, dest_path, compress (bool), compressor/config
- Outputs: result dict {ok, dest_path, size, checksum}

26. backup_full_partclone(target_device, dest_path, compress, partclone_opts)
- Description: Use partclone to image raw filesystem/drive (fast) to dest_path and optionally compress.
- Inputs: target_device (partition OR whole device), dest_path, compress, partclone options
- Outputs: result dict {ok, dest_path, size, partclone_exit_code}

27. backup_full_dd_raw(target_device, dest_path, compress, dd_opts)
- Description: Use dd to copy entire device to dest_path with options, optional compression.
- Inputs: args
- Outputs: result dict

28. restore_boot_sector(image_path, target_device, decompress_ifneeded)
- Description: Restore 10 MiB boot sector image using dd; warns and requires confirmation.
- Inputs: image_path, target_device
- Outputs: result dict

29. restore_partclone(image_path, target_device, decompress_ifneeded)
- Description: Restore partclone image to device using partclone.restore; includes warnings and verification options.
- Inputs: image_path, target_device
- Outputs: result dict

30. restore_dd_raw(image_path, target_device, decompress_ifneeded)
- Description: Restore raw dd image to device.
- Inputs: image_path, target_device
- Outputs: result dict

31. run_verification(image_path, verification_options)
- Description: Run the configured verification steps: zstd test, checksum, decompress-then-hash, loopback restore & fsck, partclone-specific checks.
- Inputs: image_path, verification_options dict
- Outputs: verification_report dict

32. decompress_if_needed(image_path, work_dir)
- Description: If image is compressed, decompress to work_dir (or stream).
- Inputs: image_path, work_dir
- Outputs: path to usable data (may stream or temp file)

33. create_dest_filename(prefix, source_device, backup_type, timestamp, compressor)
- Description: Build a deterministic destination filename used for images.
- Inputs: prefix, device, type, timestamp, compressor
- Outputs: filename string

------------------------
VI. UI / INTERACTIVE FUNCTIONS

34. main_menu()
- Description: The top-level interactive menu with keys [B] Backup, [R] Restore, [S] Settings, [X] Exit/shutdown. Starts HEADLESS_TIMEOUT timer for headless mode.
- Inputs: None
- Outputs: None (drives program flow)

35. drive_partition_menu(action)  # action is 'backup' or 'restore' or 'info'
- Description: Display disks and partitions (scan_disks_and_partitions), allow selection or Esc to return.
- Inputs: action string to control which options to enable (e.g., boot sector only shown for a whole-disk selection)
- Outputs: selected device or partition dict or None

36. backup_menu_for_selection(device_dict)
- Description: Offer [B] Boot sector, [P] Full drive (Partclone), [R] Full drive raw (dd). Only show boot option for whole-disk devices.
- Inputs: device_dict
- Outputs: selected backup type and parameters

37. confirm_and_run_backup(selected_device, backup_type, options)
- Description: Wrapper that validates target, builds dest filename, prompts user for confirmation, calls appropriate backup_* function, and then optionally runs verification and post-actions (sound/shutdown).
- Inputs: selected_device, backup_type, options dict
- Outputs: final result dict

38. images_menu()
- Description: Show paginated list of images from IMGSTORE_DIR with selection keys. Supports previewing metadata, deleting (with confirmation), and selecting for restore.
- Inputs: None (or pagination options)
- Outputs: selected image metadata or None

39. restore_menu_for_image(image_meta)
- Description: Offer restore options matching backup menu: [B] boot sector, [P] partclone, [R] raw dd (as suitable).
- Inputs: image_meta
- Outputs: selected restore action

40. confirm_and_run_restore(image_meta, target_device, restore_type, options)
- Description: Validate that target_device != BACKREST_DRV, prompt user repeatedly for confirmation, and call appropriate restore_* function. Support dry-run preview.
- Inputs: image_meta, target_device, restore_type, options
- Outputs: result dict

41. settings_menu()
- Description: Interactive settings editor (Backup Compression, Verify On Completion, System options). Allows toggling values and saving via write_settings.
- Inputs: None
- Outputs: new settings dict

42. shutdown_sequence(reason)
- Description: Optionally play sound, flush logs, archive logs, and initiate system shutdown if configured or requested.
- Inputs: reason string
- Outputs: None

43. display_message(message, duration=None)
- Description: Generic UI message, supports single-key acknowledgment and timed display.
- Inputs: message, optional duration
- Outputs: None

------------------------
VII. HEADLESS / AUTOMATION FUNCTIONS

44. headless_entrypoint(timeout=HEADLESS_TIMEOUT)
- Description: Called by main_menu() to wait for HEADLESS_TIMEOUT; if no keypress, transition to headless_run().
- Inputs: timeout seconds
- Outputs: None

45. headless_run(cfg_path=HEADLESS_CFG_PATH)
- Description: Main headless execution: read config, perform sequence of actions (get_info, backup, restore) according to config, log results and delete headless.cfg when complete (for safety).
- Inputs: cfg_path
- Outputs: summary dict of actions taken, return_code

46. read_headless_cfg(cfg_path)
- Description: Parse headless.cfg into a structured dict. If not found, log error and return None.
- Inputs: cfg_path
- Outputs: config dict or None

47. headless_get_info(save_path=LOGS_CFG_DIR/inventory.txt)
- Description: On-boot inventory collection (calls scan_disks_and_partitions and save_inventory).
- Inputs: save_path
- Outputs: path saved

48. headless_backup_sequence(cfg, settings)
- Description: Evaluate cfg to determine which devices to backup and how; call backup functions for each; support retries and error handling.
- Inputs: cfg dict, settings dict
- Outputs: list of backup result dicts

49. headless_restore_sequence(cfg, settings)
- Description: Evaluate cfg to determine which images to restore and to which devices; validate and run restores.
- Inputs: cfg, settings
- Outputs: list of restore result dicts

50. cleanup_headless(cfg_path)
- Description: Delete headless.cfg file and optionally any temporary files; log action.
- Inputs: cfg_path
- Outputs: True/False

------------------------
VIII. HELPERS & SAFETY

51. require_root_or_user(user="backrest")
- Description: Ensure the script is executed as the backrest user (or root). If not, attempt to escalate or bail.
- Inputs: user string
- Outputs: True/False

52. confirm_not_backrest_imgstore_target(target_device)
- Description: Ensure that target_device is not BACKREST_DRV; central safety check invoked before any restore operation.
- Inputs: target_device
- Outputs: True/False with message

53. handle_signals_and_cleanup()
- Description: Install signal handlers (SIGINT, SIGTERM) to gracefully stop operations and archive logs.
- Inputs: None
- Outputs: None

------------------------
IX. IMPLEMENTATION NOTES & Data Structures

- Device dict example:
  { "dev": "/dev/sda", "type":"disk", "vendor":"XYZ", "model":"ABC", "size_bytes":..., "partitions":[ { "dev":"/dev/sda1", "fs":"ext4", "mount":"/", "label":"ROOT", "used":..., "size_bytes":... } ] }

- Image metadata example:
  { "path": "/imgstore/20251104-sda-partclone.img.zst", "type":"partclone", "compressed":True, "compressor":"zstd", "timestamp":"2025-11-04T...", "size":..., "hash":"sha256:..." }

------------------------
X. INTERACTIVE MODE — Function Call Flow (All Branches from main_menu)
Below is the full interactive sequence with function calls as the user navigates the UI. The flow assumes main() invoked and environment initialized.

1) Startup
- main() calls:
  - require_root_or_user("backrest")
  - init_environment()
  - setup_logging()
  - check_mounts() -> if False: display_message("Missing mount...") and abort
  - read_settings()
  - find_backrest_drive() -> sets BACKREST_DRV
  - check_dependencies(continue_on_unmet=settings["continue_on_unmet_dependency"]) OR if settings["run_self_test_on_launch"]: self_test()
  - handle_signals_and_cleanup()
  - Enter main_menu()

2) main_menu()
- Display options: [B] Backup, [R] Restore, [S] Settings, [X] Exit (also start HEADLESS timer)
- Start headless_entrypoint(timeout=settings["headless_timeout"]) in parallel (or as a timer that triggers if no keypress)
- Wait for single-key selection

Branch A: User presses [B] Backup
  - main_menu() calls drive_partition_menu(action='backup')
    - drive_partition_menu -> calls scan_disks_and_partitions() to build list
    - menu selection using keypress_menu_select()
    - If user presses Esc -> return to main_menu()
    - If user selects a disk or partition -> returns selected_device
  - If selected_device is None -> return to main_menu()
  - main_menu() calls backup_menu_for_selection(selected_device)
    - If selected_device is whole-disk -> show [B] Boot Sector, [P] Partclone Full, [R] Raw dd
    - If partition -> hide Boot Sector option -> show [P] [R]
    - keypress menu selection returns backup_type
  - main_menu() calls confirm_and_run_backup(selected_device, backup_type, options)
    - confirm_and_run_backup:
      - build dest filename via create_dest_filename(...)
      - display summary and require confirm_user()
      - check check_dependencies() again if needed
      - call validate target (for boot sector or full backups there is no BACKREST_DRV restriction) -> proceed
      - call appropriate backup_*:
        - backup_boot_sector() OR backup_full_partclone() OR backup_full_dd_raw()
      - If settings["verify_on_completion"] -> run_verification(image_path, settings["verification_options"])
      - If settings["play_sound_on_completion"] -> play sound
      - If settings["shutdown_on_completion"] -> shutdown_sequence("backup complete")
      - archive_lastrun_log()
      - return to main_menu()
  - Any errors -> display_message() and return to backup_menu or main_menu based on error handling.

Branch B: User presses [R] Restore
  - main_menu() calls images_menu()
    - images_menu -> calls get_imgstore_images()
    - paginated UI via keypress_menu_select()
    - Allow preview of parse_image_metadata(image_path) for chosen image
    - If no images -> display_message("No images found") and return to main_menu()
    - After selecting image -> image_meta returned
  - main_menu() calls drive_partition_menu(action='restore')
    - Let user select target device/partition for restore
    - User can Esc to cancel and return to images_menu or main_menu
  - main_menu() calls confirm_and_run_restore(image_meta, target_device, restore_type, options)
    - confirm_and_run_restore:
      - validate target_device: require validate_restore_target() and confirm_not_backrest_imgstore_target()
      - If target_device == BACKREST_DRV -> display_message("Restore to BACKREST drive is disallowed") -> abort and return
      - present restore type options based on image_meta (boot vs partclone vs raw)
      - require multiple confirmations and detailed warning (use confirm_user)
      - call appropriate restore_* function:
        - restore_boot_sector(), restore_partclone(), restore_dd_raw()
      - If verification settings require post-restore actions -> run_verification or run filesystem checks (fsck/mount)
      - If settings["play_sound_on_completion"] -> play sound
      - If settings["shutdown_on_completion"] -> shutdown_sequence("restore complete")
      - archive_lastrun_log()
      - return to main_menu()
  - Error handling: on failure, display_message and offer retry or return to main_menu.

Branch C: User presses [S] Settings
  - main_menu() calls settings_menu()
    - settings_menu loads settings via read_settings()
    - interactive toggles for:
      - compression on/off, compressor choice, compression level
      - verify on completion options
      - run_self_test_on_launch toggle
      - continue_on_unmet_dependency
      - continue_without_network
      - headless_timeout
      - play_sound_on_completion
      - shutdown_on_completion
    - When user saves -> write_settings(new_settings), display success, return to main_menu()

Branch D: User presses [X] Exit
  - main_menu() calls shutdown_sequence("user exit") which:
    - flushes logs, archive_lastrun_log()
    - optionally shutdown system (or just exit)

Branch E: User presses Esc in main_menu()
  - treat as Exit or return to console; call shutdown_sequence("cancelled") or simply exit.

Notes about sub-branches and pagination:
- images_menu supports pagination: if there are more images than page_size, spacebar shows next page; selection keys map to list index on current page.
- drive_partition_menu when selecting a disk offers drill-down: if user selects disk entry it may show contained partitions (or allow selecting the disk itself).
- wifi/network configuration can be triggered during backup/restore if network required (e.g., uploading images) by calling config_network_from_cfg() and if needed config_wifi_interactive().

------------------------
XI. HEADLESS MODE — Function Call Flow

Headless mode is triggered automatically by headless_entrypoint() when no key pressed within HEADLESS_TIMEOUT from main_menu().

1) Entry
- headless_entrypoint(timeout) -> after timeout, call headless_run(cfg_path=HEADLESS_CFG_PATH)

2) headless_run(cfg_path)
- call setup_logging() (already set) and log "Beginning headless run"
- call read_headless_cfg(cfg_path)
  - If headless.cfg not found:
    - log error "headless.cfg not found. Aborting headless operation."
    - archive_lastrun_log()
    - exit headless_run with error code
- parse config into dict: cfg contains actions: get_info, backups[], restores[], network options, retry counts, schedules, verification prefs.
- call find_backrest_drive() to set BACKREST_DRV (safety)
- Perform optional network setup:
  - If cfg requests network or if backups need remote upload:
    - call config_network_from_cfg() -> if not present and wireless detected -> call config_wifi_interactive() OR if config disallows wifi, skip
    - call test_network_connectivity() and act according to settings["continue_without_network"]
- Actions (in this order, configurable via cfg):
  A) headless_get_info(save_path=cfg.get(...))
    - calls scan_disks_and_partitions()
    - calls save_inventory()
  B) headless_backup_sequence(cfg, settings)
    - For each target defined in cfg:
      - validate device exists via scan_disks_and_partitions()
      - for each backup item:
        - create dest filename create_dest_filename()
        - call backup_boot_sector() OR backup_full_partclone() OR backup_full_dd_raw()
        - if configured, call run_verification()
        - if configured to upload, perform upload (future)
    - Log results and accumulate result list
  C) headless_restore_sequence(cfg, settings)
    - For each restore entry in cfg:
      - locate image by path or pattern in IMGSTORE_DIR using get_imgstore_images()
      - parse_image_metadata() for correct restore method
      - validate target is not BACKREST_DRV by confirm_not_backrest_imgstore_target()
      - call restore_* appropriate function
      - optionally verify after restore
- After all actions:
  - cleanup_headless(cfg_path) -> delete headless.cfg (critically required)
  - archive_lastrun_log()
  - Optionally shutdown if cfg/settings request it
  - Return summary and exit.

Failure & Safety handling:
- If any step fails, record error into lastrun.log, and follow cfg["on_error"] policy (abort, continue, retry).
- If headless.cfg is missing -> abort with logged message.
- Always delete headless.cfg at the end (successful or failed) unless cfg explicitly sets preservation (but default is delete).
- Never restore to BACKREST_DRV (function confirm_not_backrest_imgstore_target() prevents this).

------------------------
XII. Example Calls — Short Traces

Example interactive backup of /dev/sdb1 as partclone:
- main() -> main_menu() -> user presses B
- -> drive_partition_menu('backup') -> scan_disks_and_partitions() -> select /dev/sdb1
- -> backup_menu_for_selection(dev) -> user selects P
- -> confirm_and_run_backup(dev,'partclone',options) ->
    create_dest_filename(...)
    confirm_user("Proceed?")
    backup_full_partclone(dev, dest, compress=True)
    run_verification(dest, verification_options)
    archive_lastrun_log()
    return to main_menu()

Example headless backup defined in headless.cfg:
- boot -> headless_entrypoint() -> headless_run()
- read_headless_cfg() -> cfg indicates get_info + backups for /dev/sda
- headless_get_info() -> scan_disks_and_partitions() -> save_inventory()
- headless_backup_sequence() -> for /dev/sda:
    create_dest_filename(...)
    backup_full_partclone('/dev/sda', dest, compress=True)
    run_verification(dest, cfg verification options)
- cleanup_headless() -> delete headless.cfg
- archive_lastrun_log() -> optional shutdown

------------------------
XIII. Final Remarks / Implementation Priorities

Top-priority functions to implement first:
1. init_environment(), setup_logging(), check_mounts()
2. scan_disks_and_partitions(), find_backrest_drive(), save_inventory()
3. get_imgstore_images(), parse_image_metadata()
4. backup_full_partclone(), backup_boot_sector(), restore_partclone(), restore_boot_sector()
5. headless_run(), read_headless_cfg(), cleanup_headless()
6. check_dependencies(), self_test()
7. main_menu(), drive_partition_menu(), images_menu(), confirm_and_run_{backup,restore}()

Security & safety:
- Thorough input validation on device paths.
- Confirmations before destructive operations.
- Prevent restoring to BACKREST_DRV.
- Delete headless.cfg after run.

This pseudocode block diagram should serve as a comprehensive blueprint for breaking the task into functions and implementing the interactive and headless flows. Implement in small increments and unit-test each disk/network operation with mocks where possible.
