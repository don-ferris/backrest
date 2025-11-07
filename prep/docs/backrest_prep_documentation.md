# BackRest Preparation Script

## Overview

The `backrest_prep` script is a critical component of the BackRest disaster recovery system. It prepares target machines to boot from the BackRest drive while maintaining fallback capabilities. This ensures that headless operation mode works correctly by prioritizing the BackRest drive in the boot sequence.

## Features

- **Multi-Platform Support**: Works with BIOS/UEFI, x86_64/ARM64, and various Linux distributions
- **Automatic System Detection**: Identifies boot configuration, partition layout, and system architecture
- **Boot Sector Backup**: Creates secure backups of original boot sectors with integrity verification
- **Boot Order Configuration**: Configures boot priority to prioritize BackRest drive
- **Secure Boot Mitigation**: Handles Secure Boot requirements and provides guidance
- **Fallback Protection**: Maintains original boot configuration for emergency recovery
- **Comprehensive Logging**: Detailed logging of all operations for troubleshooting

## System Requirements

### Dependencies
- Python 3.6 or higher
- Root privileges
- The following system tools:
  - `dd` (coreutils)
  - `lsblk` (util-linux)
  - `grub-install` (for BIOS systems)
  - `efibootmgr` (for UEFI systems)
  - `mokutil` (for Secure Boot detection, optional)

### Supported Systems
- **Operating Systems**: Most Linux distributions
- **Architectures**: x86_64, ARM64 (aarch64)
- **Boot Types**: BIOS Legacy, UEFI
- **Special Cases**: Secure Boot enabled systems, ARM64-based devices

## Installation

### Quick Setup
1. Copy both `backrest_prep.py` and `backrest_prep.sh` to your system
2. Make the shell script executable: `chmod +x backrest_prep.sh`
3. Run with root privileges: `sudo ./backrest_prep.sh`

### Manual Installation of Dependencies

#### Ubuntu/Debian
```bash
sudo apt update
sudo apt install python3 grub-efi-amd64-bin efibootmgr parted lsblk
```

#### RHEL/CentOS/Fedora
```bash
sudo yum install python3 grub2-efi-x64 efibootmgr parted lsblk
```

#### ARM64 Systems
```bash
# Additional packages for ARM64
sudo apt install grub-efi-arm64-bin  # Ubuntu/Debian
sudo yum install grub2-efi-aa64      # RHEL/CentOS
```

## Usage

### Basic Usage

```bash
# Show system information
sudo ./backrest_prep.sh --info

# Preview changes (dry run)
sudo ./backrest_prep.sh --dry-run

# Interactive mode (asks for confirmation)
sudo ./backrest_prep.sh

# Verbose mode
sudo ./backrest_prep.sh --verbose
```

### Advanced Options

```bash
# Check dependencies
sudo ./backrest_prep.sh --check-deps

# Restore original boot configuration
sudo ./backrest_prep.sh --restore

# Clean up temporary files
sudo ./backrest_prep.sh --cleanup

# Install dependencies (Ubuntu/Debian)
sudo ./backrest_prep.sh --install-deps

# Install dependencies (RHEL/CentOS)
sudo ./backrest_prep.sh --install-deps-rhel
```

### Python Script Direct Usage

```bash
# Direct Python usage
sudo python3 backrest_prep.py --help
sudo python3 backrest_prep.py --info
sudo python3 backrest_prep.py --dry-run
```

## Script Behavior

### Step-by-Step Process

1. **System Detection**
   - Identifies boot type (BIOS/UEFI)
   - Detects system architecture
   - Checks for available boot managers
   - Identifies the primary boot drive

2. **BackRest Drive Discovery**
   - Scans for drives with "LOGS_CFG" and "IMGSTORE" partitions
   - Identifies the BackRest drive automatically

3. **Boot Sector Backup**
   - Creates a 10MB backup of the original boot sector
   - Calculates SHA256 checksum for integrity verification
   - Stores backup in `/tmp/backrest_boot_backup/`

4. **Original Boot Configuration Backup**
   - Backs up UEFI boot order using `efibootmgr`
   - Saves GRUB configuration files
   - Preserves systemd-boot configuration

5. **Boot Order Configuration**
   - **UEFI Systems**: Creates new boot entry and moves it to first position
   - **BIOS Systems**: Configures GRUB to prioritize BackRest drive
   - Maintains proper boot chain configuration

6. **Secure Boot Handling**
   - Detects Secure Boot status
   - Creates mitigation configuration
   - Provides guidance for manual signing if required

7. **Fallback Configuration**
   - Ensures system can boot normally if BackRest is not present
   - Maintains original boot order as fallback
   - Creates recovery instructions

### Output Files

The script creates several important files:

- `/tmp/backrest_boot_backup/boot_sector.img` - Boot sector backup
- `/tmp/backrest_boot_backup/boot_sector.img.sha256` - Checksum file
- `/tmp/backrest_boot_backup/original_boot_order.txt` - UEFI boot order backup
- `/tmp/backrest_boot_backup/grub.cfg` - GRUB configuration backup
- `/var/log/backrest_prep.log` - Detailed operation log
- `/var/log/backrest_prep_run.log` - Session log

## Security Considerations

### Secure Boot
- Script detects Secure Boot status automatically
- Provides configuration guidance for signed bootloaders
- May require manual intervention for production Secure Boot environments

### Boot Sector Modification
- Always creates verified backups before making changes
- Provides rollback capability
- Safe to run multiple times

### Access Control
- Requires root privileges for system-level modifications
- Comprehensive logging for audit trails
- No persistent changes to system files

## Troubleshooting

### Common Issues

#### 1. "Could not identify the primary boot drive"
**Solution**: Check that you're running on a system with proper disk access. Verify with:
```bash
lsblk -f
sudo fdisk -l
```

#### 2. "BackRest drive not found"
**Solution**: Ensure the BackRest drive is connected and has the correct partition labels:
```bash
lsblk -f | grep -E "LOGS_CFG|IMGSTORE"
```

#### 3. "Permission denied" errors
**Solution**: Ensure you're running with root privileges:
```bash
sudo ./backrest_prep.sh
```

#### 4. "efibootmgr: command not found"
**Solution**: Install the required package:
```bash
sudo apt install efibootmgr  # Ubuntu/Debian
sudo yum install efibootmgr  # RHEL/CentOS
```

#### 5. GRUB installation failures
**Solution**: Check GRUB installation and target system compatibility:
```bash
sudo grub-install --version
sudo ./backrest_prep.sh --info
```

### Log Analysis
Check the logs for detailed error information:
```bash
sudo tail -f /var/log/backrest_prep.log
sudo journalctl -f -u backrest-prep  # If running as a service
```

### Recovery
If something goes wrong, you can restore the original configuration:
```bash
sudo ./backrest_prep.sh --restore
```

Or manually restore the boot order:
```bash
sudo efibootmgr  # To see current order
sudo efibootmgr --bootorder XXXX,YYYY  # Restore original order
```

## Testing and Validation

### Pre-Deployment Testing
1. Run in dry-run mode first: `sudo ./backrest_prep.sh --dry-run`
2. Check system information: `sudo ./backrest_prep.sh --info`
3. Verify dependencies: `sudo ./backrest_prep.sh --check-deps`

### Post-Deployment Validation
1. Reboot the system
2. Verify BackRest drive is detected in boot menu
3. Test fallback behavior (remove BackRest drive and reboot)
4. Check logs for any errors

## ARM64 Considerations

The script includes special handling for ARM64 systems:
- Different GRUB targets (`arm64-efi`)
- Platform-specific boot management
- Enhanced device detection for ARM platforms

## Production Deployment

For production environments, consider:

1. **Testing**: Always test in a non-production environment first
2. **Backup Strategy**: Keep original boot configurations in a secure location
3. **Documentation**: Record system-specific boot configurations
4. **Monitoring**: Monitor boot success rates after deployment
5. **Rollback Plan**: Have a plan to quickly restore original boot configuration

## Support and Maintenance

### Regular Maintenance
- Periodically verify boot order hasn't changed
- Check for updates to boot management tools
- Test recovery procedures regularly

### Compatibility Updates
The script is designed to be extensible. New boot managers and platforms can be added by extending the `BootConfigManager` class.

### Contributing
When modifying the script:
- Maintain backward compatibility
- Add comprehensive logging
- Include error handling
- Update this documentation

## API Reference

### BootConfigManager Class

The main class for managing boot configuration:

```python
class BootConfigManager:
    def __init__(self)
    def _detect_system(self) -> Dict
    def identify_boot_drive(self) -> Tuple[str, str]
    def backup_boot_sector(self, boot_drive: str) -> bool
    def verify_boot_sector_backup(self) -> bool
    def backup_original_boot_order(self) -> bool
    def find_backrest_drive(self) -> Optional[str]
    def configure_efi_boot_order(self, backrest_drive: str) -> bool
    def configure_grub_boot(self, backrest_drive: str) -> bool
    def configure_secure_boot_mitigation(self) -> bool
    def configure_fallback_boot(self) -> bool
    def prepare_backrest(self, dry_run: bool = False) -> bool
```

### Key Methods

- `prepare_backrest()`: Main function that orchestrates the entire process
- `identify_boot_drive()`: Identifies the system's primary boot drive
- `backup_boot_sector()`: Creates and verifies boot sector backups
- `configure_efi_boot_order()`: Configures UEFI boot order
- `configure_grub_boot()`: Configures GRUB for BIOS systems

## License and Copyright

This script is part of the BackRest disaster recovery system. See the main BackRest documentation for licensing information.

---

**Version**: 1.0  
**Last Updated**: 2025-11-07  
**Compatibility**: Python 3.6+, Linux systems with GRUB/UEFI support
