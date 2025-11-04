#!/usr/bin/env bash
: <<'SCRIPT_HEADER'
menutest.sh
menutest - Trying to get a handle on the whole "Esc to quit" thing
──────────────────────────────────────────────────────
Author: Don Ferris
Created: 2025-11-03
Current Revision: 1.0
──────────────────────────────────────────────────────
Revision History
================
v1.0 — 2025-11-03 — Initial implementation
──────────────────────────────────────────────────────

# END OF
SCRIPT_HEADER

# Simple main menu that reads a single keypress.
# - Options: [B] Backup, [R] Restore, [S] Settings, [X] Exit
# - Prompt includes "or press Esc to cancel"
# - Esc exits immediately (exit 0), suppressing errors
# - Other keys: report selection or show invalid message and return to menu

# Ensure we're running in a POSIX-compatible bash
set -o errexit
set -o nounset
set -o pipefail

# Show a submenu for a given title. Generates between 4 and 8 unique random letter options.
submenu() {
    local title="$1"
    # 4..8
    local count=$((RANDOM % 5 + 4))
    local options

    # Use shuf to pick unique letters from A..Z
    # If shuf is not available, fall back to a simple shuffle using awk
    if command -v shuf >/dev/null 2>&1; then
        mapfile -t options < <(printf '%s\n' {A..Z} | shuf -n "$count")
    else
        # simple fallback: print A..Z, assign random number and sort
        mapfile -t options < <(awk 'BEGIN{srand(); for(i=65;i<=90;i++){printf "%c %f\n", i, rand()}}' | sort -k2,2n | awk '{print $1}' | head -n "$count")
    fi

    while true; do
        clear
        printf '%s Menu\n' "$title"
        printf '---------\n'
        for l in "${options[@]}"; do
            printf '[%s] Option %s\n' "$l" "$l"
        done
        printf "\nChoose an option (%s) or press Esc to cancel:\n" "$(IFS=/; echo "${options[*]}")"

        # Read one single character silently
        read -rsn1 input || true

        # If the user pressed Esc (ASCII escape), exit immediately, silently
        if [[ "$input" == $'\e' ]]; then
            exit 0
        fi

        key=$(printf '%s' "$input" | tr '[:lower:]' '[:upper:]')

        # Check if key is one of the generated options
        found=false
        for l in "${options[@]}"; do
            if [[ "$key" == "$l" ]]; then
                found=true
                break
            fi
        done

        if [[ "$found" == true ]]; then
            printf 'You chose %s\n' "$key"
            sleep 1
            return 0
        else
            printf 'Invalid selection\n'
            sleep 1.5
        fi
    done
}

while true; do
    clear
    cat <<'MENU'
Main Menu
---------
[B] Backup
[R] Restore
[S] Settings
[X] Exit

Choose an option (B/R/S/X) or press Esc to cancel:
MENU

    # Read one single character silently
    read -rsn1 input || true

    # If the user pressed Esc (ASCII escape), exit immediately, silently
    if [[ "$input" == $'\e' ]]; then
        exit 0
    fi

    # Normalize to upper case for comparison
    key=$(printf '%s' "$input" | tr '[:lower:]' '[:upper:]')

    case "$key" in
        B)
            submenu "Backup"
            ;;
        R)
            submenu "Restore"
            ;;
        S)
            submenu "Settings"
            ;;
        X)
            printf 'You chose X\n'
            # Exit after choosing Exit
            exit 0
            ;;
        *)
            printf 'Invalid selection\n'
            sleep 1.5
            ;;
    esac
done
