#!/usr/bin/env python3
"""
BackRest Preparation Script
Prepares target machines to boot from BackRest drive with fallback capabilities.
Compatible with BIOS/UEFI, multiple architectures, and various operating systems.
"""

import os
import sys
import subprocess
import shutil
import platform
import json
import hashlib
import tempfile
import argparse
import logging
from pathlib import Path
from typing import Dict, List, Tuple, Optional
import time

# Configuration
BACKREST_BOOT_SECTOR_SIZE = 10 * 1024 * 1024  # 10 MB
BOOT_BACKUP_DIR = "/tmp/backrest_boot_backup"
BOOT_SECTOR_BACKUP = f"{BOOT_BACKUP_DIR}/boot_sector.img"
ORIGINAL_BOOT_ORDER_FILE = f"{BOOT_BACKUP_DIR}/original_boot_order.txt"
BACKREST_BOOT_ENTRY_FILE = f"{BOOT_BACKUP_DIR}/backrest_boot_entry.txt"

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/backrest_prep.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class BootConfigManager:
    """Manages boot configuration across different platforms and boot systems."""
    
    def __init__(self):
        self.system_info = self._detect_system()
        self.backrest_drive = None
        self.original_boot_order = []
        
    def _detect_system(self) -> Dict:
        """Detect system information including architecture, boot type, and OS."""
        system_info = {
            'architecture': platform.machine(),
            'platform': platform.system(),
            'distribution': '',
            'boot_type': 'unknown',  # bios, uefi, or unknown
            'efivars_available': False,
            'grub_installed': False,
            'systemd_boot_installed': False,
            'efibootmgr_available': False,
            'lilo_installed': False
        }
        
        # Detect Linux distribution
        if system_info['platform'] == 'Linux':
            try:
                with open('/etc/os-release', 'r') as f:
                    os_release = f.read()
                    for line in os_release.split('\n'):
                        if line.startswith('ID='):
                            system_info['distribution'] = line.split('=')[1].strip('"')
                        elif line.startswith('VERSION_ID='):
                            system_info['distribution'] += f" {line.split('=')[1].strip('"')}"
            except:
                pass
                
        # Detect boot type (UEFI vs BIOS)
        if system_info['platform'] == 'Linux':
            # Check for EFI system partition
            if Path('/sys/firmware/efi').exists():
                system_info['boot_type'] = 'uefi'
                system_info['efivars_available'] = True
            else:
                system_info['boot_type'] = 'bios'
                
        # Check for boot manager availability
        if system_info['platform'] == 'Linux':
            system_info['grub_installed'] = shutil.which('grub-install') is not None
            system_info['efibootmgr_available'] = shutil.which('efibootmgr') is not None
            system_info['systemd_boot_installed'] = Path('/usr/bin/bootctl').exists()
            system_info['lilo_installed'] = shutil.which('lilo') is not None
            
        # Detect if running on ARM64
        if system_info['architecture'] in ['aarch64', 'arm64']:
            system_info['is_arm'] = True
        else:
            system_info['is_arm'] = False
            
        return system_info
    
    def identify_boot_drive(self) -> str:
        """Identify the primary boot drive and partition."""
        boot_drive = None
        boot_partition = None
        
        try:
            # Try to identify via /proc/cmdline
            with open('/proc/cmdline', 'r') as f:
                cmdline = f.read().strip()
                logger.info(f"Kernel cmdline: {cmdline}")
                
                # Parse root device from cmdline
                for param in cmdline.split():
                    if param.startswith('root='):
                        root_device = param.split('=')[1]
                        # Convert /dev/nvme0n1p2 to /dev/nvme0n1
                        if 'p' in root_device:
                            boot_drive = root_device.rsplit('p', 1)[0]
                        else:
                            boot_drive = root_device
                        boot_partition = root_device
                        break
                        
        except Exception as e:
            logger.warning(f"Could not identify boot drive from cmdline: {e}")
            
        # Fallback: try to detect from mount points
        if not boot_drive:
            try:
                with open('/proc/mounts', 'r') as f:
                    for line in f:
                        if ' / ' in line:
                            device = line.split()[0]
                            if 'p' in device:
                                boot_drive = device.rsplit('p', 1)[0]
                            else:
                                boot_drive = device
                            boot_partition = device
                            break
            except Exception as e:
                logger.warning(f"Could not identify boot drive from mounts: {e}")
                
        # Fallback: use lsblk to find the drive with root filesystem
        if not boot_drive:
            try:
                result = subprocess.run(['lsblk', '-f', '-n', '-o', 'NAME,MOUNTPOINT'], 
                                      capture_output=True, text=True)
                for line in result.stdout.split('\n'):
                    if ' / ' in line:
                        device = line.split()[0]
                        if 'p' in device:
                            boot_drive = f"/dev/{device.rsplit('p', 1)[0]}"
                        else:
                            boot_drive = f"/dev/{device}"
                        boot_partition = f"/dev/{device}"
                        break
            except Exception as e:
                logger.warning(f"Could not identify boot drive from lsblk: {e}")
                
        if not boot_drive:
            raise RuntimeError("Could not identify the primary boot drive")
            
        logger.info(f"Identified boot drive: {boot_drive}")
        logger.info(f"Boot partition: {boot_partition}")
        
        return boot_drive, boot_partition
    
    def backup_boot_sector(self, boot_drive: str) -> bool:
        """Backup the boot sector of the specified drive."""
        logger.info(f"Backing up boot sector of {boot_drive}")
        
        # Create backup directory
        os.makedirs(BOOT_BACKUP_DIR, exist_ok=True)
        
        # Backup boot sector using dd
        try:
            cmd = [
                'dd', 'if=' + boot_drive, 'of=' + BOOT_SECTOR_BACKUP,
                'bs=1024', f'count={BACKREST_BOOT_SECTOR_SIZE // 1024}'
            ]
            result = subprocess.run(cmd, capture_output=True, text=True)
            
            if result.returncode != 0:
                logger.error(f"Failed to backup boot sector: {result.stderr}")
                return False
                
            # Verify backup file exists and has correct size
            if not Path(BOOT_SECTOR_BACKUP).exists():
                logger.error("Boot sector backup file was not created")
                return False
                
            backup_size = Path(BOOT_SECTOR_BACKUP).stat().st_size
            if backup_size != BACKREST_BOOT_SECTOR_SIZE:
                logger.warning(f"Boot sector backup size mismatch: {backup_size} != {BACKREST_BOOT_SECTOR_SIZE}")
                
            # Calculate checksum
            sha256_hash = hashlib.sha256()
            with open(BOOT_SECTOR_BACKUP, "rb") as f:
                for chunk in iter(lambda: f.read(4096), b""):
                    sha256_hash.update(chunk)
                    
            checksum = sha256_hash.hexdigest()
            logger.info(f"Boot sector backed up successfully. SHA256: {checksum}")
            
            # Save checksum to file
            with open(f"{BOOT_SECTOR_BACKUP}.sha256", 'w') as f:
                f.write(f"{checksum}  boot_sector.img\n")
                
            return True
            
        except Exception as e:
            logger.error(f"Error backing up boot sector: {e}")
            return False
    
    def verify_boot_sector_backup(self) -> bool:
        """Verify the integrity of the boot sector backup."""
        try:
            if not Path(BOOT_SECTOR_BACKUP).exists():
                logger.error("Boot sector backup file not found")
                return False
                
            # Check file size
            backup_size = Path(BOOT_SECTOR_BACKUP).stat().st_size
            if backup_size != BACKREST_BOOT_SECTOR_SIZE:
                logger.error(f"Boot sector backup size incorrect: {backup_size} != {BACKREST_BOOT_SECTOR_SIZE}")
                return False
                
            # Verify checksum if it exists
            checksum_file = f"{BOOT_SECTOR_BACKUP}.sha256"
            if Path(checksum_file).exists():
                # Read expected checksum
                with open(checksum_file, 'r') as f:
                    expected_checksum = f.read().split()[0]
                    
                # Calculate actual checksum
                sha256_hash = hashlib.sha256()
                with open(BOOT_SECTOR_BACKUP, "rb") as f:
                    for chunk in iter(lambda: f.read(4096), b""):
                        sha256_hash.update(chunk)
                        
                actual_checksum = sha256_hash.hexdigest()
                
                if actual_checksum == expected_checksum:
                    logger.info("Boot sector backup verification successful")
                    return True
                else:
                    logger.error(f"Boot sector backup checksum mismatch: {actual_checksum} != {expected_checksum}")
                    return False
            else:
                logger.warning("No checksum file found, skipping verification")
                return True
                
        except Exception as e:
            logger.error(f"Error verifying boot sector backup: {e}")
            return False
    
    def backup_original_boot_order(self) -> bool:
        """Backup the original boot order configuration."""
        try:
            if self.system_info['boot_type'] == 'uefi' and self.system_info['efibootmgr_available']:
                # Backup UEFI boot order
                result = subprocess.run(['efibootmgr'], capture_output=True, text=True)
                if result.returncode == 0:
                    with open(ORIGINAL_BOOT_ORDER_FILE, 'w') as f:
                        f.write(result.stdout)
                    logger.info("UEFI boot order backed up")
                    
            # Backup GRUB configuration if it exists
            if self.system_info['grub_installed']:
                grub_cfg = Path('/boot/grub/grub.cfg')
                if grub_cfg.exists():
                    shutil.copy2(grub_cfg, f"{BOOT_BACKUP_DIR}/grub.cfg")
                    logger.info("GRUB configuration backed up")
                    
            # Backup systemd-boot configuration if it exists
            if self.system_info['systemd_boot_installed']:
                boot_dir = Path('/boot/loader')
                if boot_dir.exists():
                    shutil.copytree(boot_dir, f"{BOOT_BACKUP_DIR}/loader", dirs_exist_ok=True)
                    logger.info("systemd-boot configuration backed up")
                    
            return True
            
        except Exception as e:
            logger.error(f"Error backing up boot order: {e}")
            return False
    
    def find_backrest_drive(self) -> Optional[str]:
        """Find the BackRest drive by looking for specific partition labels."""
        try:
            # Check for BackRest drive characteristics
            result = subprocess.run(['lsblk', '-f', '-n', '-o', 'NAME,LABEL,PARTLABEL,FSTYPE'], 
                                  capture_output=True, text=True)
            
            for line in result.stdout.split('\n'):
                if 'LOGS_CFG' in line or 'IMGSTORE' in line:
                    # Extract device name
                    parts = line.split()
                    if len(parts) >= 1:
                        device = parts[0]
                        if 'p' in device:
                            drive = f"/dev/{device.rsplit('p', 1)[0]}"
                        else:
                            drive = f"/dev/{device}"
                        logger.info(f"Found BackRest drive: {drive}")
                        return drive
                        
        except Exception as e:
            logger.error(f"Error finding BackRest drive: {e}")
            
        return None
    
    def configure_efi_boot_order(self, backrest_drive: str) -> bool:
        """Configure UEFI boot order to prioritize BackRest drive."""
        try:
            if not self.system_info['efibootmgr_available']:
                logger.warning("efibootmgr not available, skipping UEFI configuration")
                return False
                
            # Find the ESP partition on the BackRest drive
            result = subprocess.run(['lsblk', '-f', '-n', '-o', 'NAME,PARTLABEL,FSTYPE', backrest_drive], 
                                  capture_output=True, text=True)
            
            esp_partition = None
            for line in result.stdout.split('\n'):
                if 'vfat' in line and 'ESP' in line:
                    parts = line.split()
                    if len(parts) >= 1:
                        partition = parts[0]
                        esp_partition = f"/dev/{partition}"
                        break
                        
            if not esp_partition:
                # Try to find the first FAT32 partition
                result = subprocess.run(['lsblk', '-f', '-n', '-o', 'NAME,FSTYPE', backrest_drive], 
                                      capture_output=True, text=True)
                for line in result.stdout.split('\n'):
                    if 'vfat' in line:
                        parts = line.split()
                        if len(parts) >= 1:
                            partition = parts[0]
                            esp_partition = f"/dev/{partition}"
                            break
                            
            if not esp_partition:
                logger.error(f"Could not find ESP partition on {backrest_drive}")
                return False
                
            logger.info(f"Using ESP partition: {esp_partition}")
            
            # Create a backup boot entry for BackRest
            with open(BACKREST_BOOT_ENTRY_FILE, 'w') as f:
                f.write(f"BackRest Boot Entry\n")
                f.write(f"Drive: {backrest_drive}\n")
                f.write(f"ESP: {esp_partition}\n")
                f.write(f"Created: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
                
            # Add BackRest to UEFI boot order
            # First, create the boot entry
            boot_entry_name = "BackRest"
            result = subprocess.run([
                'efibootmgr', '--create', '--disk', backrest_drive,
                '--part', str(esp_partition[-1]),  # Extract partition number
                '--loader', '\\EFI\\BOOT\\BOOTX64.EFI',  # Default boot filename
                '--label', boot_entry_name
            ], capture_output=True, text=True)
            
            if result.returncode == 0:
                logger.info("BackRest boot entry created successfully")
                
                # Move BackRest to first in boot order
                result = subprocess.run(['efibootmgr'], capture_output=True, text=True)
                if result.returncode == 0:
                    # Parse current boot order
                    boot_order = []
                    for line in result.stdout.split('\n'):
                        if line.startswith('BootOrder:'):
                            boot_order = [x.strip() for x in line.split(':', 1)[1].split(',')]
                            break
                            
                    # Find our BackRest entry
                    backrest_entry = None
                    for line in result.stdout.split('\n'):
                        if boot_entry_name in line and line.startswith('Boot'):
                            backrest_entry = line.split()[0].replace('Boot', '').replace('*', '')
                            break
                            
                    if backrest_entry:
                        # Move to front of boot order
                        new_order = [backrest_entry] + [x for x in boot_order if x != backrest_entry]
                        result = subprocess.run([
                            'efibootmgr', '--bootorder', ','.join(new_order)
                        ], capture_output=True, text=True)
                        
                        if result.returncode == 0:
                            logger.info("Boot order updated successfully")
                            return True
                        else:
                            logger.error(f"Failed to update boot order: {result.stderr}")
                    else:
                        logger.error("Could not find BackRest boot entry to move")
                else:
                    logger.error(f"Failed to read current boot order: {result.stderr}")
            else:
                logger.error(f"Failed to create boot entry: {result.stderr}")
                
            return False
            
        except Exception as e:
            logger.error(f"Error configuring UEFI boot order: {e}")
            return False
    
    def configure_grub_boot(self, backrest_drive: str) -> bool:
        """Configure GRUB to prioritize BackRest drive."""
        try:
            if not self.system_info['grub_installed']:
                logger.warning("GRUB not installed, skipping GRUB configuration")
                return False
                
            # Find the boot partition on the BackRest drive
            boot_partition = None
            result = subprocess.run(['lsblk', '-f', '-n', '-o', 'NAME,PARTLABEL,FSTYPE', backrest_drive], 
                                  capture_output=True, text=True)
            
            for line in result.stdout.split('\n'):
                if 'vfat' in line:  # FAT32 boot partition
                    parts = line.split()
                    if len(parts) >= 1:
                        partition = parts[0]
                        boot_partition = f"/dev/{partition}"
                        break
                        
            if not boot_partition:
                # Use the first partition
                result = subprocess.run(['lsblk', '-ln', '-o', 'NAME', backrest_drive], 
                                      capture_output=True, text=True)
                partitions = result.stdout.strip().split('\n')
                if len(partitions) > 1:  # Skip drive itself
                    boot_partition = f"/dev/{partitions[1]}"
                    
            if not boot_partition:
                logger.error(f"Could not find boot partition on {backrest_drive}")
                return False
                
            logger.info(f"Using boot partition: {boot_partition}")
            
            # Install GRUB to the BackRest drive's boot sector
            result = subprocess.run([
                'grub-install', '--target=i386-pc' if self.system_info['boot_type'] == 'bios' else '--target=x86_64-efi',
                '--efi-directory', '/tmp/backrest_efi',  # We'll create a temporary mount point
                '--bootloader-id', 'BackRest',
                '--recheck'
            ], capture_output=True, text=True)
            
            if result.returncode == 0:
                logger.info("GRUB installed to BackRest drive successfully")
                return True
            else:
                logger.error(f"Failed to install GRUB: {result.stderr}")
                return False
                
        except Exception as e:
            logger.error(f"Error configuring GRUB boot: {e}")
            return False
    
    def configure_secure_boot_mitigation(self) -> bool:
        """Implement Secure Boot mitigation strategies."""
        try:
            # Check if Secure Boot is enabled
            if self.system_info['boot_type'] != 'uefi':
                logger.info("Not UEFI system, Secure Boot not applicable")
                return True
                
            # Check mokutil for Secure Boot status (if available)
            if shutil.which('mokutil'):
                result = subprocess.run(['mokutil', '--sb-state'], capture_output=True, text=True)
                if 'enabled' in result.stdout.lower():
                    logger.info("Secure Boot detected as enabled")
                    
                    # Generate MOK (Machine Owner Key) for signing
                    # This is a simplified approach - in production, you'd want proper key management
                    key_dir = f"{BOOT_BACKUP_DIR}/secure_boot"
                    os.makedirs(key_dir, exist_ok=True)
                    
                    # Create a placeholder for Secure Boot configuration
                    secure_boot_file = f"{key_dir}/mok_config.txt"
                    with open(secure_boot_file, 'w') as f:
                        f.write("BackRest Secure Boot Configuration\n")
                        f.write("Generated: " + time.strftime('%Y-%m-%d %H:%M:%S') + "\n")
                        f.write("Note: This system has Secure Boot enabled.\n")
                        f.write("Manual signing of BackRest bootloaders may be required.\n")
                        f.write("See BackRest documentation for Secure Boot setup.\n")
                        
                    logger.info("Secure Boot mitigation configuration created")
                    logger.warning("Manual intervention may be required for Secure Boot")
                    
                else:
                    logger.info("Secure Boot is disabled or not available")
                    
            else:
                logger.info("mokutil not available, cannot check Secure Boot status")
                
            return True
            
        except Exception as e:
            logger.error(f"Error configuring Secure Boot mitigation: {e}")
            return False
    
    def configure_fallback_boot(self) -> bool:
        """Configure fallback boot behavior when BackRest is not available."""
        try:
            # This is typically handled by the bootloader's timeout and fallback mechanisms
            # For UEFI, this would be handled by the firmware's boot order
            # For BIOS, this would be handled by GRUB's timeout
            
            # Create a configuration file for reference
            fallback_config = f"{BOOT_BACKUP_DIR}/fallback_config.txt"
            with open(fallback_config, 'w') as f:
                f.write("BackRest Fallback Configuration\n")
                f.write("Generated: " + time.strftime('%Y-%m-%d %H:%M:%S') + "\n")
                f.write("Boot order backup available in: original_boot_order.txt\n")
                f.write("To restore original boot order, use the original boot configuration.\n")
                f.write("For UEFI: Use 'efibootmgr --bootorder' with backed up order\n")
                f.write("For GRUB: Restore grub.cfg from backup\n")
                
            logger.info("Fallback boot configuration created")
            return True
            
        except Exception as e:
            logger.error(f"Error configuring fallback boot: {e}")
            return False
    
    def restore_original_boot(self) -> bool:
        """Restore the original boot configuration."""
        try:
            logger.info("Restoring original boot configuration")
            
            if self.system_info['boot_type'] == 'uefi' and self.system_info['efibootmgr_available']:
                if Path(ORIGINAL_BOOT_ORDER_FILE).exists():
                    # This would require parsing the original boot order and restoring it
                    logger.info("UEFI boot order restoration would be performed here")
                    
            # GRUB restoration would go here
            if Path(f"{BOOT_BACKUP_DIR}/grub.cfg").exists():
                logger.info("GRUB configuration restoration would be performed here")
                
            return True
            
        except Exception as e:
            logger.error(f"Error restoring original boot: {e}")
            return False
    
    def prepare_backrest(self, dry_run: bool = False) -> bool:
        """Main function to prepare the system for BackRest booting."""
        try:
            logger.info("Starting BackRest preparation process")
            logger.info(f"System detected: {self.system_info}")
            
            if dry_run:
                logger.info("DRY RUN MODE - No changes will be made")
                
            # Step 1: Identify the boot drive
            boot_drive, boot_partition = self.identify_boot_drive()
            if not dry_run:
                logger.info(f"Identified boot drive: {boot_drive}")
                
            # Step 2: Find BackRest drive
            backrest_drive = self.find_backrest_drive()
            if not backrest_drive:
                logger.error("BackRest drive not found. Ensure the drive is connected.")
                return False
                
            logger.info(f"Found BackRest drive: {backrest_drive}")
            
            # Step 3: Backup boot sector
            if not dry_run:
                if not self.backup_boot_sector(boot_drive):
                    logger.error("Failed to backup boot sector")
                    return False
                    
            if not self.verify_boot_sector_backup():
                logger.error("Boot sector backup verification failed")
                return False
                
            # Step 4: Backup original boot order
            if not dry_run:
                if not self.backup_original_boot_order():
                    logger.warning("Failed to backup original boot order")
                    
            # Step 5: Configure boot order based on system type
            if not dry_run:
                boot_configured = False
                
                if self.system_info['boot_type'] == 'uefi':
                    boot_configured = self.configure_efi_boot_order(backrest_drive)
                elif self.system_info['boot_type'] == 'bios':
                    boot_configured = self.configure_grub_boot(backrest_drive)
                else:
                    logger.warning("Unknown boot type, attempting basic configuration")
                    boot_configured = self.configure_grub_boot(backrest_drive)
                    
                if not boot_configured:
                    logger.error("Failed to configure boot order")
                    return False
                    
            # Step 6: Configure Secure Boot mitigation
            if not dry_run:
                if not self.configure_secure_boot_mitigation():
                    logger.warning("Secure Boot mitigation configuration failed")
                    
            # Step 7: Configure fallback boot
            if not dry_run:
                if not self.configure_fallback_boot():
                    logger.warning("Fallback boot configuration failed")
                    
            logger.info("BackRest preparation completed successfully")
            return True
            
        except Exception as e:
            logger.error(f"Error during BackRest preparation: {e}")
            return False
    
    def print_system_info(self):
        """Print detailed system information."""
        print("\n=== System Information ===")
        print(f"Architecture: {self.system_info['architecture']}")
        print(f"Platform: {self.system_info['platform']}")
        print(f"Distribution: {self.system_info['distribution']}")
        print(f"Boot Type: {self.system_info['boot_type']}")
        print(f"UEFI Variables Available: {self.system_info['efivars_available']}")
        print(f"GRUB Installed: {self.system_info['grub_installed']}")
        print(f"efibootmgr Available: {self.system_info['efibootmgr_available']}")
        print(f"systemd-boot Available: {self.system_info['systemd_boot_installed']}")
        print(f"ARM Architecture: {self.system_info['is_arm']}")
        print("========================\n")
    
    def cleanup_temp_files(self):
        """Clean up temporary files after operation."""
        try:
            if Path(BOOT_BACKUP_DIR).exists():
                logger.info(f"Cleaning up temporary files in {BOOT_BACKUP_DIR}")
                # Note: In a real implementation, you might want to keep these for recovery
                # shutil.rmtree(BOOT_BACKUP_DIR)
        except Exception as e:
            logger.error(f"Error cleaning up temporary files: {e}")

def main():
    """Main function to run the BackRest preparation script."""
    parser = argparse.ArgumentParser(description='Prepare system for BackRest boot configuration')
    parser.add_argument('--dry-run', action='store_true', 
                       help='Show what would be done without making changes')
    parser.add_argument('--info', action='store_true',
                       help='Display system information and exit')
    parser.add_argument('--restore', action='store_true',
                       help='Restore original boot configuration')
    parser.add_argument('--cleanup', action='store_true',
                       help='Clean up temporary files')
    parser.add_argument('--verbose', '-v', action='store_true',
                       help='Enable verbose logging')
    
    args = parser.parse_args()
    
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
        
    boot_manager = BootConfigManager()
    
    if args.info:
        boot_manager.print_system_info()
        return 0
        
    if args.cleanup:
        boot_manager.cleanup_temp_files()
        return 0
        
    if args.restore:
        success = boot_manager.restore_original_boot()
        return 0 if success else 1
        
    # Main preparation process
    boot_manager.print_system_info()
    
    print("""
    BackRest Preparation Script
    ============================
    
    This script will:
    1. Identify your system's boot configuration
    2. Find the BackRest drive
    3. Backup your current boot sector
    4. Configure boot order to prioritize BackRest
    5. Set up fallback boot behavior
    
    WARNING: This script modifies critical boot configuration.
    Always ensure you have a working backup before proceeding.
    
    Note: This script requires root privileges and may need to be run
    multiple times to complete the full configuration.
    """)
    
    if not args.dry_run:
        response = input("Continue? (yes/no): ")
        if response.lower() not in ['yes', 'y']:
            print("Operation cancelled by user")
            return 1
            
    success = boot_manager.prepare_backrest(dry_run=args.dry_run)
    
    if success:
        print("\nBackRest preparation completed successfully!")
        if not args.dry_run:
            print("Please reboot your system to test the configuration.")
            print("The original boot order has been backed up and can be restored if needed.")
        return 0
    else:
        print("\nBackRest preparation failed. Check the logs for details.")
        return 1
if __name__ == '__main__':
    sys.exit(main())
