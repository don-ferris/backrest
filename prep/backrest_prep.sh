#!/bin/bash
# BackRest Preparation Script Wrapper
# Makes the Python script executable and provides easy usage

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKREST_PREP_PY="$SCRIPT_DIR/backrest_prep.py"
PID_FILE="/tmp/backrest_prep.pid"
LOG_FILE="/var/log/backrest_prep_run.log"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges. Please run with sudo."
    echo "Usage: sudo $0 [options]"
    exit 1
fi

# Make the Python script executable
chmod +x "$BACKREST_PREP_PY"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to check dependencies
check_dependencies() {
    local missing_deps=()
    
    # Check for required commands
    for cmd in python3 dd lsblk efibootmgr grub-install; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "Missing required dependencies:"
        printf '  %s\n' "${missing_deps[@]}"
        echo ""
        echo "On Ubuntu/Debian, install with:"
        echo "  sudo apt update"
        echo "  sudo apt install python3 grub-efi-amd64-bin efibootmgr"
        echo ""
        echo "On RHEL/CentOS, install with:"
        echo "  sudo yum install python3 grub2-efi-x64 efibootmgr"
        exit 1
    fi
}

# Function to run the Python script
run_backrest_prep() {
    local args="$*"
    log_message "Starting BackRest preparation with args: $args"
    
    # Check if another instance is running
    if [ -f "$PID_FILE" ]; then
        local old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "Another instance is already running (PID: $old_pid)"
            echo "If you believe this is an error, remove $PID_FILE"
            exit 1
        else
            rm -f "$PID_FILE"
        fi
    fi
    
    # Write our PID
    echo $$ > "$PID_FILE"
    
    # Ensure cleanup on exit
    trap "rm -f $PID_FILE" EXIT
    
    # Run the Python script
    exec python3 "$BACKREST_PREP_PY" $args
}

# Function to show usage
show_usage() {
    cat << EOF
BackRest Preparation Script
============================

Usage: $0 [OPTIONS]

Options:
    --dry-run          Show what would be done without making changes
    --info             Display system information and exit
    --restore          Restore original boot configuration
    --cleanup          Clean up temporary files
    --verbose, -v      Enable verbose logging
    --check-deps       Check for required dependencies
    --install-deps     Install required dependencies (Ubuntu/Debian)
    --install-deps-rhel Install required dependencies (RHEL/CentOS)
    --help, -h         Show this help message

Examples:
    $0 --info                          # Show system information
    $0 --dry-run                       # Preview changes
    $0                                 # Interactive mode (asks for confirmation)
    $0 --restore                       # Restore original boot configuration
    $0 --verbose --dry-run            # Verbose preview

Description:
    This script configures your system to boot from the BackRest drive
    while maintaining the ability to fall back to the original configuration
    if the BackRest drive is not present.

    The script supports:
    - BIOS and UEFI systems
    - x86_64 and ARM64 architectures
    - Various Linux distributions
    - Secure Boot mitigation
    - Automatic fallback boot configuration

Requirements:
    - Root privileges
    - Python 3.6+
    - grub-install (for BIOS systems)
    - efibootmgr (for UEFI systems)
    - Sufficient disk space for backups

For more information, see the BackRest documentation.
EOF
}

# Main script logic
case "${1:-}" in
    --help|-h)
        show_usage
        exit 0
        ;;
    --check-deps)
        check_dependencies
        echo "All required dependencies are available."
        exit 0
        ;;
    --install-deps)
        echo "Installing dependencies for Ubuntu/Debian..."
        apt update
        apt install -y python3 grub-efi-amd64-bin efibootmgr parted lsblk
        echo "Dependencies installed successfully."
        exit 0
        ;;
    --install-deps-rhel)
        echo "Installing dependencies for RHEL/CentOS..."
        yum install -y python3 grub2-efi-x64 efibootmgr parted lsblk
        echo "Dependencies installed successfully."
        exit 0
        ;;
    *)
        check_dependencies
        run_backrest_prep "$@"
        ;;
esac
