#!/usr/bin/env bash
: <<'SCRIPT_HEADER'
backrest.sh
BackRest - interactive backup/restore tool (front-end for partclone + dd). Fully self-contained on bootable drive - backs up to/restores from /imgstore on same drive.
──────────────────────────────────────────────────────
Author: Don Ferris
Created: 2025-10-28
Current Revision: 2.1
──────────────────────────────────────────────────────
Revision History
================
v2.1 — 2025-11-02 — Added Wi‑Fi support: detect wireless NIC, include a wifis stanza in generated netplan (DHCPv4), prompt/store last SSID/passphrase in ~/backrest/last.wifi.conn and auto-use when SSID is visible; IPv6 disabled in generated netplan. Improved self-test to log IPv4 interface state and addresses (one line per interface) and connected SSID when present, ping 1.1.1.1, and displays the self-test log at startup. Removed the false "partclone" (no-extension) dependency check.
v2.0 — 2025-10-29 — Switched partition/volume backups to partclone (copies used blocks only) and reserve dd for boot-sector backups only; boot-sector capture size increased to 10MiB to reliably in[...]
v1.2 — 2025-10-24 — Added logging
v1.1 — 2025-10-24 — Menu refinements (better display of disk/partition information to make sure the right disk/partition is chosen).
v1.0 — 2025-10-24 — Initial implementation: A front-end for dd, BackRest displays a list of drives/partitions (for backup) or image files (for restore) as a menu with one-key menu item selectors. [...]
──────────────────────────────────────────────────────
Github Copilot Development Conversations:
https://github.com/copilot/c/16bc921c-c3fa-47b0-b483-3d73a9936593
https://github.com/copilot/c/43e6255b-db29-4c3b-a638-7dcd705bec53

# END OF
SCRIPT_HEADER

set -eu -o pipefail

# --------------------------
# Configuration / constants
# --------------------------
IMGSTORE="/imgstore"
BACKREST_DIR="$HOME/backrest"
LOGDIR="$BACKREST_DIR/logs"
TMPDIR="$IMGSTORE/.tmp"
SCRIPTPATH="")(realpath "{BASH_SOURCE[0]:-$0}")"
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
  s="${s//\/\\}"
  s="${s//"/\"}"
  printf '%s' "$s"
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
    command -v "$c" >/dev/null 2>&1 && return 0;
  done
  return 1;
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
  tmpname="$(printf "%s.tmp.%s.%s" "$user_fname" "$$(date +%s)")"
  tmpfull="$TMPDIR/$tmpname"
  printf "%s" "$tmpfull"
  return 0;
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
    printf "%s" "$ifname"; return 0;
  done < <(ip -o link show | awk -F': ' '{print $2}')
  return 1;
}

choose_wireless_if() {
  while IFS= read -r ifname; do
    case "$ifname" in lo|docker*|veth*|virbr*|br-*|tun*|tap*|wg*|vmnet*|vboxnet*) continue ;; esac
    if [ -d "/sys/class/net/$ifname/wireless" ]; then
      printf "%s" "$ifname"; return 0;
    fi
    if command -v iw >/dev/null 2>&1; then
      if iw dev 2>/dev/null | awk '/Interface/ {print $2}' | grep -q "^$ifname$" >/dev/null 2>&1; then
        printf "%s" "$ifname"; return 0;
      fi
    fi
    case "$ifname" in wlan*|wlp*)
      printf "%s" "$ifname"; return 0;
      ;;
    esac
  done < <(ip -o link show | awk -F': ' '{print $2}')
  return 1;
}

scan_visible_ssids() {
  wifi_if="$1"
  if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f SSID dev wifi list ifname "$wifi_if" 2>/dev/null | awk -F: '{print $1}' | awk 'NF' | awk '!seen[$0]++'
    return 0;
  fi
  if command -v iw >/dev/null 2>&1; then
    iw dev "$wifi_if" scan 2>/dev/null | awk -F'SSID: ' '/SSID: /{print substr($0, index($0,$2))}' | awk 'NF' | awk '!seen[$0]++'
    return 0;
  fi
  return 1;
}

prompt_select_ssid() {
  mapfile -t ssids < <(printf "%s\n" "$@" | sed '/^\s*$/d')
  if [ "");
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
  return 0;
}

read_last_wificonn() {
  f="$BACKREST_DIR/last.wifi.conn"
  [ -f "$f" ] || return 1
  ssid="$(sed -n '1p' "$f" 2>/dev/null || true)"
  psk="$(sed -n '2p' "$f" 2>/dev/null || true)"
  printf "%s\n%s" "$ssid" "$psk"
  return 0;
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
          sel="$(prompt_select_ssid "${visible[@]}" )" || sel=""
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
        sel="$(prompt_select_ssid "${visible[@]}" )" || sel=""
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
    s="${s//\/\\}"
    s="${s//"/\"}"
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
  apt-get update -y >>"$LOGDIR/ensure-deps.log" 2>&1 || log_append "apt-get update had warnings/errors"
  if ! apt-get install -y "${pkgs[@]}" >>"$LOGDIR/ensure-deps.log" 2>&1; then log_append "apt-get install failed for: ${pkgs[*]}"; return 1; fi
  log_append "install_packages: succeeded for: ${pkgs[*]}"
  return 0;
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
    name_q="$(printf '%s' "$name" | sed -e 's/\/\\/g' -e 's/"/\"/g')"
    ver_q="$(printf '%s' "$ver" | sed -e 's/\/\\/g' -e 's/"/\"/g')"
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
    bq="$(printf '%s' "$b" | sed -e 's/\/\\/g' -e 's/"/\"/g')"
    echo -n "$bq" >>"$manifest"
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
  return 0;
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
  return 0;
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
      return 0;
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
        return 0;
      fi
    fi
  fi

  # 3) nmcli device show <if> -> GENERAL.CONNECTION (profile name often equals SSID)
  if command -v nmcli >/dev/null 2>&1; then
    ssid="$(nmcli device show "$ifname" 2>/dev/null | awk -F': ' '/GENERAL.CONNECTION/ {print $2; exit}' || true)'
