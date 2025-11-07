#!/usr/bin/env bash
: <<'SCRIPT_HEADER'
backrest.sh
BackRest - interactive backup/restore tool (front-end for partclone + dd). Fully self-contained on bootable drive - backs up to/restores from /imgstore on same drive.
──────────────────────────────────────────────────────
Author: Don Ferris
Created: 2025-10-28
Current Revision: 2.2
──────────────────────────────────────────────────────
Revision History
================
v2.2 — 2025-11-04 — Fixed undesirable menu behavior by adding helper python script backrest_readkey.py
v2.1 — 2025-11-02 — Added Wi‑Fi support: detect wireless NIC, include a wifis stanza in generated netplan (DHCPv4), prompt/store last SSID/passphrase in ~/backrest/last.wifi.conn and auto-us[...]
v2.0 — 2025-10-29 — Switched partition/volume backups to partclone (copies used blocks only) and reserve dd for boot-sector backups only; boot-sector capture size increased to 10MiB to reliabl[...]
v1.2 — 2025-10-24 — Added logging
v1.1 — 2025-10-24 — Menu refinements (better display of disk/partition information to make sure the right disk/partition is chosen).
v1.0 — 2025-10-24 — Initial implementation: A front-end for dd, BackRest displays a list of drives/partitions (for backup) or image files (for restore) as a menu with one-key menu item selecto[...]
──────────────────────────────────────────────────────
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

choose_wireless_if() {
  while IFS= read -r ifname; do
    case "$ifname" in lo|docker*|veth*|virbr*|br-*|tun*|tap*|wg*|vmnet*|vboxnet*) continue ;; esac
    if [ -d "/sys/class/net/$ifname/wireless" ]; then
      printf "%s" "$ifname"; return 0
    fi
    if command -v iw >/dev/null 2>&1; then
      if iw dev 2>/dev/null | awk '/Interface/ {print $2}' | grep -q "^$ifname$" >/dev/null 2>&1; then
        printf "%s" "$ifname"; return 0
      fi
    fi
    case "$ifname" in wlan*|wlp*)
      printf "%s" "$ifname"; return 0
      ;;
    esac
  done < <(ip -o link show | awk -F': ' '{print $2}')
  return 1
}

scan_visible_ssids() {
  wifi_if="$1"
  if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f SSID dev wifi list ifname "$wifi_if" 2>/dev/null | awk -F: '{print $1}' | awk 'NF' | awk '!seen[$0]++'
    return 0
  fi
  if command -v iw >/dev/null 2>&1; then
    iw dev "$wifi_if" scan 2>/dev/null | awk -F'SSID: ' '/SSID: /{print substr($0, index($0,$2))}' | awk 'NF' | awk '!seen[$0]++'
    return 0
  fi
  return 1
}

prompt_select_ssid() {
  mapfile -t ssids < <(printf "%s\n" "$@" | sed '/^\s*$/d')
  if [ "${#ssids[@]}" -eq 0 ]; then return 1; fi
  echo
  echo "Available Wi-Fi networks:"
  for i in "${!ssids[@]}"; do
    idx=$((i+1))
    printf "  %d) %s\n" "$idx" "${ssids[$i]}"
  done
  echo
  echo -n "Select network by number (or press Esc to cancel): "
  read -rsn1 ch
  echo
  if [ "$ch" = $'\e' ]; then while read -rsn1 -t 0.01 junk; do :; done; return 1; fi
  if ! printf "%s" "$ch" | grep -q '^[0-9]$'; then echo "Invalid selection"; return 1; fi
  sel=$((ch - 1))
  if [ "$sel" -lt 0 ] || [ "$sel" -ge "${#ssids[@]}" ]; then echo "Invalid selection"; return 1; fi
  printf "%s" "${ssids[$sel]}"
  return 0
}

read_last_wificonn() {
  f="$BACKREST_DIR/last.wifi.conn"
  [ -f "$f" ] || return 1
  ssid="$(sed -n '1p' "$f" 2>/dev/null || true)"
  psk="$(sed -n '2p' "$f" 2>/dev/null || true)"
  printf "%s\n%s" "$ssid" "$psk"
  return 0
}

write_last_wificonn() {
  ssid="$1"; psk="$2"
  f="$BACKREST_DIR/last.wifi.conn"
  umask_save="$(umask)"
  umask 177
  {
    printf "%s\n" "$ssid"
    printf "%s\n" "$psk"
  } >"$f"
  chmod 600 "$f" 2>/dev/null || true
  umask "$umask_save"
  log_append "Saved last wifi credentials to $f (permissions 600)"
}

# --------------------------
# Connectivity test (ping target changed to 1.1.1.1)
# --------------------------
test_network_connectivity() {
  if cmd_exists ping; then
    ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && return 0 || return 1
  else
    ip route show default >/dev/null 2>&1 && return 0 || return 1
  fi
}

setup_netplan() {
  ensure_log="$LOGDIR/ensure-deps.log"
  LOGPATH="$ensure_log"
  ifname="$(choose_physical_if || true)"
  if [ -z "$ifname" ]; then log_append "No suitable physical interface detected"; LOGPATH=""; return 1; fi
  log_append "Selected interface $ifname for DHCP netplan"

  wifi_if="$(choose_wireless_if || true)"

  wifi_ssid=""
  wifi_psk=""
  want_save_last=false
  if [ -n "$wifi_if" ]; then
    log_append "Detected wireless interface $wifi_if -- scanning for SSIDs"
    mapfile -t visible < <(scan_visible_ssids "$wifi_if" 2>/dev/null || true)
    if read_last="$(read_last_wificonn 2>/dev/null || true)"; then
      last_ssid="$(printf "%s" "$read_last" | sed -n '1p')"
      last_psk="$(printf "%s" "$read_last" | sed -n '2p')"
      if [ -n "$last_ssid" ] && printf "%s\n" "${visible[@]}" | grep -Fxq -- "$last_ssid" 2>/dev/null; then
        wifi_ssid="$last_ssid"
        wifi_psk="$last_psk"
        log_append "Using stored SSID $wifi_ssid from last.wifi.conn"
      else
        if [ "${#visible[@]}" -gt 0 ]; then
          sel="$(prompt_select_ssid "${visible[@]}")" || sel=""
          if [ -n "$sel" ]; then
            wifi_ssid="$sel"
            echo -n "Enter passphrase for \"$wifi_ssid\": "
            read -rs wifi_psk
            echo
            want_save_last=true
          else
            log_append "WiFi selection cancelled by user"
          fi
        else
          log_append "No WiFi SSIDs visible to select"
        fi
      fi
    else
      if [ "${#visible[@]}" -gt 0 ]; then
        sel="$(prompt_select_ssid "${visible[@]}")" || sel=""
        if [ -n "$sel" ]; then
          wifi_ssid="$sel"
          echo -n "Enter passphrase for \"$wifi_ssid\": "
          read -rs wifi_psk
          echo
          want_save_last=true
        else
          log_append "WiFi selection cancelled by user"
        fi
      else
        log_append "No WiFi SSIDs visible and no saved credentials"
      fi
    fi
  fi

  backup_netplan_files
  cfg="/etc/netplan/01-netcfg.yaml"

  escape_yaml() {
    s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf "%s" "$s"
  }

  # NOTE: IPv6 disabled (dhcp6: false, accept-ra: false)
  if [ -n "$wifi_ssid" ]; then
    ssid_esc="$(escape_yaml "$wifi_ssid")"
    psk_esc="$(escape_yaml "$wifi_psk")"
    cat >"$cfg" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $ifname:
      dhcp4: true
      dhcp6: false
      accept-ra: false
  wifis:
    $wifi_if:
      optional: true
      access-points:
        "$ssid_esc":
          password: "$psk_esc"
      dhcp4: true
      dhcp6: false
      accept-ra: false
EOF
  else
    cat >"$cfg" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $ifname:
      dhcp4: true
      dhcp6: false
      accept-ra: false
EOF
  fi

  chmod 600 "$cfg" || log_append "Warning: chmod 600 $cfg failed"
  log_append "Wrote and chmod'd $cfg (600)"
  if ! cmd_exists netplan; then log_append "netplan not installed"; LOGPATH=""; return 1; fi

  if netplan apply >>"$ensure_log" 2>&1; then
    log_append "netplan apply succeeded"
  else
    log_append "netplan apply failed (see $ensure_log)"; journalctl -n 50 -u systemd-networkd >>"$ensure_log" 2>&1 || true
  fi

  if test_network_connectivity && [ -n "$wifi_ssid" ] && [ "$want_save_last" = true ]; then
    write_last_wificonn "$wifi_ssid" "$wifi_psk"
  fi

  test_network_connectivity && { log_append "Network connectivity verified"; LOGPATH=""; return 0; } || { log_append "Network connectivity not established"; LOGPATH=""; return 1; }
}

# --------------------------
# Package install and manifest
# --------------------------
install_packages() {
  pkgs=("$@")
  log_append "install_packages: apt-get install -y ${pkgs[*]}"
  export DEBIAN_FRONTEND=noninteractive
  # Retry apt-get update up to a few times with exponential backoff to handle transient network/mirror issues.
  # We log each failed attempt to the ensure-deps log and abort the install if all attempts fail.
  _ar_attempts=3
  _ar_try=1
  _ar_wait=1
  _ar_ok=1
  while [ "$_ar_try" -le "$_ar_attempts" ]; do
    if apt-get update -y >>"$LOGDIR/ensure-deps.log" 2>&1; then
      _ar_ok=0
      break
    fi
    log_append "apt-get update failed (attempt $_ar_try of $_ar_attempts); retrying in ${_ar_wait}s"
    sleep "$_ar_wait"
    _ar_try=$(( _ar_try + 1 ))
    _ar_wait=$(( _ar_wait * 2 ))
  done
  [ "$_ar_ok" -eq 0 ] || { log_append "apt-get update failed after ${_ar_attempts} attempts"; return 1; }
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
  # removed plain "partclone" (no-extension) from this list to avoid false-missing reports;
  # keep extension-specific binaries.
  for b in partclone.restore partclone.ext4 partclone.xfs partclone.ntfs partclone.fat pv zstd parted e2image mkfs.xfs ntfsclone dosfslabel lvcreate rsync btrfs dkms gcc make zfs zpool; do
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
    bq="$(printf '%s' "$b" | sed -e 's/\\/\\\\/g' -e 's/\"/\\\"/g')"
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
  pkg_cmds[partclone]="partclone.restore partclone.ext4 partclone.xfs partclone.ntfs partclone.fat"
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

# Robust SSID detection helper: try iwgetid, then iw, then nmcli
get_ssid_for_if() {
  ifname="$1"
  ssid=""

  # 1) iwgetid -r returns the SSID if connected
  if command -v iwgetid >/dev/null 2>&1; then
    ssid="$(iwgetid -r "$ifname" 2>/dev/null || true)"
    ssid="$(printf "%s" "$ssid" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -n "$ssid" ]; then
      printf "%s" "$ssid"
      return 0
    fi
  fi

  # 2) iw dev <if> link : parse "SSID: <name>" line robustly
  if command -v iw >/dev/null 2>&1; then
    linkout="$(iw dev "$ifname" link 2>/dev/null || true)"
    ssid_line="$(printf "%s" "$linkout" | grep -m1 'SSID:' || true)"
    if [ -n "$ssid_line" ]; then
      ssid="$(printf "%s" "$ssid_line" | sed 's/.*SSID:[[:space:]]*//')"
      ssid="$(printf "%s" "$ssid" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      if [ -n "$ssid" ] && ! printf "%s" "$ssid" | grep -qi 'not connected'; then
        printf "%s" "$ssid"
        return 0
      fi
    fi
  fi

  # 3) nmcli device show <if> -> GENERAL.CONNECTION (profile name often equals SSID)
  if command -v nmcli >/dev/null 2>&1; then
    ssid="$(nmcli device show "$ifname" 2>/dev/null | awk -F': ' '/GENERAL.CONNECTION/ {print $2; exit}' || true)"
    ssid="$(printf "%s" "$ssid" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -n "$ssid" ] && [ "$ssid" != "--" ]; then
      printf "%s" "$ssid"
      return 0
    fi

    ssid="$(nmcli -t -f IN-USE,SSID,DEVICE dev wifi 2>/dev/null | awk -F: -v dev="$ifname" '$3==dev && $1=="*"{print $2; exit}' || true)"
    ssid="$(printf "%s" "$ssid" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -n "$ssid" ]; then
      printf "%s" "$ssid"
      return 0
    fi
  fi

  printf "%s" ""
  return 0
}

# list ethernet and wifi interfaces with IPv4 (no CIDR) and SSID if connected
list_interfaces_info() {
  while IFS= read -r ifname; do
    [ -z "$ifname" ] && continue
    case "$ifname" in
      lo|l0|docker*|veth*|virbr*|br-*|tun*|tap*|wg*|vmnet*|vboxnet*) continue ;;
    esac

    is_wireless=false
    if [ -d "/sys/class/net/$ifname/wireless" ] || printf "%s" "$ifname" | grep -Eq '^(wlan|wlp)'; then
      is_wireless=true
    fi

    is_ethernet=false
    if ip -o link show dev "$ifname" 2>/dev/null | grep -q 'link/ether'; then
      is_ethernet=true
    else
      if [ -f "/sys/class/net/$ifname/address" ]; then
        hwaddr="$(cat /sys/class/net/$ifname/address 2>/dev/null || true)"
        if [ -n "$hwaddr" ] && [ "$hwaddr" != "00:00:00:00:00:00" ]; then
          is_ethernet=true
        fi
      fi
    fi

    if [ "$is_wireless" = false ] && [ "$is_ethernet" = false ]; then
      continue
    fi

    if [ -f "/sys/class/net/$ifname/operstate" ]; then
      state="$(cat "/sys/class/net/$ifname/operstate" 2>/dev/null || echo unknown)"
    else
      state="$(ip -o link show dev "$ifname" 2>/dev/null | awk '{print $9}' || echo unknown)"
    fi

    addrs=""
    mapfile -t a4 < <(ip -o -4 addr show dev "$ifname" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    for x in "${a4[@]}"; do
      [ -z "$x" ] && continue
      if [ -z "$addrs" ]; then addrs="$x"; else addrs="${addrs},${x}"; fi
    done
    [ -z "$addrs" ] && addrs="(no address)"

    ssid=""
    if [ "$is_wireless" = true ]; then
      ssid="$(get_ssid_for_if "$ifname" 2>/dev/null || true)"
    fi

    if [ -n "$ssid" ]; then
      printf "%s - %s - %s (%s)\n" "$ifname" "$state" "$addrs" "$ssid"
    else
      printf "%s - %s - %s\n" "$ifname" "$state" "$addrs"
    fi
  done < <(ip -o link show | awk -F': ' '{print $2}')
}

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

  declare -a required_bins=(pv zstd parted partclone.restore partclone.ext4 partclone.xfs partclone.ntfs partclone.fat e2image mkfs.xfs ntfsclone dosfslabel lvcreate rsync btrfs dkms gcc make)
  for b in "${required_bins[@]}"; do
    if command -v "$b" >/dev/null 2>&1; then
      echo "  [OK]  $b -> $(command -v "$b")" >>"$LOGPATH"
    else
      echo "  [MISSING] $b" >>"$LOGPATH"
    fi
  done
  echo >>"$LOGPATH"

  {
    echo "Detected network interfaces:"
  } >>"$LOGPATH"
  list_interfaces_info >>"$LOGPATH" 2>/dev/null || true
  echo >>"$LOGPATH"

  echo "Network test (ping 1.1.1.1): $( (test_network_connectivity && echo OK) || echo FAILED )" >>"$LOGPATH"
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
    case "$tok" in legacy_boot|bios_grub) tok="boot" ;; efi) tok="efi" ;; esp) tok="esp" ;; boot) tok="boot" ;; lvm) tok="lvm" ;; raid) tok="raid" ;; hidden) tok="hidden" ;; swap) tok="swap" ;; m[...]
      ;;
    esac
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
  case "$fstype" in
    ext4) pc_bin="partclone.ext4" ;;
    ext3) pc_bin="partclone.ext3" ;;
    ext2) pc_bin="partclone.ext2" ;;
    xfs) pc_bin="partclone.xfs" ;;
    ntfs) pc_bin="partclone.ntfs" ;;
    fat16|fat32|vfat) pc_bin="partclone.fat" ;;
    *) pc_bin="" ;;
  esac
  if [ -n "$pc_bin" ] && command -v "$pc_bin" >/dev/null 2>&1; then
    if cmd_exists pv; then
      size_bytes=$(get_size_bytes "$src_dev")
      [ -n "$size_bytes" ] && [ "$size_bytes" -gt 0 ] && eval "$pc_bin -c -s \"$src_dev\" -o - 2>/dev/null | pv -s $size_bytes | $ZSTD_CMD > \"$out_file\""
      return $?
    else
      eval "$pc_bin -c -s \"$src_dev\" -o - 2>/dev/null | $ZSTD_CMD > \"$out_file\""
      return $?
    fi
  fi
  # fallback to dd if no partclone available
  if cmd_exists pv; then
    pv_cmd="pv -s $(get_size_bytes "$src_dev")"
    eval "dd if=\"$src_dev\" bs=4M status=none | $pv_cmd | $ZSTD_CMD > \"$out_file\""
  else
    eval "dd if=\"$src_dev\" bs=4M status=progress | $ZSTD_CMD > \"$out_file\""
  fi
  return $?
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

# Robust single-key reader that prefers the helper python binary if available.
# Sets READ_KEY to:
#  - "ESC" if user pressed escape
#  - a single character (byte) otherwise
read_menu_key() {
  READ_KEY=""
  # Prefer installed helper: first look under BACKREST_DIR/bin then /usr/local/bin
  READ_HELPER="${BACKREST_DIR:-$HOME/backrest}/bin/backrest_readkey.py"
  [ -x "$READ_HELPER" ] || READ_HELPER="/usr/local/bin/backrest_readkey.py"
  # If helper exists and is executable, use it to get a literal \xHH sequence
  if [ -x "$READ_HELPER" ]; then
    # read helper output from /dev/tty to ensure we don't read from redirected stdin
    out="$("$READ_HELPER" < /dev/tty 2>/dev/null || true)"
    if [ -n "$out" ]; then
      # Decode the \xHH sequences into bytes and examine the first byte
      decoded="$(printf '%b' "$out")"
      # Extract first byte
      first_byte="$(printf '%s' "$decoded" | awk '{printf "%c", substr($0,1,1)}' 2>/dev/null || printf '%s' "${decoded:0:1}")"
      if [ "$first_byte" = $'\e' ]; then
        READ_KEY="ESC"
      else
        READ_KEY="$first_byte"
      fi
      return 0
    fi
  fi

  # Fallback: use builtin read from /dev/tty
  if IFS= read -rsn1 key < /dev/tty 2>/dev/null; then
    if [ "$key" = $'\e' ]; then
      # consume any remaining quickly to avoid leaving bytes in the tty buffer
      while read -rsn1 -t 0.01 junk < /dev/tty 2>/dev/null; do :; done
      READ_KEY="ESC"
    else
      READ_KEY="$key"
    fi
  else
    READ_KEY=""
  fi
}

# Replaced get_menu_choice() - robust single-key reader using read_menu_key()
get_menu_choice() {
  max_entries="$1"

  # Use the centralized single-key reader so ESC and escape sequences are handled robustly.
  read_menu_key

  # If helper indicated ESC -> cancel
  if [ "${READ_KEY:-}" = "ESC" ]; then
    printf "%s" "-1"
    return 0
  fi

  # If nothing read -> invalid/non-letter
  if [ -z "${READ_KEY:-}" ]; then
    printf "%s" "-2"
    return 0
  fi

  ch="$READ_KEY"
  up="$(printf "%s" "$ch" | tr '[:lower:]' '[:upper:]')"

  # Must be a single ASCII letter
  if ! printf "%s" "$up" | grep -q '^[A-Z]$'; then
    printf "%s" "-2"
    return 0
  fi

  idx="$(printf "%d" "'$up")"; base="$(printf "%d" "'A")"; idx=$((idx - base))

  if [ "$idx" -lt 0 ] || [ "$idx" -ge "$max_entries" ]; then
    printf "%s" "-2"
    return 0
  fi

  printf "%s" "$idx"
  return 0
}

confirm_yesno() {
  prompt="$1"
  echo
  echo -n "$prompt [y/N]: "
  # Use read_menu_key so ESC handling is consistent here too
  read_menu_key
  echo
  [ "$READ_KEY" = "ESC" ] && { while read -rsn1 -t 0.01 junk; do :; done; return 1; }
  yn="$(printf "%s" "$READ_KEY" | tr '[:upper:]' '[:lower:]')"
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
      D) echo "Running dependency installer..."; if ensure_backrest_depends; then touch "$BACKREST_DIR/deps-ok"; echo "Dependencies installed."; press_any_key; return 0; else echo "Dependency in[...]
      N) LOGPATH="$LOGDIR/ensure-deps.log"; if setup_netplan; then echo "Networking configured."; else echo "Networking setup failed. See $LOGDIR/ensure-deps.log"; fi; LOGPATH=""; press_any_key [...]
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

# Run self-test and display its log before continuing to main menu.
self_test_display

[ -t 0 ] || { echo "This script is interactive and requires a real TTY (tty1). Exiting."; exit 1; }

main_menu
# End of file  251104-1127
