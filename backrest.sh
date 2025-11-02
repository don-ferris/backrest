#!/usr/bin/env bash
: <<'SCRIPT_HEADER'
backrest.sh
BackRest - interactive backup/restore tool (front-end for partclone + dd). Fully self-contained on bootable drive - backs up to/restores from /imgstore on same drive.
──────────────────────────────────────────────────────
Author: Don Ferris
Created: 2025-10-28
Current Revision: 2.0
──────────────────────────────────────────────────────
Revision History
================
v2.0 — 2025-10-29 — Switched partition/volume backups to partclone (copies used blocks only) and reserve dd for boot-sector backups only; boot-sector capture size increased to 10MiB to reliably include bootloader and partition table data; auto-install BackRest dependencies non‑interactively (zstd as default compressor); enforce backups write only to image files under /imgstore (no chance of calalmtious device overwrites).
v1.2 — 2025-10-24 — Added logging
v1.1 — 2025-10-24 — Menu refinements (better display of disk/partition information to make sure the right disk/partition is chosen).
v1.0 — 2025-10-24 — Initial implementation: A front-end for dd, BackRest displays a list of drives/partitions (for backup) or image files (for restore) as a menu with one-key menu item selectors. With the option to backup boot sectors only, BackRest backs up to/restores from "/imgstore" directory on same drive. Shows progress bar and ETA for backup/restore operations. Plays notification bel when ops complete.
──────────────────────────────────────────────────────
Github Copilot Development Conversations: 
https://github.com/copilot/c/f3b19939-b86e-4dba-826e-136ddf14d15e
https://github.com/copilot/c/43e6255b-db29-4c3b-a638-7dcd705bec53

# END OF
SCRIPT_HEADER

set -eu -o pipefail

# --------------------------
# Configuration / constants
# --------------------------
IMGSTORE="/imgstore"
BACKREST_DIR="/root/backrest"
LOGDIR="$BACKREST_DIR/logs"
TMPDIR="$IMGSTORE/.tmp"
SCRIPTPATH="$(realpath "${BASH_SOURCE[0]:-$0}")"
SCRIPTNAME="$(basename "$SCRIPTPATH")"

BACKREST_AUTO_INSTALL=true
ZSTD_CMD="zstd -T0 -6 -c"
ZSTD_DECOMP="zstd -d -c"

BOOT_SECTOR_BYTES=$((10 * 1024 * 1024))
BOOT_SECTOR_BLOCKS=$((BOOT_SECTOR_BYTES / 512))

MIN_SPACE_BYTES=$((4 * 1024 * 1024 * 1024))
MIN_SPACE_FOR_ZFS=$((8 * 1024 * 1024 * 1024))
MANIFEST_TTL_DAYS=365

mkdir -p "$BACKREST_DIR" "$LOGDIR" "$TMPDIR" 2>/dev/null || true

# --------------------------
# Logging / helpers
# --------------------------
LOGPATH=""
log_append() {
  ts="$(date -Is)"
  msg="$ts - $*"
  echo "$msg"
  [ -n "$LOGPATH" ] && printf "%s\n" "$msg" >>"$LOGPATH"
}

press_any_key() {
  echo
  echo -n "Press any key to continue..."
  read -rsn1 -t 3600 _ || true
  echo
}

json_quote() {
  s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "\"$s\""
}

humanize_bytes_round() {
  num="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B --format="%.0f" "$num"
  else
    awk -v b="$num" 'function human(x){
      s="B KMGTPE"; i=1;
      while(x>=1024 && i<6){x/=1024; i++}
      return sprintf("%.0f%s",x,substr(s,i,1) "B")
    } {print human(b)}'
  fi
}

get_size_bytes() {
  dev="$1"
  blockdev --getsize64 "$dev" 2>/dev/null || echo 0
}

cmd_exists() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 && return 0
  done
  return 1
}

play_bell_three() {
  for i in 1 2 3; do
    printf '\a'
    sleep 0.12
  done
}

# --------------------------
# Destination validation
# --------------------------
validate_and_prepare_dest() {
  user_fname="$1"
  if [ -z "$user_fname" ]; then printf "Invalid filename\n"; return 1; fi
  if printf "%s" "$user_fname" | grep -q '[/:]' ; then printf "Invalid filename (contains path separators)\n"; return 1; fi
  dest="$IMGSTORE/$user_fname"
  target_dir="$(realpath -m "$IMGSTORE")"
  dest_real="$(realpath -m "$dest")"
  case "$dest_real" in "$target_dir"/*) ;; *) printf "Destination resolves outside $IMGSTORE\n"; return 1 ;; esac
  if [ -b "$dest_real" ]; then printf "Destination would be a block device (refusing)\n"; return 1; fi
  mkdir -p "$TMPDIR"
  tmpname="$(printf "%s.tmp.%s.%s" "$user_fname" "$$" "$(date +%s)")"
  tmpfull="$TMPDIR/$tmpname"
  printf "%s" "$tmpfull"
  return 0
}

# --------------------------
# Networking helpers
# --------------------------
backup_netplan_files() {
  bakdir="/etc/netplan/netplan_bak-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$bakdir"
  for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do [ -e "$f" ] || continue; mv "$f" "$bakdir/"; done
  log_append "Moved existing netplan files to $bakdir"
}

choose_physical_if() {
  while IFS= read -r ifname; do
    case "$ifname" in lo|docker*|veth*|virbr*|br-*|tun*|tap*|wg*|vmnet*|vboxnet*) continue ;; esac
    if [ -f "/sys/class/net/$ifname/carrier" ]; then
      carrier=$(cat "/sys/class/net/$ifname/carrier" 2>/dev/null || echo 0)
      [ "$carrier" = "1" ] && { printf "%s" "$ifname"; return 0; }
    fi
  done < <(ip -o link show | awk -F': ' '{print $2}')
  while IFS= read -r ifname; do
    case "$ifname" in lo|docker*|veth*|virbr*|br-*|tun*|tap*|wg*|vmnet*|vboxnet*) continue ;; esac
    printf "%s" "$ifname"; return 0
  done < <(ip -o link show | awk -F': ' '{print $2}')
  return 1
}

test_network_connectivity() {
  if cmd_exists ping; then ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && return 0 || return 1; else ip route show default >/dev/null 2>&1 && return 0 || return 1; fi
}

setup_netplan() {
  ensure_log="$LOGDIR/ensure-deps.log"
  LOGPATH="$ensure_log"
  ifname="$(choose_physical_if || true)"
  if [ -z "$ifname" ]; then log_append "No suitable physical interface detected"; LOGPATH=""; return 1; fi
  log_append "Selected interface $ifname for DHCP netplan"
  backup_netplan_files
  cfg="/etc/netplan/01-netcfg.yaml"
  cat >"$cfg" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $ifname:
      dhcp4: true
EOF
  chmod 600 "$cfg" || log_append "Warning: chmod 600 $cfg failed"
  log_append "Wrote and chmod'd $cfg (600)"
  if ! cmd_exists netplan; then log_append "netplan not installed"; LOGPATH=""; return 1; fi
  if netplan apply >>"$ensure_log" 2>&1; then log_append "netplan apply succeeded"; else log_append "netplan apply failed (see $ensure_log)"; journalctl -n 50 -u systemd-networkd >>"$ensure_log" 2>&1 || true; LOGPATH=""; return 1; fi
  test_network_connectivity && { log_append "Network connectivity verified"; LOGPATH=""; return 0; } || { log_append "Network connectivity not established"; LOGPATH=""; return 1; }
}

# --------------------------
# Package install and manifest
# --------------------------
install_packages() {
  pkgs=("$@")
  log_append "install_packages: apt-get install -y ${pkgs[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >>"$LOGDIR/ensure-deps.log" 2>&1 || log_append "apt-get update had warnings/errors"
  if ! apt-get install -y "${pkgs[@]}" >>"$LOGDIR/ensure-deps.log" 2>&1; then log_append "apt-get install failed for: ${pkgs[*]}"; return 1; fi
  log_append "install_packages: succeeded for: ${pkgs[*]}"
  return 0
}

_generate_manifest_after_install() {
  pkgs=("$@")
  manifest="$BACKREST_DIR/manifest.json"
  tmp="$BACKREST_DIR/_pkglist.$$"
  : >"$tmp"
  for p in "${pkgs[@]}"; do
    ver="$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || true)"
    [ -z "$ver" ] && ver="(not-installed)"
    printf "%s\t%s\n" "$p" "$ver" >>"$tmp"
  done
  sorted="$BACKREST_DIR/_pkglist_sorted.$$"
  sort "$tmp" >"$sorted" || cp "$tmp" "$sorted"
  packages_hash="$(sha256sum "$sorted" 2>/dev/null | awk '{print $1}' || echo "")"

  binaries_verified=()
  for b in partclone partclone.restore partclone.ext4 partclone.xfs partclone.ntfs partclone.fat pv zstd parted e2image mkfs.xfs ntfsclone dosfslabel lvcreate rsync btrfs dkms gcc make zfs zpool; do
    command -v "$b" >/dev/null 2>&1 && binaries_verified+=("$b")
  done

  script_sha="$(sha256sum "$SCRIPTPATH" 2>/dev/null | awk '{print $1}' || true)"
  free_bytes="$(df --output=avail -B1 / | awk 'NR==2{print $1}' 2>/dev/null || echo 0)"
  apt_snapshot="$BACKREST_DIR/apt-sources.tar.gz"
  (tar -czf "$apt_snapshot" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)

  {
    echo "{"
    echo "  \"manifest_version\": 1,"
    echo "  \"status\": \"ok\","
    echo "  \"timestamp\": \"$(date -Is)\","
    echo "  \"backrest_revision\": \"2.0\","
    echo "  \"runner_uname\": $(json_quote "$(uname -a)"),"
    echo "  \"kernel_for_dkms\": $(json_quote "$(uname -r)"),"
    echo "  \"free_space_at_install\": ${free_bytes},"
    echo "  \"packages_hash\": $(json_quote "${packages_hash}"),"
    echo "  \"packages\": ["
  } >"$manifest"

  first=true
  while IFS=$'\t' read -r name ver; do
    if ! $first; then echo "," >>"$manifest"; fi
    first=false
    name_q="$(printf '%s' "$name" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    ver_q="$(printf '%s' "$ver" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    printf '    {"name":"%s","version":"%s"}' "$name_q" "$ver_q" >>"$manifest"
  done <"$sorted"

  {
    echo ""
    echo "  ],"
    echo -n "  \"binaries_verified\": ["
  } >>"$manifest"

  bfirst=true
  for b in "${binaries_verified[@]}"; do
    if ! $bfirst; then echo -n ", " >>"$manifest"; fi
    bq="$(printf '%s' "$b" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    echo -n "\"$bq\"" >>"$manifest"
    bfirst=false
  done

  {
    echo "],"
    echo "  \"zfs_dkms_build\": { \"attempted\": false, \"success\": false },"
    echo "  \"ensure_log\": \"${LOGDIR}/ensure-deps.log\","
    echo "  \"apt_sources_snapshot\": \"${apt_snapshot}\","
    echo "  \"script_sha256\": \"${script_sha}\","
    echo "  \"marker_expires_days\": ${MANIFEST_TTL_DAYS}"
    echo "}"
  } >>"$manifest"

  rm -f "$tmp" "$sorted" 2>/dev/null || true
  log_append "Wrote detailed manifest to $manifest"
}

ensure_backrest_depends() {
  LOGPATH="$LOGDIR/ensure-deps.log"
  log_append "Starting ensure_backrest_deps (auto_install=$BACKREST_AUTO_INSTALL)"

  avail_bytes=$(df --output=avail -B1 / | awk 'NR==2{print $1}')
  log_append "Available bytes on root: $avail_bytes ($(humanize_bytes_round "$avail_bytes"))"
  [ -z "$avail_bytes" ] || [ "$avail_bytes" -lt "$MIN_SPACE_BYTES" ] && { log_append "ERROR: Not enough free space"; LOGPATH=""; return 1; }

  declare -A pkg_cmds
  pkg_cmds[pv]="pv"
  pkg_cmds[zstd]="zstd"
  pkg_cmds[parted]="parted"
  pkg_cmds[partclone]="partclone partclone.restore partclone.ext4 partclone.xfs partclone.ntfs partclone.fat"
  pkg_cmds[e2fsprogs]="e2image"
  pkg_cmds[xfsprogs]="mkfs.xfs xfs_info"
  pkg_cmds[ntfs-3g]="ntfsclone"
  pkg_cmds[dosfstools]="dosfslabel"
  pkg_cmds[lvm2]="lvcreate"
  pkg_cmds[rsync]="rsync"
  pkg_cmds[btrfs-progs]="btrfs"
  pkg_cmds[dkms]="dkms"
  pkg_cmds[build-essential]="gcc make"
  pkg_cmds[linux-headers-generic]="uname"
  pkg_cmds[zfsutils-linux]="zfs"
  pkg_cmds[zfs-dkms]="zfs"

  pkg_list=(pv zstd parted partclone e2fsprogs xfsprogs ntfs-3g dosfstools lvm2 rsync btrfs-progs dkms build-essential linux-headers-generic)
  zfs_pkgs=(zfsutils-linux zfs-dkms)
  use_zfs=true
  [ "$avail_bytes" -lt "$MIN_SPACE_FOR_ZFS" ] && { log_append "Low space; skipping zfs packages"; use_zfs=false; }
  $use_zfs && pkg_list+=("${zfs_pkgs[@]}")

  install_candidates=()
  for pkg in "${pkg_list[@]}"; do
    cmds="${pkg_cmds[$pkg]:-$pkg}"
    found=false
    for c in $cmds; do command -v "$c" >/dev/null 2>&1 && { found=true; break; }; done
    $found || install_candidates+=("$pkg")
  done

  if [ "${#install_candidates[@]}" -eq 0 ]; then log_append "All required packages already present."; _generate_manifest_after_install "${pkg_list[@]}"; LOGPATH=""; return 0; fi

  if [ "$BACKREST_AUTO_INSTALL" != "true" ]; then log_append "Auto install disabled"; LOGPATH=""; return 1; fi
  command -v apt-get >/dev/null 2>&1 || { log_append "apt-get unavailable"; LOGPATH=""; return 1; }
  install_packages "${install_candidates[@]}" || { log_append "install failed"; LOGPATH=""; return 1; }

  still_missing=()
  for pkg in "${install_candidates[@]}"; do
    cmds="${pkg_cmds[$pkg]:-$pkg}"; present=false
    for c in $cmds; do command -v "$c" >/dev/null 2>&1 && { present=true; break; }; done
    $present || still_missing+=("$pkg")
  done
  [ "${#still_missing[@]}" -ne 0 ] && { log_append "After install, still missing: ${still_missing[*]}"; LOGPATH=""; return 1; }

  $use_zfs && command -v modprobe >/dev/null 2>&1 && command -v zpool >/dev/null 2>&1 2>/dev/null && { modprobe zfs >/dev/null 2>&1 && log_append "zfs loaded" || log_append "zfs load failed"; }

  _generate_manifest_after_install "${pkg_list[@]}"
  record_deps_manifest "ok"
  LOGPATH=""
  return 0
}

record_deps_manifest() {
  status="$1"
  manifest="$BACKREST_DIR/manifest.json"
  [ -f "$manifest" ] && { log_append "Manifest present at $manifest"; return 0; }
  cat >"$manifest" <<EOF
{
  "status": "$status",
  "timestamp": "$(date -Is)",
  "backrest_revision": "2.0"
}
EOF
  log_append "Wrote fallback manifest to $manifest"
}

remove_backrest_deps() {
  LOGPATH="$LOGDIR/ensure-deps.log"
  pkgs=(pv zstd parted partclone e2fsprogs xfsprogs ntfs-3g dosfstools lvm2 rsync btrfs-progs dkms build-essential linux-headers-generic zfsutils-linux zfs-dkms)
  echo "About to purge: ${pkgs[*]}"
  confirm_yesno "Proceed with unconditional purge and autoremove (will use --allow-remove-essential)?" || { echo "Cancelled"; LOGPATH=""; return 1; }
  export DEBIAN_FRONTEND=noninteractive
  log_append "apt-get remove --purge -y --allow-remove-essential ${pkgs[*]}"
  apt-get remove --purge -y --allow-remove-essential "${pkgs[@]}" >>"$LOGPATH" 2>&1 || log_append "apt-get remove had errors"
  log_append "apt-get autoremove -y"
  apt-get autoremove -y >>"$LOGPATH" 2>&1 || log_append "apt-get autoremove had errors"
  rm -f "$BACKREST_DIR/manifest.json" "$BACKREST_DIR/deps-ok" || true
  LOGPATH=""
  echo "Removal complete; see $LOGDIR/ensure-deps.log"
  press_any_key
  return 0
}

# --------------------------
# Self-test / logs
# --------------------------
SELFTEST_LOG="$LOGDIR/self-test.log"

self_test_writeonly() {
  : >"$SELFTEST_LOG"
  LOGPATH="$SELFTEST_LOG"
  log_append "Starting automatic self-test"
  {
    echo "BackRest self-test"
    echo "==================="
    echo "System: $(uname -a)"
    avail_bytes=$(df --output=avail -B1 / | awk 'NR==2{print $1}')
    echo "Free root bytes: $avail_bytes ($(humanize_bytes_round "$avail_bytes"))"
    echo
    echo "Checking required binaries:"
  } >>"$LOGPATH"
  declare -a required_bins=(pv zstd parted partclone partclone.restore partclone.ext4 partclone.xfs partclone.ntfs partclone.fat e2image mkfs.xfs ntfsclone dosfslabel lvcreate rsync btrfs dkms gcc make)
  for b in "${required_bins[@]}"; do
    if command -v "$b" >/dev/null 2>&1; then echo "  [OK]  $b -> $(command -v "$b")" >>"$LOGPATH"; else echo "  [MISSING] $b" >>"$LOGPATH"; fi
  done
  echo >>"$LOGPATH"
  echo "Network test (ping 8.8.8.8): $( (test_network_connectivity && echo OK) || echo FAILED )" >>"$LOGPATH"
  log_append "Self-test complete"
  LOGPATH=""
}

self_test_display() {
  self_test_writeonly
  if cmd_exists more; then more "$SELFTEST_LOG"
  elif cmd_exists less; then less "$SELFTEST_LOG"
  else cat "$SELFTEST_LOG"
  fi
  press_any_key
}

view_selftest_log() {
  [ -f "$SELFTEST_LOG" ] || { echo "Self-test log not found: $SELFTEST_LOG"; press_any_key; return 0; }
  if cmd_exists less; then less +G "$SELFTEST_LOG"; else tail -n 200 "$SELFTEST_LOG"; fi
  press_any_key
}

view_ensure_log() {
  logf="$LOGDIR/ensure-deps.log"
  [ -f "$logf" ] || { echo "Log file not found: $logf"; return 0; }
  if cmd_exists less; then less +G "$logf"; else tail -n 200 "$logf"; fi
  # no extra pause
}

# --------------------------
# Inventory / images
# --------------------------
declare -a MENU_KEYS MENU_LABELS MENU_DEVS MENU_TYPE

get_partition_flags() {
  disk="$1"; partnum="$2"
  command -v parted >/dev/null 2>&1 || { printf ""; return 0; }
  flags_raw="$(parted -ms "$disk" unit B print 2>/dev/null | awk -F: -v p="$partnum" '$1==p{print $7; exit}')"
  [ -z "$flags_raw" ] || [ "$flags_raw" = "." ] || [ "$flags_raw" = "-" ] && { printf ""; return 0; }
  flags_lc="$(printf "%s" "$flags_raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[; ]+/,/g; s/,+/,/g; s/^,+//; s/,+$//')"
  IFS=',' read -ra parts <<<"$flags_lc"
  out=""
  for t in "${parts[@]}"; do
    tok="$(printf "%s" "$t" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"; [ -z "$tok" ] && continue
    case "$tok" in legacy_boot|bios_grub) tok="boot" ;; efi) tok="efi" ;; esp) tok="esp" ;; boot) tok="boot" ;; lvm) tok="lvm" ;; raid) tok="raid" ;; hidden) tok="hidden" ;; swap) tok="swap" ;; msftdata|msft) tok="msftdata" ;; *) ;; esac
    [ -n "$out" ] && case ",$out," in *",$tok,"*) ;; *) out="${out},${tok}" ;; esac || out="$tok"
  done
  printf "%s" "$out"
}

build_inventory() {
  MENU_KEYS=(); MENU_LABELS=(); MENU_DEVS=(); MENU_TYPE=()
  mapfile -t disks < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')
  key_code=65
  for d in "${disks[@]}"; do
    dev="/dev/$d"; dev_base="$d"
    model_raw="$(lsblk -dn -o MODEL "$dev" 2>/dev/null || echo "")"
    model_clean="$(printf "%s" "$model_raw" | sed -E 's/[[:space:]]+[0-9]+([.][0-9]+)?(GB|TB|MB|gb|tb|mb)$//I' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    size_bytes="$(get_size_bytes "$dev")"; hsize="$(humanize_bytes_round "$size_bytes")"
    header="${dev_base} — ${model_clean:-unknown} — ${hsize}"
    key="$(printf "\\x$(printf %x "$key_code")")"
    MENU_KEYS+=("$key"); MENU_LABELS+=("[$key] ${header}"); MENU_DEVS+=("$dev"); MENU_TYPE+=("disk")
    ((key_code++))
    mapfile -t parts < <(lsblk -ln -o NAME,TYPE "$dev" | awk '$2=="part"{print $1}')
    for p in "${parts[@]}"; do
      pdev="/dev/$p"; pbase="$p"
      partnum="${p#${d}}"; partnum="${partnum#p}"
      flags="$(get_partition_flags "$dev" "$partnum")"; flags_display=""; [ -n "$flags" ] && flags_display=" (${flags})"
      fstype="$(blkid -s TYPE -o value "$pdev" 2>/dev/null || echo "")"
      label="$(blkid -s LABEL -o value "$pdev" 2>/dev/null || echo "")"
      psize_bytes="$(get_size_bytes "$pdev")"; psize="$(humanize_bytes_round "$psize_bytes")"
      mountpoint="$(lsblk -no MOUNTPOINT "$pdev" 2>/dev/null || echo "")"
      usage_display="N/A"
      if [ -n "$mountpoint" ]; then
        dfinfo="$(df -B1 "$mountpoint" 2>/dev/null | awk 'NR==2{print $3 "," $5}')"
        if [ -n "$dfinfo" ]; then
          used_bytes="$(echo "$dfinfo" | cut -d, -f1)"; pct_raw="$(echo "$dfinfo" | cut -d, -f2)"
          pct="$(printf "%s" "$pct_raw" | tr -d '%')"; used_human="$(humanize_bytes_round "$used_bytes")"
          usage_display="${used_human}/${pct}% used"
        fi
      fi
      ptype="${fstype:-unknown}"
      [ -n "$label" ] && labeldisplay="\"$label\"" || labeldisplay="\"(no label)\""
      entry="${pbase}${flags_display} — ${labeldisplay} — ${ptype} — ${psize} (${usage_display})"
      key="$(printf "\\x$(printf %x "$key_code")")"
      MENU_KEYS+=("$key"); MENU_LABELS+=("[$key] $entry"); MENU_DEVS+=("$pdev"); MENU_TYPE+=("part")
      ((key_code++))
    done
  done
}

show_inventory_menu() {
  echo
  printf "Detected drives and partitions:\n\n"
  for i in "${!MENU_KEYS[@]}"; do printf "%s\n" "${MENU_LABELS[$i]}"; done
  echo
}

list_images() {
  mapfile -t imgs < <(find "$IMGSTORE" -maxdepth 1 -type f -printf '%f\n' | sort)
  printf "%s\n" "${imgs[@]}"
}

show_images_menu() {
  echo
  printf "Images in $IMGSTORE:\n\n"
  mapfile -t images < <(list_images)
  if [ "${#images[@]}" -eq 0 ]; then printf "No image files found in $IMGSTORE\n"; return 1; fi
  key_code=65
  for img in "${images[@]}"; do key="$(printf "\\x$(printf %x "$key_code")")"; printf "[%s] %s\n" "$key" "$img"; ((key_code++)); done
  echo
  return 0
}

# --------------------------
# partclone helpers
# --------------------------
partclone_save_partition() {
  src_dev="$1"; out_file="$2"
  fstype="$(blkid -s TYPE -o value "$src_dev" 2>/dev/null || echo "")"
  if [ -z "$fstype" ]; then
    if cmd_exists pv; then pv_cmd="pv -s $(get_size_bytes "$src_dev")"; eval "dd if=\"$src_dev\" bs=4M status=none | $pv_cmd | $ZSTD_CMD > \"$out_file\""
    else eval "dd if=\"$src_dev\" bs=4M status=progress | $ZSTD_CMD > \"$out_file\""; fi
    return $?
  fi
  case "$fstype" in ext4) pc_bin="partclone.ext4" ;; ext3) pc_bin="partclone.ext3" ;; ext2) pc_bin="partclone.ext2" ;; xfs) pc_bin="partclone.xfs" ;; ntfs) pc_bin="partclone.ntfs" ;; fat16|fat32|vfat) pc_bin="partclone.fat" ;; *) pc_bin="" ;; esac
  if [ -n "$pc_bin" ] && command -v "$pc_bin" >/dev/null 2>&1; then
    if cmd_exists pv; then size_bytes=$(get_size_bytes "$src_dev"); [ -n "$size_bytes" ] && [ "$size_bytes" -gt 0 ] && eval "$pc_bin -c -s \"$src_dev\" -o - 2>/dev/null | pv -s $size_bytes | $ZSTD_CMD > \"$out_file\"" || eval "$pc_bin -c -s \"$src_dev\" -o - 2>/dev/null | $ZSTD_CMD > \"$out_file\""; else eval "$pc_bin -c -s \"$src_dev\" -o - 2>/dev/null | $ZSTD_CMD > \"$out_file\""; fi
    return $?
  fi
  log_append "ERROR: Required partclone binary ($pc_bin) not found for filesystem $fstype on $src_dev. Ensure dependencies are installed via Settings -> Dependencies."
  return 2
}

restore_image_to_device() {
  image_path="$1"; tgt_dev="$2"
  if file "$image_path" | grep -qi partclone >/dev/null 2>&1 || [[ "$image_path" == *.pcl* || "$image_path" == *.partclone* ]]; then
    if command -v partclone.restore >/dev/null 2>&1; then
      if cmd_exists pv; then pv "$image_path" | $ZSTD_DECOMP | partclone.restore -s - -o "$tgt_dev"; else $ZSTD_DECOMP < "$image_path" | partclone.restore -s - -o "$tgt_dev"; fi
      return $?
    else
      $ZSTD_DECOMP < "$image_path" | dd of="$tgt_dev" bs=4M conv=fsync status=progress
      return $?
    fi
  else
    if cmd_exists pv; then pv "$image_path" | $ZSTD_DECOMP | dd of="$tgt_dev" bs=4M conv=fsync; else $ZSTD_DECOMP < "$image_path" | dd of="$tgt_dev" bs=4M conv=fsync status=progress; fi
    return $?
  fi
}

# --------------------------
# Menus: helpers included above
# --------------------------

# --------------------------
# Backup flow (returns 0 on success, non-zero on failure)
# --------------------------
do_backup() {
  selection_idx="$1"
  seldev="${MENU_DEVS[$selection_idx]}"
  seltype="${MENU_TYPE[$selection_idx]}"
  sel_label="${MENU_LABELS[$selection_idx]}"

  echo
  echo "Selected: ${sel_label}"
  if [ "$seltype" = "disk" ]; then
    echo
    echo "[A] Partition-by-partition (recommended; uses partclone where possible)"
    echo "[B] Raw whole-disk (dd) - SLOW and will copy free space"
    echo "[C] Boot sector only (10MiB)"
    echo -n "Select option (or press Esc to cancel): "
    choice_raw="$(get_menu_choice 3)"
    [ "$choice_raw" = "-1" ] && { menu_invalid; return 1; }
    [ "$choice_raw" = "-2" ] && { menu_invalid; return 1; }
    case "$choice_raw" in
      0) mode="partitioned" ;;
      1) mode="raw" ;;
      *) mode="boot" ;;
    esac
  else
    echo
    echo "[A] Partition image (recommended; uses partclone)"
    echo "[B] Boot sector only (10MiB)"
    echo -n "Select option (or press Esc to cancel): "
    choice_raw="$(get_menu_choice 2)"
    [ "$choice_raw" = "-1" ] && { menu_invalid; return 1; }
    [ "$choice_raw" = "-2" ] && { menu_invalid; return 1; }
    [ "$choice_raw" = "0" ] && mode="partitioned" || mode="boot"
  fi

  echo
  echo -n "Enter descriptive filename base (no path, no spaces): "
  read filename_base
  filename_base="$(printf "%s" "$filename_base" | tr -d ' /')"
  [ -z "$filename_base" ] && { echo "Empty filename; cancelling."; return 1; }

  LOGPATH="$LOGDIR/${filename_base}.log"
  log_append "Backup requested: sel=${seldev}, type=${seltype}, mode=${mode}"

  if [ "$mode" = "boot" ]; then
    destname="${filename_base}.boot"
    if ! tmpfull="$(validate_and_prepare_dest "$destname")"; then log_append "Invalid destination path"; LOGPATH=""; echo "Invalid destination path"; press_any_key; return 1; fi
    tmpfull="$(printf "%s" "$tmpfull")"
    log_append "Writing boot sector to temp $tmpfull"
    if cmd_exists pv; then dd if="$seldev" bs=512 count="$BOOT_SECTOR_BLOCKS" status=none | pv -s "$BOOT_SECTOR_BYTES" > "$tmpfull"; else dd if="$seldev" bs=512 count="$BOOT_SECTOR_BLOCKS" of="$tmpfull" status=progress; fi
    mv "$tmpfull" "$IMGSTORE/$destname"
    log_append "Boot saved to $IMGSTORE/$destname"
    play_bell_three
    LOGPATH=""
    echo "Boot sector saved: $IMGSTORE/$destname"
    press_any_key
    return 0
  fi

  if [ "$mode" = "raw" ]; then
    destname="${filename_base}.raw.zst"
    if ! tmpfull="$(validate_and_prepare_dest "$destname")"; then log_append "Invalid destination"; LOGPATH=""; echo "Invalid destination"; press_any_key; return 1; fi
    tmpfull="$(printf "%s" "$tmpfull")"
    log_append "Starting raw dd -> zstd to $tmpfull"
    if cmd_exists pv; then pv_cmd="pv -s $(get_size_bytes "$seldev")"; eval "dd if=\"$seldev\" bs=4M status=none | $pv_cmd | $ZSTD_CMD > \"$tmpfull\""; else eval "dd if=\"$seldev\" bs=4M status=progress | $ZSTD_CMD > \"$tmpfull\""; fi
    mv "$tmpfull" "$IMGSTORE/$destname"
    log_append "Raw disk saved to $IMGSTORE/$destname"
    play_bell_three
    LOGPATH=""
    echo "Raw disk saved: $IMGSTORE/$destname"
    press_any_key
    return 0
  fi

  # partitioned mode
  if [ "$seltype" = "disk" ]; then
    parttable_file="${filename_base}.parttable.sfdisk"
    if ! tmp_pt="$(validate_and_prepare_dest "$parttable_file")"; then log_append "Invalid destination for partition table"; LOGPATH=""; echo "Invalid destination for partition table"; press_any_key; return 1; fi
    tmp_pt="$(printf "%s" "$tmp_pt")"
    log_append "Saving partition table of $seldev to $tmp_pt"
    sfdisk -d "$seldev" >"$tmp_pt"
    mv "$tmp_pt" "$IMGSTORE/$parttable_file"
    log_append "Partition table saved to $IMGSTORE/$parttable_file"

    mapfile -t parts < <(lsblk -ln -o NAME,TYPE "$seldev" | awk '$2=="part"{print $1}')
    [ "${#parts[@]}" -eq 0 ] && { log_append "No partitions found on $seldev"; echo "No partitions found"; LOGPATH=""; press_any_key; return 1; }

    for p in "${parts[@]}"; do
      pdev="/dev/$p"
      safe_name="${filename_base}_${p}.pcl.zst"
      if ! tmpfull="$(validate_and_prepare_dest "$safe_name")"; then log_append "Invalid dest for partition $p"; echo "Invalid dest for partition $p"; continue; fi
      tmpfull="$(printf "%s" "$tmpfull")"
      log_append "Backing up partition $pdev -> $tmpfull"
      if ! partclone_save_partition "$pdev" "$tmpfull"; then log_append "Failed to backup $pdev (missing tool or error)."; echo "Failed to backup $pdev; see Settings -> View ensure-deps.log."; rm -f "$tmpfull" || true; continue; fi
      mv "$tmpfull" "$IMGSTORE/$safe_name"
      log_append "Saved $pdev -> $IMGSTORE/$safe_name"
    done
    play_bell_three
    LOGPATH=""
    echo "Partitioned backup complete (see $IMGSTORE)"
    press_any_key
    return 0
  else
    # single partition
    pdev="$seldev"
    safe_name="${filename_base}_${pdev##*/}.pcl.zst"
    if ! tmpfull="$(validate_and_prepare_dest "$safe_name")"; then log_append "Invalid dest for partition"; LOGPATH=""; echo "Invalid dest for partition"; press_any_key; return 1; fi
    tmpfull="$(printf "%s" "$tmpfull")"
    log_append "Backing up partition $pdev -> $tmpfull"
    if ! partclone_save_partition "$pdev" "$tmpfull"; then log_append "Failed to backup partition $pdev"; echo "Failed to backup partition $pdev"; rm -f "$tmpfull" || true; LOGPATH=""; press_any_key; return 1; fi
    mv "$tmpfull" "$IMGSTORE/$safe_name"
    log_append "Saved $pdev -> $IMGSTORE/$safe_name"
    play_bell_three
    LOGPATH=""
    echo "Partition backup saved: $IMGSTORE/$safe_name"
    press_any_key
    return 0
  fi
}

# --------------------------
# Restore flow (returns 0 on success)
# --------------------------
do_restore() {
  mapfile -t images < <(list_images)
  [ "${#images[@]}" -eq 0 ] && { echo "No images in $IMGSTORE"; press_any_key; return 1; }
  show_images_menu
  echo -n "Select letter for the desired source image to restore (or press Esc to cancel): "
  choice_raw="$(get_menu_choice "${#images[@]}")"
  [ "$choice_raw" = "-1" ] && { menu_invalid; return 1; }
  [ "$choice_raw" = "-2" ] && { menu_invalid; return 1; }
  idx="$choice_raw"; image="${images[$idx]}"; imagepath="$IMGSTORE/$image"
  echo; echo "Selected image: $imagepath"

  build_inventory
  show_inventory_menu
  echo -n "Select the letter for the desired target device to restore to (or press Esc to cancel): "
  tgt_choice_raw="$(get_menu_choice "${#MENU_DEVS[@]}")"
  [ "$tgt_choice_raw" = "-1" ] && { menu_invalid; return 1; }
  [ "$tgt_choice_raw" = "-2" ] && { menu_invalid; return 1; }
  tgtidx="$tgt_choice_raw"; tgtdev="${MENU_DEVS[$tgtidx]}"

  echo; echo "Confirm:"; echo "  Restore image ${image} -> ${tgtdev##*/}"
  confirm_yesno "Proceed? This will overwrite the target device" || { echo "Cancelled"; press_any_key; return 1; }

  LOGPATH="$LOGDIR/restore_${image}.log"
  log_append "Starting restore of $imagepath to $tgtdev"

  if restore_image_to_device "$imagepath" "$tgtdev"; then
    log_append "Restore completed successfully."
    play_bell_three
    LOGPATH=""
    echo "Restore completed."
    press_any_key
    return 0
  else
    log_append "Restore failed."
    play_bell_three
    LOGPATH=""
    echo "Restore failed (see logs)."
    press_any_key
    return 1
  fi
}

# --------------------------
# Menus: helpers included above
# --------------------------
get_menu_choice() {
  max_entries="$1"
  read -rsn1 key
  echo
  if [ "$key" = $'\e' ]; then while read -rsn1 -t 0.01 junk; do :; done; printf "%s" "-1"; return 0; fi
  up="$(printf "%s" "$key" | tr '[:lower:]' '[:upper:]')"
  if ! printf "%s" "$up" | grep -q '^[A-Z]$'; then printf "%s" "-2"; return 0; fi
  idx="$(printf "%d" "'$up")"; base="$(printf "%d" "'A")"; idx=$((idx - base))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge "$max_entries" ]; then printf "%s" "-2"; return 0; fi
  printf "%s" "$idx"; return 0
}

confirm_yesno() {
  prompt="$1"
  echo
  echo -n "$prompt [y/N]: "
  read -rsn1 yn; echo
  [ "$yn" = $'\e' ] && { while read -rsn1 -t 0.01 junk; do :; done; return 1; }
  yn="$(printf "%s" "$yn" | tr '[:upper:]' '[:lower:]')"
  [ "$yn" = "y" ]
}

menu_invalid() { echo; echo "Invalid selection or cancelled; returning to main menu."; sleep 1; }

# --------------------------
# Settings menu
# --------------------------
settings_menu() {
  while true; do
    clear
    echo "======================"
    echo "  BackRest - Settings"
    echo "======================"
    echo
    echo "[D] Dependencies: (re)run ensure-backrest-depends"
    echo "[N] Networking: detect NIC and apply DHCP netplan"
    echo "[R] Remove Dependencies (purge + autoremove --allow-remove-essential)"
    echo "[T] View self-test log"
    echo "[L] View ensure-deps.log"
    echo
    echo -n "Select an option (or press Esc to cancel): "
    read -rsn1 ch; echo
    [ "$ch" = $'\e' ] && { while read -rsn1 -t 0.01 junk; do :; done; echo "Cancelled. Returning."; return 0; }
    ch="$(printf "%s" "$ch" | tr '[:lower:]' '[:upper:]')"
    case "$ch" in
      D) echo "Running dependency installer..."; if ensure_backrest_depends; then touch "$BACKREST_DIR/deps-ok"; echo "Dependencies installed."; press_any_key; return 0; else echo "Dependency install failed. See $LOGDIR/ensure-deps.log"; press_any_key; fi ;;
      N) LOGPATH="$LOGDIR/ensure-deps.log"; if setup_netplan; then echo "Networking configured."; else echo "Networking setup failed. See $LOGDIR/ensure-deps.log"; fi; LOGPATH=""; press_any_key ;;
      R) remove_backrest_deps ;;
      T) view_selftest_log ;;
      L) view_ensure_log ;;
      *) echo "Invalid selection."; sleep 1 ;;
    esac
  done
}

# --------------------------
# Main menu
# --------------------------
main_menu() {
  while true; do
    clear
    echo "=============================================="
    echo "   BackRest Backup / Restore Menu (interactive)"
    echo "=============================================="
    echo
    echo "[B] Backup"
    echo "[R] Restore"
    echo "[S] Settings"
    echo "[X] Exit and shutdown"
    echo
    echo -n "Select an option (or press Esc to cancel): "
    read -rsn1 mainchoice; echo
    [ "$mainchoice" = $'\e' ] && { while read -rsn1 -t 0.01 junk; do :; done; echo "Cancelled. Exiting."; exit 0; }
    mainchoice="$(printf "%s" "$mainchoice" | tr '[:lower:]' '[:upper:]')"
    case "$mainchoice" in
      B)
        build_inventory
        if [ "${#MENU_DEVS[@]}" -eq 0 ]; then echo "No block devices found."; press_any_key; continue; fi
        show_inventory_menu
        echo -n "Select the letter for the desired source to back up (or press Esc to cancel): "
        sel_choice_raw="$(get_menu_choice "${#MENU_DEVS[@]}")"
        [ "$sel_choice_raw" = "-1" ] && { menu_invalid; continue; }
        [ "$sel_choice_raw" = "-2" ] && { menu_invalid; continue; }
        if ! do_backup "$sel_choice_raw"; then echo "Backup ended with an error; returning to menu."; fi
        continue
        ;;
      R)
        if ! do_restore; then echo "Restore ended with an error; returning to menu."; fi
        continue
        ;;
      S) settings_menu; continue ;;
      X)
        # immediate shutdown without confirmation
        sync
        systemctl poweroff -i 2>/dev/null || shutdown -h now
        exit 0
        ;;
      *)
        echo "Invalid selection."
        sleep 1
        ;;
    esac
  done
}

# --------------------------
# Startup
# --------------------------
if [ -f "$BACKREST_DIR/manifest.json" ]; then
  manifest_age_days=$(( ( $(date +%s) - $(stat -c %Y "$BACKREST_DIR/manifest.json") ) / 86400 )) || manifest_age_days=9999
  [ "$manifest_age_days" -gt "$MANIFEST_TTL_DAYS" ] && { echo "Manifest older than $MANIFEST_TTL_DAYS days; re-running ensure-backrest-depends."; rm -f "$BACKREST_DIR/deps-ok" || true; }
fi

if [ ! -f "$BACKREST_DIR/deps-ok" ]; then
  echo "Dependency marker not found - running dependency bootstrap..."
  if ! ensure_backrest_depends; then
    echo "Dependency bootstrap failed. Entering Settings for recovery."
    sleep 1
    settings_menu
  else
    touch "$BACKREST_DIR/deps-ok"
  fi
fi

self_test_writeonly

[ -t 0 ] || { echo "This script is interactive and requires a real TTY (tty1). Exiting."; exit 1; }

main_menu
# End of file   1625
