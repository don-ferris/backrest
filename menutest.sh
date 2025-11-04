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
    # -r: raw input (do not treat backslashes specially)
    # -s: silent (do not echo)
    # -n1: read 1 character
    read -rsn1 input || true

    # If the user pressed Esc (ASCII escape), exit immediately, silently
    if [[ "${input}" == $'\e' ]]; then
        exit 0
    fi

    # Normalize to upper case for comparison
    key=$(printf '%s' "$input" | tr '[:lower:]' '[:upper:]')

    case "$key" in
        B)
            printf 'You chose B\n'
            sleep 1
            ;;
        R)
            printf 'You chose R\n'
            sleep 1
            ;;
        S)
            printf 'You chose S\n'
            sleep 1
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
