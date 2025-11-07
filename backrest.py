#!/usr/bin/env python3
"""
backrest.sh
BackRest - interactive or unattended backup/restore tool (front-end for partclone + dd). Fully self-contained on bootable drive - backs up to/restores from /imgstore on same drive.
──────────────────────────────────────────────────────
Author: Don Ferris
Created: 2025-11-05
Current Revision: 0.1
──────────────────────────────────────────────────────
Revision History
================
v0.1 — 2025-11-05 — create stubbed module for BackRest application.
──────────────────────────────────────────────────────

END OF SCRIPT_HEADER
"""

import os
import sys
import logging
import json
import subprocess
import time
import signal
import hashlib
import shutil
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Tuple, Optional, Any

# ========================
# I. GLOBALS / CONSTANTS
# ========================

BACKREST_DIR = Path(__file__).parent.resolve()
LOGS_CFG_DIR = Path("/logs-cfg")
IMGSTORE_DIR = Path("/imgstore")
HEADLESS_CFG_PATH = LOGS_CFG_DIR / "headless.cfg"
HEADLESS_TIMEOUT = 30  # seconds - configurable via settings
DEPENDS_FILE = BACKREST_DIR / "depends.lst"
BACKREST_DRV = None  # determined at runtime
USER = "backrest"

# Runtime state
runtime_state = {}
logger = None

# Simple console logging fallback
def _console_log(level: str, message: str):
    """Fallback logging to console before logger is initialized."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{level}] {message}", flush=True)


# =========================================
# II. UTILITY & SYSTEM FUNCTIONS
# =========================================

def init_environment() -> Dict[str, Any]:
    """Bootstrap runtime state and validate environment (called at script start)."""
    global runtime_state, logger
    
    runtime_state = {
        "backrest_dir": BACKREST_DIR,
        "logs_cfg_dir": LOGS_CFG_DIR,
        "imgstore_dir": IMGSTORE_DIR,
        "headless_cfg_path": HEADLESS_CFG_PATH,
        "settings": read_settings(),
        "start_time": datetime.now()
    }
    
    logger = setup_logging()
    if logger:
        logger.info(f"BackRest initialized at {runtime_state['start_time']}")
    else:
        _console_log("INFO", f"BackRest initialized at {runtime_state['start_time']}")
    
    return runtime_state


def check_mounts() -> bool:
    """Ensure IMGSTORE_DIR and LOGS_CFG_DIR are mounted & writable."""
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        # Check if directories exist
        if not IMGSTORE_DIR.exists():
            safe_log("error", f"IMGSTORE_DIR {IMGSTORE_DIR} does not exist")
            return False
        if not LOGS_CFG_DIR.exists():
            safe_log("error", f"LOGS_CFG_DIR {LOGS_CFG_DIR} does not exist")
            return False
        
        # Check writability
        test_file_imgstore = IMGSTORE_DIR / ".write_test"
        test_file_logs = LOGS_CFG_DIR / ".write_test"
        
        try:
            test_file_imgstore.touch()
            test_file_imgstore.unlink()
            test_file_logs.touch()
            test_file_logs.unlink()
        except PermissionError as e:
            safe_log("error", f"Mount check failed: {e}")
            return False
        
        safe_log("info", "Mount check passed")
        return True
    except Exception as e:
        safe_log("error", f"Error checking mounts: {e}")
        return False


def setup_logging() -> Optional[logging.Logger]:
    """Configure logging to /logs-cfg/lastrun.log and console."""
    try:
        # Ensure archive directory exists
        archive_dir = LOGS_CFG_DIR / "archive"
        archive_dir.mkdir(parents=True, exist_ok=True)
        
        # Create logger
        log = logging.getLogger("BackRest")
        log.setLevel(logging.DEBUG)
        
        # File handler
        log_file = LOGS_CFG_DIR / "lastrun.log"
        file_handler = logging.FileHandler(log_file, mode='w')
        file_handler.setLevel(logging.DEBUG)
        
        # Console handler
        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setLevel(logging.INFO)
        
        # Formatter
        formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
        file_handler.setFormatter(formatter)
        console_handler.setFormatter(formatter)
        
        log.addHandler(file_handler)
        log.addHandler(console_handler)
        
        return log
    except Exception as e:
        # Fallback to console logging
        _console_log("ERROR", f"Failed to setup logging: {e}")
        return None


def archive_lastrun_log() -> Optional[Path]:
    """Copy/rotate /logs-cfg/lastrun.log -> /logs-cfg/archive/YYYYMMDD-hhmm.log"""
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        lastrun_log = LOGS_CFG_DIR / "lastrun.log"
        if not lastrun_log.exists():
            return None
        
        timestamp = datetime.now().strftime("%Y%m%d-%H%M")
        archive_path = LOGS_CFG_DIR / "archive" / f"{timestamp}.log"
        
        shutil.copy2(lastrun_log, archive_path)
        safe_log("info", f"Archived log to {archive_path}")
        return archive_path
    except Exception as e:
        safe_log("error", f"Failed to archive log: {e}")
        return None


def read_dependencies(file: Path = DEPENDS_FILE) -> List[str]:
    """Read package/tool dependency list from depends.lst"""
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        if not file.exists():
            safe_log("warning", f"Dependencies file {file} not found")
            return []
        
        with open(file, 'r') as f:
            deps = [line.strip() for line in f if line.strip() and not line.startswith('#')]
        
        safe_log("debug", f"Read {len(deps)} dependencies from {file}")
        return deps
    except Exception as e:
        safe_log("error", f"Error reading dependencies: {e}")
        return []


def check_dependencies(continue_on_unmet: bool = False) -> Tuple[bool, List[str]]:
    """Verify dependencies are installed."""
    dependencies = read_dependencies()
    missing = []
    
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    for dep in dependencies:
        # Check if command/package exists
        result = subprocess.run(['which', dep], capture_output=True, text=True)
        if result.returncode != 0:
            missing.append(dep)
            safe_log("warning", f"Missing dependency: {dep}")
    
    all_ok = len(missing) == 0
    
    if not all_ok:
        safe_log("warning", f"Missing {len(missing)} dependencies: {', '.join(missing)}")
        if not continue_on_unmet:
            safe_log("error", "Cannot continue with unmet dependencies")
    
    return all_ok, missing


def self_test() -> Dict[str, Any]:
    """Run non-destructive self-test (dependency checks + small network report)"""
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    safe_log("info", "Running self-test...")
    
    dependencies_ok, missing_deps = check_dependencies(continue_on_unmet=True)
    net_report = list_network_interfaces()
    
    summary = {
        "dependencies_ok": dependencies_ok,
        "missing_dependencies": missing_deps,
        "net_report": net_report,
        "timestamp": datetime.now().isoformat()
    }
    
    # Print display-ready lines
    print("\n=== BackRest Self-Test ===")
    print(f"[{'OK' if dependencies_ok else 'WARN'}] Dependencies: {len(missing_deps)} missing")
    for dep in missing_deps:
        print(f"  [MISSING] {dep}")
    
    print(f"\nNetwork Interfaces: {len(net_report)}")
    for iface in net_report:
        print(f"  {iface.get('name', 'unknown')}: {iface.get('link_state', 'unknown')} - {iface.get('ip', 'No IP')}")
    
    safe_log("info", "Self-test complete")
    return summary


def find_backrest_drive() -> Optional[str]:
    """Scan block devices to identify drive containing partitions labeled LOGS_CFG and IMGSTORE."""
    global BACKREST_DRV
    
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        # Use lsblk to find devices with LOGS_CFG and IMGSTORE labels
        result = subprocess.run(
            ['lsblk', '-o', 'NAME,LABEL,PKNAME', '-J'],
            capture_output=True, text=True
        )
        
        if result.returncode != 0:
            safe_log("error", "Failed to run lsblk")
            return None
        
        # Safe JSON parsing
        try:
            devices = json.loads(result.stdout)
        except json.JSONDecodeError as e:
            safe_log("error", f"Failed to parse lsblk JSON output: {e}")
            return None
        
        # Validate JSON structure
        if not isinstance(devices, dict) or 'blockdevices' not in devices:
            safe_log("error", "Invalid JSON structure from lsblk")
            return None
        
        labels_found = {'LOGS_CFG': None, 'IMGSTORE': None}
        
        for device in devices.get('blockdevices', []):
            # Validate device structure
            if not isinstance(device, dict):
                continue
                
            if device.get('label') in labels_found:
                labels_found[device['label']] = device.get('pkname')
            
            # Check children (partitions)
            children = device.get('children', [])
            if isinstance(children, list):
                for child in children:
                    if not isinstance(child, dict):
                        continue
                    if child.get('label') in labels_found:
                        labels_found[child['label']] = device.get('name')
        
        # Check if both labels found on same drive
        if labels_found['LOGS_CFG'] and labels_found['IMGSTORE']:
            if labels_found['LOGS_CFG'] == labels_found['IMGSTORE']:
                BACKREST_DRV = f"/dev/{labels_found['LOGS_CFG']}"
                safe_log("info", f"BackRest drive identified: {BACKREST_DRV}")
                return BACKREST_DRV
        
        safe_log("warning", "Could not identify BackRest drive")
        return None
    except Exception as e:
        safe_log("error", f"Error finding BackRest drive: {e}")
        return None


def validate_restore_target(target_device: str) -> Tuple[bool, str]:
    """Check target_device is not BACKREST_DRV and is writable."""
    if not target_device:
        return False, "Target device is empty"
    
    target_path = Path(target_device)
    
    # Check if it's the BackRest drive
    if BACKREST_DRV and target_device == BACKREST_DRV:
        return False, f"Cannot restore to BackRest drive ({BACKREST_DRV})"
    
    # Check if device exists
    if not target_path.exists():
        return False, f"Target device {target_device} does not exist"
    
    # Check if writable (attempt to open for writing)
    try:
        with open(target_device, 'ab') as f:
            pass
        return True, "Target is valid"
    except PermissionError:
        return False, f"No write permission for {target_device}"
    except Exception as e:
        return False, f"Error accessing {target_device}: {e}"


def confirm_user(prompt: str, default: bool = False) -> bool:
    """Generic Y/n confirmation utility that accepts single keypress."""
    import sys
    import tty
    import termios
    
    suffix = " [Y/n]: " if default else " [y/N]: "
    print(prompt + suffix, end='', flush=True)
    
    try:
        fd = sys.stdin.fileno()
        old_settings = termios.tcgetattr(fd)
        try:
            tty.setraw(sys.stdin.fileno())
            ch = sys.stdin.read(1)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
        
        print()  # newline after input
        
        if ch.lower() == 'y':
            return True
        elif ch.lower() == 'n':
            return False
        elif ch == '\r' or ch == '\n':
            return default
        else:
            return default
    except:
        # Fallback to regular input
        response = input().strip().lower()
        if not response:
            return default
        return response in ['y', 'yes']


def keypress_menu_select(menu_items: List[Tuple], prompt: str, page_size: int = 15) -> Optional[Any]:
    """Display menu_items with single-key selection, handle pagination, Esc to cancel."""
    import sys
    import tty
    import termios
    
    total_items = len(menu_items)
    current_page = 0
    total_pages = (total_items + page_size - 1) // page_size
    
    while True:
        start_idx = current_page * page_size
        end_idx = min(start_idx + page_size, total_items)
        page_items = menu_items[start_idx:end_idx]
        
        # Display menu
        print("\n" + "=" * 60)
        print(prompt)
        print("=" * 60)
        
        for key, label, meta in page_items:
            print(f"  [{key}] {label}")
        
        if total_pages > 1:
            print(f"\n  [Space] Next page ({current_page + 1}/{total_pages})")
        print("  [Esc] Cancel\n")
        
        # Get keypress
        try:
            fd = sys.stdin.fileno()
            old_settings = termios.tcgetattr(fd)
            try:
                tty.setraw(sys.stdin.fileno())
                ch = sys.stdin.read(1)
                if ch == '\x1b':  # Escape
                    print("\nCancelled")
                    return None
            finally:
                termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
            
            # Check for space (next page)
            if ch == ' ' and total_pages > 1:
                current_page = (current_page + 1) % total_pages
                continue
            
            # Check for valid selection
            for key, label, meta in page_items:
                if ch.lower() == key.lower():
                    print(f"\nSelected: {label}")
                    return (key, label, meta)
            
            print(f"\nInvalid selection: {ch}")
        except Exception as e:
            if logger:
                logger.error(f"Error in menu selection: {e}")
            else:
                _console_log("ERROR", f"Error in menu selection: {e}")
            return None


def read_settings() -> Dict[str, Any]:
    """Read persisted settings (from /logs-cfg or $BACKREST_DIR)."""
    settings_file = LOGS_CFG_DIR / "settings.json"
    default_settings = {
        "compression_enabled": True,
        "compressor": "zstd",
        "compression_level": 3,
        "verify_on_completion": True,
        "verification_options": {
            "checksum": True,
            "compress_test": True,
            "loopback_fsck": False
        },
        "run_self_test_on_launch": False,
        "continue_on_unmet_dependency": False,
        "continue_without_network": True,
        "headless_timeout": HEADLESS_TIMEOUT,
        "play_sound_on_completion": False,
        "shutdown_on_completion": False
    }
    
    try:
        if settings_file.exists():
            with open(settings_file, 'r') as f:
                loaded = json.load(f)
                # Merge with defaults
                default_settings.update(loaded)
                if logger:
                    logger.debug("Settings loaded from file")
                else:
                    _console_log("DEBUG", "Settings loaded from file")
        else:
            if logger:
                logger.debug("Using default settings")
            else:
                _console_log("DEBUG", "Using default settings")
    except Exception as e:
        if logger:
            logger.warning(f"Error loading settings: {e}, using defaults")
        else:
            _console_log("WARNING", f"Error loading settings: {e}, using defaults")
    
    return default_settings


def write_settings(settings: Dict[str, Any]) -> bool:
    """Persist given settings to disk."""
    settings_file = LOGS_CFG_DIR / "settings.json"
    
    try:
        with open(settings_file, 'w') as f:
            json.dump(settings, f, indent=2)
        if logger:
            logger.info("Settings saved")
        else:
            _console_log("INFO", "Settings saved")
        return True
    except Exception as e:
        if logger:
            logger.error(f"Failed to save settings: {e}")
        else:
            _console_log("ERROR", f"Failed to save settings: {e}")
        return False


def human_readable_size(bytes_val: int) -> str:
    """Convert bytes to human string (MiB, GiB)."""
    for unit in ['B', 'KiB', 'MiB', 'GiB', 'TiB']:
        if bytes_val < 1024.0:
            return f"{bytes_val:.2f} {unit}"
        bytes_val /= 1024.0
    return f"{bytes_val:.2f} PiB"


# ===========================
# III. NETWORKING FUNCTIONS
# ===========================

def list_network_interfaces() -> List[Dict[str, Any]]:
    """Return list of physical interfaces and link states."""
    interfaces = []
    
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        # Use ip command to list interfaces
        result = subprocess.run(['ip', '-j', 'link', 'show'], capture_output=True, text=True)
        if result.returncode == 0:
            try:
                links = json.loads(result.stdout)
            except json.JSONDecodeError as e:
                safe_log("error", f"Failed to parse ip JSON output: {e}")
                return interfaces
            
            if isinstance(links, list):
                for link in links:
                    if not isinstance(link, dict):
                        continue
                        
                    if link.get('link_type') in ['loopback']:
                        continue
                    
                    iface_name = link.get('ifname', 'unknown')
                    link_state = 'UP' if 'UP' in link.get('flags', []) else 'DOWN'
                    
                    # Get IP address
                    ip_result = subprocess.run(
                        ['ip', '-j', 'addr', 'show', iface_name],
                        capture_output=True, text=True
                    )
                    ip_addr = None
                    if ip_result.returncode == 0:
                        try:
                            addr_info = json.loads(ip_result.stdout)
                            if isinstance(addr_info, list):
                                for addr in addr_info:
                                    if not isinstance(addr, dict):
                                        continue
                                    for addr_entry in addr.get('addr_info', []):
                                        if not isinstance(addr_entry, dict):
                                            continue
                                        if addr_entry.get('family') == 'inet':
                                            ip_addr = addr_entry.get('local')
                                            break
                        except json.JSONDecodeError:
                            pass  # Continue without IP
                    
                    interfaces.append({
                        "name": iface_name,
                        "link_state": link_state,
                        "ip": ip_addr,
                        "ssid": None  # TODO: get SSID for wireless
                    })
        
        safe_log("debug", f"Found {len(interfaces)} network interfaces")
    except Exception as e:
        safe_log("error", f"Error listing network interfaces: {e}")
    
    return interfaces


def config_network_from_cfg() -> bool:
    """If /logs-cfg/cfg/10-<hostname>.netcfg.yaml exists, apply it."""
    try:
        result = subprocess.run(['hostname'], capture_output=True, text=True)
        if result.returncode == 0:
            hostname = result.stdout.strip()
            netcfg_file = LOGS_CFG_DIR / "cfg" / f"10-{hostname}.netcfg.yaml"
            
            if not netcfg_file.exists():
                if logger:
                    logger.info(f"No network config found at {netcfg_file}")
                else:
                    _console_log("INFO", f"No network config found at {netcfg_file}")
                return False
            
            if logger:
                logger.info(f"Applying network config from {netcfg_file}")
            else:
                _console_log("INFO", f"Applying network config from {netcfg_file}")
            # TODO: Implement netplan or NetworkManager configuration application
            return True
    except Exception as e:
        if logger:
            logger.error(f"Error applying network config: {e}")
        else:
            _console_log("ERROR", f"Error applying network config: {e}")
        return False


def scan_wifi_ssids() -> List[str]:
    """Use nmcli to list SSIDs and signal strengths."""
    ssids = []
    
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        result = subprocess.run(
            ['nmcli', '-t', '-f', 'SSID,SIGNAL', 'dev', 'wifi', 'list'],
            capture_output=True, text=True
        )
        
        if result.returncode == 0:
            for line in result.stdout.strip().split('\n'):
                if line:
                    parts = line.split(':')
                    if len(parts) >= 2:
                        ssid = parts[0]
                        if ssid and ssid not in ssids:
                            ssids.append(ssid)
        
        safe_log("debug", f"Found {len(ssids)} WiFi networks")
    except FileNotFoundError:
        safe_log("warning", "nmcli not available")
    except Exception as e:
        safe_log("error", f"Error scanning WiFi: {e}")
    
    return ssids


def config_wifi_interactive() -> Dict[str, Any]:
    """Interactive WiFi configuration: show SSID menu, prompt password, attempt connect."""
    print("\n=== WiFi Configuration ===")
    
    ssids = scan_wifi_ssids()
    
    if not ssids:
        print("No WiFi networks found")
        return {"ok": False, "ssid": None, "ip": None}
    
    # Create menu items
    menu_items = [(str(i+1), ssid, ssid) for i, ssid in enumerate(ssids)]
    
    selected = keypress_menu_select(menu_items, "Select WiFi Network:", page_size=10)
    
    if not selected:
        return {"ok": False, "ssid": None, "ip": None}
    
    ssid = selected[2]
    
    # Get password
    password = input(f"Enter password for {ssid}: ").strip()
    
    # Attempt connection
    try:
        print(f"Connecting to {ssid}...")
        result = subprocess.run(
            ['nmcli', 'dev', 'wifi', 'connect', ssid, 'password', password],
            capture_output=True, text=True, timeout=30
        )
        
        if result.returncode == 0:
            print("Connected successfully!")
            # Get IP address
            time.sleep(2)
            interfaces = list_network_interfaces()
            for iface in interfaces:
                if iface.get('ip'):
                    return {"ok": True, "ssid": ssid, "ip": iface['ip']}
            return {"ok": True, "ssid": ssid, "ip": None}
        else:
            print(f"Connection failed: {result.stderr}")
            return {"ok": False, "ssid": ssid, "ip": None}
    except Exception as e:
        if logger:
            logger.error(f"Error connecting to WiFi: {e}")
        else:
            _console_log("ERROR", f"Error connecting to WiFi: {e}")
        return {"ok": False, "ssid": ssid, "ip": None}


def test_network_connectivity() -> Dict[str, bool]:
    """Validate IP existence and ping a known host (1.1.1.1)."""
    result = {"has_ip": False, "ping_ok": False}
    
    # Check for IP address
    interfaces = list_network_interfaces()
    for iface in interfaces:
        if iface.get('ip'):
            result["has_ip"] = True
            break
    
    # Test ping
    try:
        ping_result = subprocess.run(
            ['ping', '-c', '1', '-W', '2', '1.1.1.1'],
            capture_output=True, text=True, timeout=5
        )
        result["ping_ok"] = ping_result.returncode == 0
    except Exception as e:
        if logger:
            logger.error(f"Error testing connectivity: {e}")
        else:
            _console_log("ERROR", f"Error testing connectivity: {e}")
    
    if logger:
        logger.info(f"Network connectivity: has_ip={result['has_ip']}, ping_ok={result['ping_ok']}")
    else:
        _console_log("INFO", f"Network connectivity: has_ip={result['has_ip']}, ping_ok={result['ping_ok']}")
    return result


def write_netcfg_for_host(hostname: str) -> Optional[Path]:
    """Generate 10-<hostname>.netcfg.yaml into /logs-cfg/cfg to be reused."""
    try:
        cfg_dir = LOGS_CFG_DIR / "cfg"
        cfg_dir.mkdir(parents=True, exist_ok=True)
        
        netcfg_file = cfg_dir / f"10-{hostname}.netcfg.yaml"
        
        # TODO: Generate proper netplan YAML from current network state
        config_content = f"# Network configuration for {hostname}\n# Generated by BackRest\n"
        
        with open(netcfg_file, 'w') as f:
            f.write(config_content)
        
        if logger:
            logger.info(f"Network config written to {netcfg_file}")
        else:
            _console_log("INFO", f"Network config written to {netcfg_file}")
        return netcfg_file
    except Exception as e:
        if logger:
            logger.error(f"Error writing network config: {e}")
        else:
            _console_log("ERROR", f"Error writing network config: {e}")
        return None


# =====================================
# IV. DISK / INVENTORY FUNCTIONS
# =====================================

def scan_disks_and_partitions() -> List[Dict[str, Any]]:
    """Produce inventory of block devices and partitions."""
    disks = []
    
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        result = subprocess.run(
            ['lsblk', '-J', '-o', 'NAME,TYPE,SIZE,VENDOR,MODEL,FSTYPE,LABEL,MOUNTPOINT'],
            capture_output=True, text=True
        )
        
        if result.returncode != 0:
            safe_log("error", "Failed to run lsblk")
            return disks
        
        # Safe JSON parsing
        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError as e:
            safe_log("error", f"Failed to parse lsblk JSON: {e}")
            return disks
        
        # Validate JSON structure
        if not isinstance(data, dict) or 'blockdevices' not in data:
            safe_log("error", "Invalid lsblk JSON structure")
            return disks
        
        for device in data.get('blockdevices', []):
            if not isinstance(device, dict):
                continue
                
            if device.get('type') == 'disk':
                disk_info = {
                    "dev": f"/dev/{device.get('name', 'unknown')}",
                    "type": "disk",
                    "vendor": device.get('vendor', 'Unknown').strip(),
                    "model": device.get('model', 'Unknown').strip(),
                    "size": device.get('size', '0'),
                    "size_bytes": 0,  # TODO: parse size
                    "partitions": []
                }
                
                # Process partitions
                children = device.get('children', [])
                if isinstance(children, list):
                    for child in children:
                        if not isinstance(child, dict):
                            continue
                            
                        if child.get('type') == 'part':
                            partition_info = {
                                "dev": f"/dev/{child.get('name', 'unknown')}",
                                "fs": child.get('fstype', 'Unknown'),
                                "mount": child.get('mountpoint', ''),
                                "label": child.get('label', ''),
                                "size": child.get('size', '0'),
                                "size_bytes": 0,  # TODO: parse size
                                "used": 0
                            }
                            disk_info["partitions"].append(partition_info)
                
                disks.append(disk_info)
        
        safe_log("info", f"Scanned {len(disks)} disks")
    except Exception as e:
        safe_log("error", f"Error scanning disks: {e}")
    
    return disks


def save_inventory(path: Path = None) -> Tuple[bool, Optional[Path]]:
    """Save scan_disks_and_partitions() output to inventory file"""
    if path is None:
        path = LOGS_CFG_DIR / "inventory.txt"
    
    try:
        disks = scan_disks_and_partitions()
        
        with open(path, 'w') as f:
            f.write(f"BackRest Inventory - {datetime.now().isoformat()}\n")
            f.write("=" * 70 + "\n\n")
            
            for disk in disks:
                f.write(f"Device: {disk['dev']}\n")
                f.write(f"  Vendor: {disk['vendor']}\n")
                f.write(f"  Model: {disk['model']}\n")
                f.write(f"  Size: {disk['size']}\n")
                f.write(f"  Partitions: {len(disk['partitions'])}\n")
                
                for part in disk['partitions']:
                    f.write(f"\n    Partition: {part['dev']}\n")
                    f.write(f"      Filesystem: {part['fs']}\n")
                    f.write(f"      Label: {part['label']}\n")
                    f.write(f"      Size: {part['size']}\n")
                    f.write(f"      Mount: {part['mount']}\n")
                
                f.write("\n" + "-" * 70 + "\n\n")
        
        if logger:
            logger.info(f"Inventory saved to {path}")
        else:
            _console_log("INFO", f"Inventory saved to {path}")
        return True, path
    except Exception as e:
        if logger:
            logger.error(f"Error saving inventory: {e}")
        else:
            _console_log("ERROR", f"Error saving inventory: {e}")
        return False, None


def get_imgstore_images() -> List[Dict[str, Any]]:
    """List image files in IMGSTORE_DIR sorted by date/name with metadata."""
    images = []
    
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        if not IMGSTORE_DIR.exists():
            safe_log("warning", f"IMGSTORE_DIR {IMGSTORE_DIR} does not exist")
            return images
        
        # Find all image files
        for item in IMGSTORE_DIR.iterdir():
            if item.is_file() and item.suffix in ['.img', '.zst', '.gz', '.xz']:
                metadata = parse_image_metadata(item)
                images.append(metadata)
        
        # Sort by timestamp (newest first)
        images.sort(key=lambda x: x.get('timestamp', ''), reverse=True)
        
        safe_log("info", f"Found {len(images)} images in IMGSTORE")
    except Exception as e:
        safe_log("error", f"Error listing images: {e}")
    
    return images


def parse_image_metadata(image_path: Path) -> Dict[str, Any]:
    """Determine backup type (dd/partclone/boot), compression, and stored hashes"""
    metadata = {
        "path": str(image_path),
        "name": image_path.name,
        "size": image_path.stat().st_size,
        "timestamp": datetime.fromtimestamp(image_path.stat().st_mtime).isoformat(),
        "compressed": False,
        "compressor": None,
        "type": "unknown",
        "hash": None
    }
    
    # Detect compression
    if image_path.suffix == '.zst':
        metadata["compressed"] = True
        metadata["compressor"] = "zstd"
    elif image_path.suffix == '.gz':
        metadata["compressed"] = True
        metadata["compressor"] = "gzip"
    elif image_path.suffix == '.xz':
        metadata["compressed"] = True
        metadata["compressor"] = "xz"
    
    # Detect backup type from filename
    name_lower = image_path.name.lower()
    if 'boot' in name_lower:
        metadata["type"] = "boot_sector"
    elif 'partclone' in name_lower:
        metadata["type"] = "partclone"
    elif 'dd' in name_lower or 'raw' in name_lower:
        metadata["type"] = "dd_raw"
    
    return metadata


# ========================================
# V. BACKUP & RESTORE CORE FUNCTIONS
# ========================================

def backup_boot_sector(target_device: str, dest_path: Path, compress: bool = True, 
                       compressor: str = "zstd") -> Dict[str, Any]:
    """Use dd to save first 10 MiB from target_device to dest_path."""
    result = {"ok": False, "dest_path": str(dest_path), "size": 0, "checksum": None}
    
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        safe_log("info", f"Backing up boot sector from {target_device} to {dest_path}")
        
        # Build dd command (10 MiB = 10485760 bytes = 20480 blocks of 512 bytes)
        if compress:
            # Pipe through compressor
            if compressor == "zstd":
                dest_path = dest_path.with_suffix(dest_path.suffix + '.zst')
                cmd = f"dd if={target_device} bs=512 count=20480 status=progress | zstd -3 -o {dest_path}"
            else:
                cmd = f"dd if={target_device} bs=512 count=20480 status=progress > {dest_path}"
            
            subprocess.run(cmd, shell=True, check=True)
        else:
            dd_cmd = ['dd', f'if={target_device}', f'of={dest_path}', 'bs=512', 'count=20480', 
                      'status=progress']
            subprocess.run(dd_cmd, check=True)
        
        # Calculate checksum
        checksum = calculate_sha256(dest_path)
        
        result["ok"] = True
        result["dest_path"] = str(dest_path)
        result["size"] = dest_path.stat().st_size
        result["checksum"] = checksum
        
        safe_log("info", f"Boot sector backup complete: {human_readable_size(result['size'])}")
    except Exception as e:
        safe_log("error", f"Boot sector backup failed: {e}")
        result["error"] = str(e)
    
    return result


def backup_full_partclone(target_device: str, dest_path: Path, compress: bool = True,
                          partclone_opts: Dict = None) -> Dict[str, Any]:
    """Use partclone to image raw filesystem/drive to dest_path."""
    result = {"ok": False, "dest_path": str(dest_path), "size": 0, "partclone_exit_code": -1}
    
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        safe_log("info", f"Starting partclone backup of {target_device} to {dest_path}")
        
        # Detect filesystem type
        fs_result = subprocess.run(['blkid', '-o', 'value', '-s', 'TYPE', target_device],
                                  capture_output=True, text=True)
        fs_type = fs_result.stdout.strip() or 'ext4'
        
        # Build partclone command
        partclone_bin = f'partclone.{fs_type}'
        
        if compress:
            dest_path = dest_path.with_suffix(dest_path.suffix + '.zst')
            cmd = f'{partclone_bin} -c -s {target_device} | zstd -3 -o {dest_path}'
        else:
            cmd = f'{partclone_bin} -c -s {target_device} -o {dest_path}'
        
        subprocess.run(cmd, shell=True, check=True)
        
        result["ok"] = True
        result["dest_path"] = str(dest_path)
        result["size"] = dest_path.stat().st_size
        result["partclone_exit_code"] = 0
        
        safe_log("info", f"Partclone backup complete: {human_readable_size(result['size'])}")
    except Exception as e:
        safe_log("error", f"Partclone backup failed: {e}")
        result["error"] = str(e)
    
    return result


def backup_full_dd_raw(target_device: str, dest_path: Path, compress: bool = True,
                       dd_opts: Dict = None) -> Dict[str, Any]:
    """Use dd to copy entire device to dest_path."""
    result = {"ok": False, "dest_path": str(dest_path), "size": 0}
    
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        safe_log("info", f"Starting dd raw backup of {target_device} to {dest_path}")
        
        if compress:
            dest_path = dest_path.with_suffix(dest_path.suffix + '.zst')
            cmd = f'dd if={target_device} bs=4M status=progress | zstd -3 -o {dest_path}'
        else:
            cmd = f'dd if={target_device} of={dest_path} bs=4M status=progress'
        
        subprocess.run(cmd, shell=True, check=True)
        
        result["ok"] = True
        result["dest_path"] = str(dest_path)
        result["size"] = dest_path.stat().st_size
        
        safe_log("info", f"DD raw backup complete: {human_readable_size(result['size'])}")
    except Exception as e:
        safe_log("error", f"DD raw backup failed: {e}")
        result["error"] = str(e)
    
    return result


def restore_boot_sector(image_path: Path, target_device: str, 
                       decompress_ifneeded: bool = True) -> Dict[str, Any]:
    """Restore 10 MiB boot sector image using dd."""
    result = {"ok": False, "target_device": target_device}
    
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        safe_log("info", f"Restoring boot sector from {image_path} to {target_device}")
        
        # Warning
        print("\n" + "!" * 70)
        print("WARNING: This will overwrite the boot sector of", target_device)
        print("!" * 70)
        
        if not confirm_user("Are you ABSOLUTELY SURE you want to continue?", default=False):
            safe_log("info", "Boot sector restore cancelled by user")
            result["error"] = "Cancelled by user"
            return result
        
        # Decompress if needed
        if image_path.suffix == '.zst':
            cmd = f'zstd -dc {image_path} | dd of={target_device} bs=512 status=progress'
        elif image_path.suffix == '.gz':
            cmd = f'gunzip -c {image_path} | dd of={target_device} bs=512 status=progress'
        else:
            cmd = f'dd if={image_path} of={target_device} bs=512 status=progress'
        
        subprocess.run(cmd, shell=True, check=True)
        
        result["ok"] = True
        safe_log("info", "Boot sector restore complete")
    except Exception as e:
        safe_log("error", f"Boot sector restore failed: {e}")
        result["error"] = str(e)
    
    return result


def restore_partclone(image_path: Path, target_device: str,
                     decompress_ifneeded: bool = True) -> Dict[str, Any]:
    """Restore partclone image to device."""
    result = {"ok": False, "target_device": target_device}
    
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        safe_log("info", f"Restoring partclone image from {image_path} to {target_device}")
        
        # Warning
        print("\n" + "!" * 70)
        print("WARNING: This will DESTROY ALL DATA on", target_device)
        print("!" * 70)
        
        if not confirm_user("Type YES to confirm", default=False):
            safe_log("info", "Restore cancelled by user")
            result["error"] = "Cancelled by user"
            return result
        
        # Detect filesystem from metadata or filename
        # Assume ext4 for now
        partclone_bin = 'partclone.restore'
        
        if image_path.suffix == '.zst':
            cmd = f'zstd -dc {image_path} | {partclone_bin} -s - -o {target_device}'
        else:
            cmd = f'{partclone_bin} -s {image_path} -o {target_device}'
        
        subprocess.run(cmd, shell=True, check=True)
        
        result["ok"] = True
        safe_log("info", "Partclone restore complete")
    except Exception as e:
        safe_log("error", f"Partclone restore failed: {e}")
        result["error"] = str(e)
    
    return result


def restore_dd_raw(image_path: Path, target_device: str,
                   decompress_ifneeded: bool = True) -> Dict[str, Any]:
    """Restore raw dd image to device."""
    result = {"ok": False, "target_device": target_device}
    
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        safe_log("info", f"Restoring dd raw image from {image_path} to {target_device}")
        
        # Warning
        print("\n" + "!" * 70)
        print("WARNING: This will DESTROY ALL DATA on", target_device)
        print("!" * 70)
        
        if not confirm_user("Type YES to confirm", default=False):
            safe_log("info", "Restore cancelled by user")
            result["error"] = "Cancelled by user"
            return result
        
        if image_path.suffix == '.zst':
            cmd = f'zstd -dc {image_path} | dd of={target_device} bs=4M status=progress'
        elif image_path.suffix == '.gz':
            cmd = f'gunzip -c {image_path} | dd of={target_device} bs=4M status=progress'
        else:
            cmd = f'dd if={image_path} of={target_device} bs=4M status=progress'
        
        subprocess.run(cmd, shell=True, check=True)
        
        result["ok"] = True
        safe_log("info", "DD raw restore complete")
    except Exception as e:
        safe_log("error", f"DD raw restore failed: {e}")
        result["error"] = str(e)
    
    return result


def run_verification(image_path: Path, verification_options: Dict) -> Dict[str, Any]:
    """Run configured verification steps."""
    report = {"ok": True, "checks": []}
    
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        # Checksum verification
        if verification_options.get("checksum"):
            safe_log("info", "Running checksum verification...")
            checksum = calculate_sha256(image_path)
            report["checks"].append({"test": "checksum", "result": "ok", "value": checksum})
        
        # Compress test (for compressed images)
        if verification_options.get("compress_test") and image_path.suffix in ['.zst', '.gz', '.xz']:
            safe_log("info", "Testing compressed file integrity...")
            if image_path.suffix == '.zst':
                test_cmd = f'zstd -t {image_path}'
            elif image_path.suffix == '.gz':
                test_cmd = f'gunzip -t {image_path}'
            else:
                test_cmd = f'xz -t {image_path}'
            
            result = subprocess.run(test_cmd, shell=True, capture_output=True, text=True)
            test_ok = result.returncode == 0
            report["checks"].append({"test": "compress_test", "result": "ok" if test_ok else "failed"})
            if not test_ok:
                report["ok"] = False
        
        safe_log("info", f"Verification complete: {len(report['checks'])} checks performed")
    except Exception as e:
        safe_log("error", f"Verification failed: {e}")
        report["ok"] = False
        report["error"] = str(e)
    
    return report


def decompress_if_needed(image_path: Path, work_dir: Path) -> Path:
    """If image is compressed, decompress to work_dir."""
    if image_path.suffix not in ['.zst', '.gz', '.xz']:
        return image_path
    
    try:
        decompressed_path = work_dir / image_path.stem
        
        if image_path.suffix == '.zst':
            subprocess.run(f'zstd -dc {image_path} > {decompressed_path}', shell=True, check=True)
        elif image_path.suffix == '.gz':
            subprocess.run(f'gunzip -c {image_path} > {decompressed_path}', shell=True, check=True)
        elif image_path.suffix == '.xz':
            subprocess.run(f'xz -dc {image_path} > {decompressed_path}', shell=True, check=True)
        
        if logger:
            logger.info(f"Decompressed to {decompressed_path}")
        else:
            _console_log("INFO", f"Decompressed to {decompressed_path}")
        return decompressed_path
    except Exception as e:
        if logger:
            logger.error(f"Decompression failed: {e}")
        else:
            _console_log("ERROR", f"Decompression failed: {e}")
        return image_path


def create_dest_filename(prefix: str, source_device: str, backup_type: str,
                        timestamp: datetime, compressor: str = None) -> str:
    """Build a deterministic destination filename for images."""
    device_name = Path(source_device).name
    ts = timestamp.strftime("%Y%m%d-%H%M%S")
    
    filename = f"{prefix}-{ts}-{device_name}-{backup_type}.img"
    
    if compressor:
        if compressor == "zstd":
            filename += ".zst"
        elif compressor == "gzip":
            filename += ".gz"
        elif compressor == "xz":
            filename += ".xz"
    
    return filename


def calculate_sha256(file_path: Path) -> str:
    """Calculate SHA256 hash of a file."""
    sha256 = hashlib.sha256()
    
    with open(file_path, 'rb') as f:
        for chunk in iter(lambda: f.read(8192), b''):
            sha256.update(chunk)
    
    return sha256.hexdigest()


# ===================================
# VI. UI / INTERACTIVE FUNCTIONS
# ===================================

def main_menu():
    """Top-level interactive menu with keys [B] Backup, [R] Restore, [S] Settings, [X] Exit."""
    settings = runtime_state.get("settings", read_settings())
    
    while True:
        print("\n" + "=" * 60)
        print("BackRest - Main Menu")
        print("=" * 60)
        print("  [B] Backup")
        print("  [R] Restore")
        print("  [S] Settings")
        print("  [T] Self-Test")
        print("  [I] Inventory")
        print("  [X] Exit")
        print()
        
        choice = input("Select an option: ").strip().upper()
        
        if choice == 'B':
            backup_workflow()
        elif choice == 'R':
            restore_workflow()
        elif choice == 'S':
            settings_menu()
        elif choice == 'T':
            self_test()
        elif choice == 'I':
            inventory_workflow()
        elif choice == 'X':
            shutdown_sequence("user exit")
            break
        else:
            print("Invalid selection")


def drive_partition_menu(action: str = 'backup') -> Optional[Dict]:
    """Display disks and partitions, allow selection."""
    disks = scan_disks_and_partitions()
    
    if not disks:
        print("No disks found")
        return None
    
    # Build menu items
    menu_items = []
    for disk in disks:
        menu_items.append((disk['dev'], f"[DISK] {disk['dev']} - {disk['vendor']} {disk['model']} ({disk['size']})", disk))
        for part in disk['partitions']:
            menu_items.append((part['dev'], f"  [PART] {part['dev']} - {part['fs']} {part['label']} ({part['size']})", part))
    
    # Simplify for text menu
    print(f"\n=== Select Device for {action.capitalize()} ===")
    for i, (dev, label, meta) in enumerate(menu_items, 1):
        print(f"  [{i}] {label}")
    print("  [0] Cancel")
    
    choice = input("\nSelect device number: ").strip()
    
    if choice == '0':
        return None
    
    try:
        idx = int(choice) - 1
        if 0 <= idx < len(menu_items):
            return menu_items[idx][2]
    except:
        pass
    
    print("Invalid selection")
    return None


def backup_menu_for_selection(device_dict: Dict) -> Optional[str]:
    """Offer backup options based on device type."""
    print(f"\n=== Backup Options for {device_dict['dev']} ===")
    
    if device_dict.get('type') == 'disk':
        print("  [B] Boot Sector Only (10 MiB)")
        print("  [P] Full Drive (Partclone)")
        print("  [R] Full Drive (Raw DD)")
    else:
        print("  [P] Partition (Partclone)")
        print("  [R] Partition (Raw DD)")
    
    print("  [C] Cancel")
    
    choice = input("\nSelect backup type: ").strip().upper()
    
    if choice == 'B' and device_dict.get('type') == 'disk':
        return 'boot_sector'
    elif choice == 'P':
        return 'partclone'
    elif choice == 'R':
        return 'dd_raw'
    elif choice == 'C':
        return None
    
    print("Invalid selection")
    return None


def confirm_and_run_backup(selected_device: Dict, backup_type: str, options: Dict) -> Dict:
    """Validate, confirm, and execute backup operation."""
    settings = runtime_state.get("settings", read_settings())
    
    # Build destination filename
    timestamp = datetime.now()
    prefix = "backup"
    compressor = settings.get("compressor", "zstd") if settings.get("compression_enabled") else None
    
    filename = create_dest_filename(prefix, selected_device['dev'], backup_type, timestamp, compressor)
    dest_path = IMGSTORE_DIR / filename
    
    # Display summary
    print("\n" + "=" * 70)
    print("Backup Summary:")
    print(f"  Source: {selected_device['dev']}")
    print(f"  Type: {backup_type}")
    print(f"  Destination: {dest_path}")
    print(f"  Compression: {compressor or 'None'}")
    print("=" * 70)
    
    if not confirm_user("\nProceed with backup?", default=False):
        if logger:
            logger.info("Backup cancelled by user")
        else:
            _console_log("INFO", "Backup cancelled by user")
        return {"ok": False, "error": "Cancelled by user"}
    
    # Execute backup
    result = {}
    try:
        if backup_type == 'boot_sector':
            result = backup_boot_sector(selected_device['dev'], dest_path, 
                                       compress=settings.get("compression_enabled", True),
                                       compressor=compressor)
        elif backup_type == 'partclone':
            result = backup_full_partclone(selected_device['dev'], dest_path,
                                          compress=settings.get("compression_enabled", True))
        elif backup_type == 'dd_raw':
            result = backup_full_dd_raw(selected_device['dev'], dest_path,
                                       compress=settings.get("compression_enabled", True))
        
        # Verification
        if result.get("ok") and settings.get("verify_on_completion"):
            print("\nRunning verification...")
            verify_result = run_verification(Path(result["dest_path"]), 
                                           settings.get("verification_options", {}))
            result["verification"] = verify_result
        
        # Post-actions
        if result.get("ok"):
            if settings.get("play_sound_on_completion"):
                play_sound()
            
            if settings.get("shutdown_on_completion"):
                shutdown_sequence("backup complete")
        
        archive_lastrun_log()
    except Exception as e:
        if logger:
            logger.error(f"Backup failed: {e}")
        else:
            _console_log("ERROR", f"Backup failed: {e}")
        result = {"ok": False, "error": str(e)}
    
    return result


def backup_workflow():
    """Complete backup workflow."""
    print("\n=== Backup Workflow ===")
    
    # Select device
    selected_device = drive_partition_menu(action='backup')
    if not selected_device:
        return
    
    # Select backup type
    backup_type = backup_menu_for_selection(selected_device)
    if not backup_type:
        return
    
    # Execute
    result = confirm_and_run_backup(selected_device, backup_type, {})
    
    if result.get("ok"):
        print("\n✓ Backup completed successfully!")
    else:
        print(f"\n✗ Backup failed: {result.get('error', 'Unknown error')}")


def images_menu() -> Optional[Dict]:
    """Show paginated list of images with selection."""
    images = get_imgstore_images()
    
    if not images:
        print("No images found in IMGSTORE")
        return None
    
    print("\n=== Available Images ===")
    for i, img in enumerate(images, 1):
        print(f"  [{i}] {img['name']} - {human_readable_size(img['size'])} - {img['type']}")
    print("  [0] Cancel")
    
    choice = input("\nSelect image number: ").strip()
    
    if choice == '0':
        return None
    
    try:
        idx = int(choice) - 1
        if 0 <= idx < len(images):
            return images[idx]
    except:
        pass
    
    print("Invalid selection")
    return None


def restore_menu_for_image(image_meta: Dict) -> Optional[str]:
    """Offer restore options based on image type."""
    print(f"\n=== Restore Options for {image_meta['name']} ===")
    print(f"  Type: {image_meta['type']}")
    print(f"  Size: {human_readable_size(image_meta['size'])}")
    print()
    
    if image_meta['type'] == 'boot_sector':
        print("  [B] Restore Boot Sector")
    elif image_meta['type'] == 'partclone':
        print("  [P] Restore with Partclone")
    elif image_meta['type'] == 'dd_raw':
        print("  [R] Restore with DD")
    else:
        print("  [R] Restore (Auto-detect)")
    
    print("  [C] Cancel")
    
    choice = input("\nSelect restore method: ").strip().upper()
    
    if choice == 'B' and image_meta['type'] == 'boot_sector':
        return 'boot_sector'
    elif choice == 'P':
        return 'partclone'
    elif choice == 'R':
        return 'dd_raw'
    elif choice == 'C':
        return None
    
    print("Invalid selection")
    return None


def confirm_and_run_restore(image_meta: Dict, target_device: str, restore_type: str, options: Dict) -> Dict:
    """Validate and execute restore operation."""
    settings = runtime_state.get("settings", read_settings())
    
    # Safety checks
    valid, reason = validate_restore_target(target_device)
    if not valid:
        if logger:
            logger.error(f"Invalid restore target: {reason}")
        else:
            _console_log("ERROR", f"Invalid restore target: {reason}")
        return {"ok": False, "error": reason}
    
    if not confirm_not_backrest_imgstore_target(target_device):
        return {"ok": False, "error": "Cannot restore to BackRest drive"}
    
    # Display warning
    print("\n" + "!" * 70)
    print("WARNING: DESTRUCTIVE OPERATION")
    print(f"  Image: {image_meta['name']}")
    print(f"  Target: {target_device}")
    print(f"  Type: {restore_type}")
    print("  ALL DATA ON TARGET WILL BE DESTROYED!")
    print("!" * 70)
    
    if not confirm_user("\nType YES to confirm", default=False):
        if logger:
            logger.info("Restore cancelled by user")
        else:
            _console_log("INFO", "Restore cancelled by user")
        return {"ok": False, "error": "Cancelled by user"}
    
    # Double confirmation
    if not confirm_user("Are you ABSOLUTELY SURE?", default=False):
        if logger:
            logger.info("Restore cancelled by user")
        else:
            _console_log("INFO", "Restore cancelled by user")
        return {"ok": False, "error": "Cancelled by user"}
    
    # Execute restore
    result = {}
    try:
        image_path = Path(image_meta['path'])
        
        if restore_type == 'boot_sector':
            result = restore_boot_sector(image_path, target_device)
        elif restore_type == 'partclone':
            result = restore_partclone(image_path, target_device)
        elif restore_type == 'dd_raw':
            result = restore_dd_raw(image_path, target_device)
        
        # Post-actions
        if result.get("ok"):
            if settings.get("play_sound_on_completion"):
                play_sound()
            
            if settings.get("shutdown_on_completion"):
                shutdown_sequence("restore complete")
        
        archive_lastrun_log()
    except Exception as e:
        if logger:
            logger.error(f"Restore failed: {e}")
        else:
            _console_log("ERROR", f"Restore failed: {e}")
        result = {"ok": False, "error": str(e)}
    
    return result


def restore_workflow():
    """Complete restore workflow."""
    print("\n=== Restore Workflow ===")
    
    # Select image
    image_meta = images_menu()
    if not image_meta:
        return
    
    # Select target device
    target_device_dict = drive_partition_menu(action='restore')
    if not target_device_dict:
        return
    
    target_device = target_device_dict['dev']
    
    # Select restore method
    restore_type = restore_menu_for_image(image_meta)
    if not restore_type:
        return
    
    # Execute
    result = confirm_and_run_restore(image_meta, target_device, restore_type, {})
    
    if result.get("ok"):
        print("\n✓ Restore completed successfully!")
    else:
        print(f"\n✗ Restore failed: {result.get('error', 'Unknown error')}")


def settings_menu():
    """Interactive settings editor."""
    settings = read_settings()
    
    while True:
        print("\n" + "=" * 60)
        print("Settings Menu")
        print("=" * 60)
        print(f"  [1] Compression: {settings['compression_enabled']} ({settings['compressor']})")
        print(f"  [2] Verify on Completion: {settings['verify_on_completion']}")
        print(f"  [3] Self-Test on Launch: {settings['run_self_test_on_launch']}")
        print(f"  [4] Continue on Unmet Dependency: {settings['continue_on_unmet_dependency']}")
        print(f"  [5] Headless Timeout: {settings['headless_timeout']}s")
        print(f"  [6] Play Sound on Completion: {settings['play_sound_on_completion']}")
        print(f"  [7] Shutdown on Completion: {settings['shutdown_on_completion']}")
        print("  [S] Save Settings")
        print("  [X] Exit")
        
        choice = input("\nSelect option: ").strip().upper()
        
        if choice == '1':
            settings['compression_enabled'] = not settings['compression_enabled']
        elif choice == '2':
            settings['verify_on_completion'] = not settings['verify_on_completion']
        elif choice == '3':
            settings['run_self_test_on_launch'] = not settings['run_self_test_on_launch']
        elif choice == '4':
            settings['continue_on_unmet_dependency'] = not settings['continue_on_unmet_dependency']
        elif choice == '5':
            timeout = input("Enter headless timeout (seconds): ").strip()
            try:
                settings['headless_timeout'] = int(timeout)
            except:
                print("Invalid value")
        elif choice == '6':
            settings['play_sound_on_completion'] = not settings['play_sound_on_completion']
        elif choice == '7':
            settings['shutdown_on_completion'] = not settings['shutdown_on_completion']
        elif choice == 'S':
            if write_settings(settings):
                print("Settings saved successfully")
                runtime_state["settings"] = settings
            else:
                print("Failed to save settings")
        elif choice == 'X':
            break


def inventory_workflow():
    """Display and save inventory."""
    print("\n=== System Inventory ===")
    disks = scan_disks_and_partitions()
    
    for disk in disks:
        print(f"\nDevice: {disk['dev']}")
        print(f"  Vendor: {disk['vendor']}")
        print(f"  Model: {disk['model']}")
        print(f"  Size: {disk['size']}")
        
        for part in disk['partitions']:
            print(f"\n    Partition: {part['dev']}")
            print(f"      Filesystem: {part['fs']}")
            print(f"      Label: {part['label']}")
            print(f"      Size: {part['size']}")
            print(f"      Mount: {part['mount']}")
    
    if confirm_user("\nSave inventory to file?", default=True):
        success, path = save_inventory()
        if success:
            print(f"Inventory saved to {path}")


def shutdown_sequence(reason: str):
    """Optionally play sound, flush logs, archive logs, and shutdown."""
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    safe_log("info", f"Shutdown sequence initiated: {reason}")
    
    settings = runtime_state.get("settings", read_settings())
    
    # Archive logs
    archive_lastrun_log()
    
    # Play sound
    if settings.get("play_sound_on_completion"):
        play_sound()
    
    # Shutdown system
    if settings.get("shutdown_on_completion"):
        print("\nSystem will shutdown in 5 seconds...")
        time.sleep(5)
        subprocess.run(['shutdown', '-h', 'now'])
    else:
        print(f"\nExiting: {reason}")


def display_message(message: str, duration: int = None):
    """Generic UI message."""
    print(f"\n{message}")
    if duration:
        time.sleep(duration)


def play_sound():
    """Play completion sound."""
    try:
        subprocess.run(['beep', '-f', '1000', '-l', '200'])
    except:
        print("\a")  # Terminal bell


# ========================================
# VII. HEADLESS / AUTOMATION FUNCTIONS
# ========================================

def headless_entrypoint(timeout: int = HEADLESS_TIMEOUT):
    """Wait for timeout; if no keypress, transition to headless_run()."""
    import select
    
    print(f"\nPress any key within {timeout} seconds to enter interactive mode...")
    print("(or wait for headless mode)")
    
    # Check for keypress with timeout
    ready, _, _ = select.select([sys.stdin], [], [], timeout)
    
    if ready:
        # Key was pressed, stay in interactive mode
        sys.stdin.read(1)  # consume the keypress
        return False
    else:
        # Timeout reached, enter headless mode
        if logger:
            logger.info("Entering headless mode")
        else:
            _console_log("INFO", "Entering headless mode")
        return True


def headless_run(cfg_path: Path = HEADLESS_CFG_PATH) -> Dict[str, Any]:
    """Main headless execution: read config, perform actions."""
    summary = {
        "started": datetime.now().isoformat(),
        "actions": [],
        "return_code": 0
    }
    
    # Safe logging function
    def safe_log(level, message):
        if logger:
            getattr(logger, level.lower())(message)
        else:
            _console_log(level.upper(), message)
    
    try:
        safe_log("info", "Beginning headless run")
        
        # Read configuration
        cfg = read_headless_cfg(cfg_path)
        
        if not cfg:
            safe_log("error", "headless.cfg not found. Aborting headless operation.")
            summary["return_code"] = 1
            archive_lastrun_log()
            return summary
        
        settings = runtime_state.get("settings", read_settings())
        
        # Find backrest drive for safety
        find_backrest_drive()
        
        # Network setup (if needed)
        if cfg.get("network_required", False):
            net_result = config_network_from_cfg()
            if not net_result:
                connectivity = test_network_connectivity()
                if not connectivity["ping_ok"] and not settings.get("continue_without_network"):
                    safe_log("error", "Network required but not available")
                    summary["return_code"] = 2
                    cleanup_headless(cfg_path)
                    return summary
        
        # Execute actions
        if cfg.get("get_info"):
            result = headless_get_info()
            summary["actions"].append({"action": "get_info", "result": result})
        
        if cfg.get("backups"):
            backup_results = headless_backup_sequence(cfg, settings)
            summary["actions"].append({"action": "backups", "results": backup_results})
        
        if cfg.get("restores"):
            restore_results = headless_restore_sequence(cfg, settings)
            summary["actions"].append({"action": "restores", "results": restore_results})
        
        # Cleanup
        cleanup_headless(cfg_path)
        archive_lastrun_log()
        
        # Optional shutdown
        if cfg.get("shutdown_after", False):
            shutdown_sequence("headless complete")
        
        safe_log("info", "Headless run complete")
    except Exception as e:
        safe_log("error", f"Headless run failed: {e}")
        summary["return_code"] = 1
        summary["error"] = str(e)
        cleanup_headless(cfg_path)
        archive_lastrun_log()
    
    return summary


def read_headless_cfg(cfg_path: Path) -> Optional[Dict]:
    """Parse headless.cfg into a structured dict."""
    try:
        if not cfg_path.exists():
            if logger:
                logger.error(f"Headless config not found: {cfg_path}")
            else:
                _console_log("ERROR", f"Headless config not found: {cfg_path}")
            return None
        
        with open(cfg_path, 'r') as f:
            cfg = json.load(f)
        
        if logger:
            logger.info("Headless config loaded")
        else:
            _console_log("INFO", "Headless config loaded")
        return cfg
    except Exception as e:
        if logger:
            logger.error(f"Error reading headless config: {e}")
        else:
            _console_log("ERROR", f"Error reading headless config: {e}")
        return None


def headless_get_info(save_path: Path = None) -> str:
    """On-boot inventory collection."""
    if save_path is None:
        save_path = LOGS_CFG_DIR / "inventory.txt"
    
    if logger:
        logger.info("Collecting system inventory")
    else:
        _console_log("INFO", "Collecting system inventory")
    success, path = save_inventory(save_path)
    
    if success:
        if logger:
            logger.info(f"Inventory saved to {path}")
        else:
            _console_log("INFO", f"Inventory saved to {path}")
        return str(path)
    else:
        if logger:
            logger.error("Failed to save inventory")
        else:
            _console_log("ERROR", "Failed to save inventory")
        return None


def headless_backup_sequence(cfg: Dict, settings: Dict) -> List[Dict]:
    """Evaluate cfg and perform configured backups."""
    results = []
    
    backups = cfg.get("backups", [])
    if logger:
        logger.info(f"Processing {len(backups)} backup tasks")
    else:
        _console_log("INFO", f"Processing {len(backups)} backup tasks")
    
    for backup_task in backups:
        try:
            target_device = backup_task.get("device")
            backup_type = backup_task.get("type", "partclone")
            
            if logger:
                logger.info(f"Backing up {target_device} as {backup_type}")
            else:
                _console_log("INFO", f"Backing up {target_device} as {backup_type}")
            
            # Build destination
            timestamp = datetime.now()
            prefix = backup_task.get("prefix", "headless")
            compressor = settings.get("compressor") if settings.get("compression_enabled") else None
            
            filename = create_dest_filename(prefix, target_device, backup_type, timestamp, compressor)
            dest_path = IMGSTORE_DIR / filename
            
            # Execute backup
            if backup_type == 'boot_sector':
                result = backup_boot_sector(target_device, dest_path,
                                           compress=settings.get("compression_enabled", True),
                                           compressor=compressor)
            elif backup_type == 'partclone':
                result = backup_full_partclone(target_device, dest_path,
                                              compress=settings.get("compression_enabled", True))
            elif backup_type == 'dd_raw':
                result = backup_full_dd_raw(target_device, dest_path,
                                           compress=settings.get("compression_enabled", True))
            else:
                result = {"ok": False, "error": f"Unknown backup type: {backup_type}"}
            
            # Verification
            if result.get("ok") and settings.get("verify_on_completion"):
                verify_result = run_verification(Path(result["dest_path"]),
                                               settings.get("verification_options", {}))
                result["verification"] = verify_result
            
            results.append(result)
        except Exception as e:
            if logger:
                logger.error(f"Backup task failed: {e}")
            else:
                _console_log("ERROR", f"Backup task failed: {e}")
            results.append({"ok": False, "error": str(e), "device": backup_task.get("device")})
    
    return results


def headless_restore_sequence(cfg: Dict, settings: Dict) -> List[Dict]:
    """Evaluate cfg and perform configured restores."""
    results = []
    
    restores = cfg.get("restores", [])
    if logger:
        logger.info(f"Processing {len(restores)} restore tasks")
    else:
        _console_log("INFO", f"Processing {len(restores)} restore tasks")
    
    for restore_task in restores:
        try:
            image_pattern = restore_task.get("image")
            target_device = restore_task.get("target_device")
            restore_type = restore_task.get("type", "partclone")
            
            if logger:
                logger.info(f"Restoring {image_pattern} to {target_device}")
            else:
                _console_log("INFO", f"Restoring {image_pattern} to {target_device}")
            
            # Safety check
            if not confirm_not_backrest_imgstore_target(target_device):
                if logger:
                    logger.error(f"Cannot restore to BackRest drive: {target_device}")
                else:
                    _console_log("ERROR", f"Cannot restore to BackRest drive: {target_device}")
                results.append({"ok": False, "error": "Target is BackRest drive", "target": target_device})
                continue
            
            # Find image
            images = get_imgstore_images()
            matching_image = None
            for img in images:
                if image_pattern in img['name']:
                    matching_image = img
                    break
            
            if not matching_image:
                if logger:
                    logger.error(f"Image not found: {image_pattern}")
                else:
                    _console_log("ERROR", f"Image not found: {image_pattern}")
                results.append({"ok": False, "error": "Image not found", "pattern": image_pattern})
                continue
            
            image_path = Path(matching_image['path'])
            
            # Execute restore
            if restore_type == 'boot_sector':
                result = restore_boot_sector(image_path, target_device)
            elif restore_type == 'partclone':
                result = restore_partclone(image_path, target_device)
            elif restore_type == 'dd_raw':
                result = restore_dd_raw(image_path, target_device)
            else:
                result = {"ok": False, "error": f"Unknown restore type: {restore_type}"}
            
            results.append(result)
        except Exception as e:
            if logger:
                logger.error(f"Restore task failed: {e}")
            else:
                _console_log("ERROR", f"Restore task failed: {e}")
            results.append({"ok": False, "error": str(e), "target": restore_task.get("target_device")})
    
    return results


def cleanup_headless(cfg_path: Path) -> bool:
    """Delete headless.cfg file."""
    try:
        if cfg_path.exists():
            cfg_path.unlink()
            if logger:
                logger.info(f"Deleted headless config: {cfg_path}")
            else:
                _console_log("INFO", f"Deleted headless config: {cfg_path}")
            return True
        return False
    except Exception as e:
        if logger:
            logger.error(f"Error deleting headless config: {e}")
        else:
            _console_log("ERROR", f"Error deleting headless config: {e}")
        return False


# ===========================
# VIII. HELPERS & SAFETY
# ===========================

def require_root_or_user(user: str = "backrest") -> bool:
    """Ensure the script is executed as the backrest user (or root)."""
    import pwd
    
    current_user = pwd.getpwuid(os.getuid()).pw_name
    
    if current_user == 'root' or current_user == user:
        if logger:
            logger.info(f"Running as user: {current_user}")
        else:
            _console_log("INFO", f"Running as user: {current_user}")
        return True
    else:
        if logger:
            logger.error(f"Must run as root or {user}, currently: {current_user}")
        else:
            _console_log("ERROR", f"Must run as root or {user}, currently: {current_user}")
        print(f"Error: This script must be run as root or {user}")
        return False


def confirm_not_backrest_imgstore_target(target_device: str) -> bool:
    """Ensure that target_device is not BACKREST_DRV."""
    if BACKREST_DRV and target_device == BACKREST_DRV:
        if logger:
            logger.error(f"Target device {target_device} is the BackRest drive!")
        else:
            _console_log("ERROR", f"Target device {target_device} is the BackRest drive!")
        print(f"\nERROR: Cannot restore to BackRest drive ({BACKREST_DRV})")
        return False
    return True


def handle_signals_and_cleanup():
    """Install signal handlers (SIGINT, SIGTERM)."""
    def signal_handler(signum, frame):
        # Safe logging function
        def safe_log(level, message):
            if logger:
                getattr(logger, level.lower())(message)
            else:
                _console_log(level.upper(), message)
        
        safe_log("warning", f"Received signal {signum}, cleaning up...")
        archive_lastrun_log()
        sys.exit(1)
    
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    if logger:
        logger.debug("Signal handlers installed")
    else:
        _console_log("DEBUG", "Signal handlers installed")


# ===========================
# IX. MAIN ENTRY POINT
# ===========================

def main():
    """Main entry point for BackRest."""
    global logger, runtime_state
    
    print("=" * 70)
    print("BackRest - Backup and Restore Utility")
    print("=" * 70)
    
    # Check user
    if not require_root_or_user(USER):
        sys.exit(1)
    
    # Initialize environment
    try:
        runtime_state = init_environment()
        logger = runtime_state.get("logger") or setup_logging()
    except Exception as e:
        print(f"Failed to initialize environment: {e}")
        sys.exit(1)
    
    # Check mounts
    if not check_mounts():
        display_message("ERROR: Required mounts are not available. Cannot continue.")
        sys.exit(1)
    
    # Read settings
    settings = read_settings()
    runtime_state["settings"] = settings
    
    # Find BackRest drive
    find_backrest_drive()
    
    # Check dependencies
    if settings.get("run_self_test_on_launch"):
        self_test()
    else:
        deps_ok, missing = check_dependencies(continue_on_unmet=settings.get("continue_on_unmet_dependency", False))
        if not deps_ok and not settings.get("continue_on_unmet_dependency"):
            display_message(f"ERROR: Missing dependencies: {', '.join(missing)}")
            sys.exit(1)
    
    # Install signal handlers
    handle_signals_and_cleanup()
    
    # Check for headless mode
    if HEADLESS_CFG_PATH.exists():
        if logger:
            logger.info("Headless config detected")
        else:
            _console_log("INFO", "Headless config detected")
        # Enter headless mode immediately
        headless_run(HEADLESS_CFG_PATH)
        sys.exit(0)
    
    # Check for headless timeout (with keypress check)
    should_run_headless = headless_entrypoint(timeout=settings.get("headless_timeout", HEADLESS_TIMEOUT))
    
    if should_run_headless:
        # Timeout reached without keypress
        if HEADLESS_CFG_PATH.exists():
            headless_run(HEADLESS_CFG_PATH)
        else:
            if logger:
                logger.info("No headless config found, entering interactive mode")
            else:
                _console_log("INFO", "No headless config found, entering interactive mode")
            main_menu()
    else:
        # User pressed key, enter interactive mode
        if logger:
            logger.info("Entering interactive mode")
        else:
            _console_log("INFO", "Entering interactive mode")
        main_menu()
    
    # Cleanup
    archive_lastrun_log()
    if logger:
        logger.info("BackRest exiting")
    else:
        _console_log("INFO", "BackRest exiting")


if __name__ == "__main__":
    main()
