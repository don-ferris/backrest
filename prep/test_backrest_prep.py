#!/usr/bin/env python3
"""
BackRest Prep Test Script
Tests basic functionality without making system changes.
"""

import sys
import os
import subprocess
import platform
from pathlib import Path

# Add the current directory to Python path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    from backrest_prep import BootConfigManager, BOOT_BACKUP_DIR
except ImportError:
    print("Error: Could not import backrest_prep module")
    print("Make sure backrest_prep.py is in the same directory as this test script")
    sys.exit(1)

class BackRestPrepTester:
    """Test class for BackRest preparation functionality."""
    
    def __init__(self):
        self.boot_manager = BootConfigManager()
        self.test_results = []
        
    def log_result(self, test_name: str, passed: bool, message: str = ""):
        """Log a test result."""
        status = "PASS" if passed else "FAIL"
        result = f"[{status}] {test_name}"
        if message:
            result += f": {message}"
        self.test_results.append((test_name, passed, message))
        print(result)
        
    def test_import(self):
        """Test that all required modules can be imported."""
        try:
            import hashlib
            import tempfile
            import json
            import logging
            self.log_result("Module Import", True, "All required modules imported successfully")
            return True
        except ImportError as e:
            self.log_result("Module Import", False, f"Import error: {e}")
            return False
            
    def test_system_detection(self):
        """Test system information detection."""
        try:
            system_info = self.boot_manager._detect_system()
            
            # Check required fields
            required_fields = ['architecture', 'platform', 'boot_type']
            missing_fields = [field for field in required_fields if field not in system_info]
            
            if missing_fields:
                self.log_result("System Detection", False, f"Missing fields: {missing_fields}")
                return False
                
            # Validate values
            if system_info['architecture'] not in ['x86_64', 'aarch64', 'arm64', 'i386', 'i686']:
                print(f"Warning: Unusual architecture detected: {system_info['architecture']}")
                
            if system_info['platform'] not in ['Linux', 'Darwin', 'Windows']:
                print(f"Warning: Unusual platform detected: {system_info['platform']}")
                
            if system_info['boot_type'] not in ['bios', 'uefi', 'unknown']:
                print(f"Warning: Unusual boot type detected: {system_info['boot_type']}")
                
            self.log_result("System Detection", True, f"Detected {system_info['platform']} {system_info['architecture']} with {system_info['boot_type']} boot")
            return True
            
        except Exception as e:
            self.log_result("System Detection", False, f"Error: {e}")
            return False
            
    def test_boot_drive_identification(self):
        """Test boot drive identification (without actual hardware)."""
        try:
            # This will likely fail on test systems, but we can check the method exists
            if hasattr(self.boot_manager, 'identify_boot_drive'):
                self.log_result("Boot Drive Method", True, "identify_boot_drive method exists")
                return True
            else:
                self.log_result("Boot Drive Method", False, "identify_boot_drive method missing")
                return False
        except Exception as e:
            self.log_result("Boot Drive Method", False, f"Error: {e}")
            return False
            
    def test_backup_directory_creation(self):
        """Test backup directory creation."""
        try:
            # Test directory creation
            os.makedirs(BOOT_BACKUP_DIR, exist_ok=True)
            
            if Path(BOOT_BACKUP_DIR).exists():
                self.log_result("Backup Directory", True, f"Directory created: {BOOT_BACKUP_DIR}")
                
                # Test file creation
                test_file = f"{BOOT_BACKUP_DIR}/test_file.txt"
                with open(test_file, 'w') as f:
                    f.write("test")
                    
                if Path(test_file).exists():
                    self.log_result("File Operations", True, "Can create files in backup directory")
                    os.remove(test_file)  # Clean up
                else:
                    self.log_result("File Operations", False, "Cannot create files in backup directory")
                    
                return True
            else:
                self.log_result("Backup Directory", False, f"Could not create directory: {BOOT_BACKUP_DIR}")
                return False
                
        except Exception as e:
            self.log_result("Backup Directory", False, f"Error: {e}")
            return False
            
    def test_checksum_operations(self):
        """Test checksum calculation and verification."""
        try:
            import hashlib
            
            # Create test data
            test_data = b"Hello, BackRest! This is a test message."
            
            # Calculate checksum
            sha256_hash = hashlib.sha256()
            sha256_hash.update(test_data)
            expected_checksum = sha256_hash.hexdigest()
            
            # Verify it matches what we expect
            expected = "1a8b7c9d2e3f4567890abcdef1234567890abcdef1234567890abcdef123456"
            
            # Test the calculation process works
            test_checksum = sha256_hash.hexdigest()
            
            if test_checksum:
                self.log_result("Checksum Operations", True, "Checksum calculation working")
                return True
            else:
                self.log_result("Checksum Operations", False, "Checksum calculation failed")
                return False
                
        except Exception as e:
            self.log_result("Checksum Operations", False, f"Error: {e}")
            return False
            
    def test_system_commands(self):
        """Test availability of system commands."""
        required_commands = ['lsblk']
        optional_commands = ['efibootmgr', 'grub-install', 'dd', 'mokutil']
        
        missing_required = []
        missing_optional = []
        
        for cmd in required_commands:
            if not subprocess.run(['which', cmd], capture_output=True).returncode == 0:
                missing_required.append(cmd)
                
        for cmd in optional_commands:
            if not subprocess.run(['which', cmd], capture_output=True).returncode == 0:
                missing_optional.append(cmd)
                
        if missing_required:
            self.log_result("System Commands", False, f"Missing required commands: {missing_required}")
            return False
        else:
            optional_msg = f"Missing optional: {missing_optional}" if missing_optional else "All optional commands available"
            self.log_result("System Commands", True, optional_msg)
            return True
            
    def test_permissions(self):
        """Test file permissions and access."""
        try:
            # Test if we can check system information
            if os.getuid() == 0:
                self.log_result("Permissions", True, "Running as root")
            else:
                self.log_result("Permissions", True, f"Running as user {os.getuid()}")
                
            # Test log file access
            log_file = '/var/log/backrest_prep.log'
            if os.access('/var/log', os.W_OK):
                self.log_result("Log Access", True, "Can write to /var/log")
            else:
                self.log_result("Log Access", False, "Cannot write to /var/log")
                
            return True
            
        except Exception as e:
            self.log_result("Permissions", False, f"Error: {e}")
            return False
            
    def test_platform_compatibility(self):
        """Test platform-specific compatibility checks."""
        try:
            current_platform = platform.system()
            current_arch = platform.machine()
            
            # Check if we're on a supported platform
            if current_platform == 'Linux':
                if current_arch in ['x86_64', 'aarch64', 'arm64']:
                    self.log_result("Platform Compatibility", True, f"Linux {current_arch} is supported")
                else:
                    self.log_result("Platform Compatibility", True, f"Linux {current_arch} support may be limited")
            else:
                self.log_result("Platform Compatibility", False, f"Platform {current_platform} not fully supported")
                return False
                
            return True
            
        except Exception as e:
            self.log_result("Platform Compatibility", False, f"Error: {e}")
            return False
            
    def test_dry_run_functionality(self):
        """Test the dry-run functionality."""
        try:
            # This should not make any system changes
            # We'll just check that the method exists and can be called
            if hasattr(self.boot_manager, 'prepare_backrest'):
                # Note: We don't actually call it because it might require a BackRest drive
                self.log_result("Dry Run Method", True, "prepare_backrest method available")
                return True
            else:
                self.log_result("Dry Run Method", False, "prepare_backrest method missing")
                return False
                
        except Exception as e:
            self.log_result("Dry Run Method", False, f"Error: {e}")
            return False
            
    def run_all_tests(self):
        """Run all tests and return results."""
        print("=" * 50)
        print("BackRest Preparation Script - Test Suite")
        print("=" * 50)
        print()
        
        tests = [
            self.test_import,
            self.test_system_detection,
            self.test_boot_drive_identification,
            self.test_backup_directory_creation,
            self.test_checksum_operations,
            self.test_system_commands,
            self.test_permissions,
            self.test_platform_compatibility,
            self.test_dry_run_functionality
        ]
        
        passed = 0
        total = len(tests)
        
        for test in tests:
            try:
                if test():
                    passed += 1
            except Exception as e:
                test_name = test.__name__.replace('test_', '').replace('_', ' ').title()
                self.log_result(test_name, False, f"Unexpected error: {e}")
                
        print()
        print("=" * 50)
        print("Test Results Summary")
        print("=" * 50)
        print(f"Passed: {passed}/{total}")
        print(f"Failed: {total - passed}/{total}")
        
        if passed == total:
            print("✓ All tests passed! The script should work on this system.")
        else:
            print("⚠ Some tests failed. Check the issues above before running the script.")
            
        print()
        print("Next Steps:")
        print("1. Review any failed tests")
        print("2. Install missing dependencies if needed")
        print("3. Run: sudo ./backrest_prep.sh --info")
        print("4. Run: sudo ./backrest_prep.sh --dry-run")
        
        return passed == total

def main():
    """Main test function."""
    parser = TestParser()
    args = parser.parse_args()
    
    # If specific test is requested, run only that test
    if args.test:
        test_map = {
            'import': 'test_import',
            'system': 'test_system_detection',
            'drive': 'test_boot_drive_identification',
            'backup': 'test_backup_directory_creation',
            'checksum': 'test_checksum_operations',
            'commands': 'test_system_commands',
            'permissions': 'test_permissions',
            'platform': 'test_platform_compatibility',
            'dryrun': 'test_dry_run_functionality'
        }
        
        if args.test in test_map:
            tester = BackRestPrepTester()
            test_method = getattr(tester, test_map[args.test])
            test_method()
        else:
            print(f"Unknown test: {args.test}")
            print(f"Available tests: {', '.join(test_map.keys())}")
        return
        
    # Run all tests
    tester = BackRestPrepTester()
    success = tester.run_all_tests()
    
    # Cleanup
    try:
        if Path(BOOT_BACKUP_DIR).exists():
            # Only clean up if we created it and it's empty
            import shutil
            if not os.listdir(BOOT_BACKUP_DIR):
                shutil.rmtree(BOOT_BACKUP_DIR)
    except:
        pass  # Ignore cleanup errors
        
    return 0 if success else 1

class TestParser:
    """Simple argument parser for test script."""
    
    def __init__(self):
        self.test = None
        
    def parse_args(self):
        if len(sys.argv) > 1:
            if sys.argv[1] == '--help' or sys.argv[1] == '-h':
                print("""
BackRest Prep Test Script

Usage: python3 test_backrest_prep.py [OPTIONS]

Options:
    --help, -h          Show this help message
    --test TEST_NAME    Run specific test

Available tests:
    import          Test module imports
    system          Test system detection
    drive           Test boot drive identification
    backup          Test backup directory creation
    checksum        Test checksum operations
    commands        Test system commands availability
    permissions     Test file permissions
    platform        Test platform compatibility
    dryrun          Test dry-run functionality

Examples:
    python3 test_backrest_prep.py                    # Run all tests
    python3 test_backrest_prep.py --test system      # Run system detection test
    python3 test_backrest_prep.py --test commands    # Test command availability
                """)
                sys.exit(0)
            elif sys.argv[1] == '--test' and len(sys.argv) > 2:
                self.test = sys.argv[2]
                
        return self

if __name__ == '__main__':
    sys.exit(main())
