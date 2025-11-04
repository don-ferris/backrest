#!/usr/bin/env python3
# pyref.py - an annotated Python script that demonstrates many language features
#
# This variant is simplified for Linux-only usage (Ubuntu Server).
# It removes Windows-specific handling (msvcrt) and assumes a POSIX terminal
# environment where termios + tty are available.
#
"""
Multi-line comment / module docstring:
This script is intended as a reference / tutorial showing many Python features
including: shebang, variable assignment, comments, immediate keypress handling
(so Y/N and menu selections do not require Enter), file I/O, subprocess usage,
data types, scope, functions, conditional branches, imports, marker files, and
text parsing/manipulation examples.

Notes:
- This version is tailored for Linux (POSIX) systems only. It uses termios/tty
  for single-key input without Enter and does not include Windows branches.
- Designed to be run on Ubuntu Server or similar Linux distributions.
"""
# Extensive inline documentation is included in functions and comments below.

# Standard library imports (demonstrating importing external libraries).
import os
import sys
import subprocess
import time
import json
from pathlib import Path

# Try to import a commonly used third-party library as an example.
# If it's not installed, we handle it gracefully.
try:
    import requests  # optional; only used for demonstration of imports
    HAS_REQUESTS = True
except Exception:
    HAS_REQUESTS = False

# -------------------------------------------------------------------------
# Cross-platform keypress note:
# This script is Linux-only. The get_single_key below uses POSIX APIs only
# (termios + tty). It will NOT run correctly on Windows.
# -------------------------------------------------------------------------
def get_single_key():
    """
    Read a single keypress from stdin and return a tuple (char, ordinal).
    Does not require the user to press Enter. This is implemented using POSIX
    APIs (termios + tty) and will work on Linux/Unix systems.

    Behavior notes:
    - Returns a 1-character string and its ordinal code (ord(character)).
    - If the user presses Ctrl-C, a KeyboardInterrupt will be raised.
    - Esc has ordinal 27.
    """
    import tty
    import termios

    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        # Put terminal into raw mode to get immediate single-character input
        tty.setraw(fd)
        ch = sys.stdin.read(1)  # read exactly one character
        if not ch:
            return "", 0
        # If Ctrl-C pressed, raise as a normal KeyboardInterrupt
        if ord(ch) == 3:
            raise KeyboardInterrupt
        return ch, ord(ch)
    finally:
        # Always restore terminal settings to avoid leaving terminal in raw mode
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)

def press_any_key(message="Press any key to continue..."):  
    """
    Inform the user of [something] and wait for any single key press (no Enter).
    This echoes the message and waits for a single key via get_single_key().
    """
    print(message, end='', flush=True)
    try:
        get_single_key()  # read and ignore returned value
    except KeyboardInterrupt:
        # If user hit Ctrl-C, print a newline and re-raise to allow graceful exit
        print()
        raise
    print()  # newline after key press

# 1) Proper shebang: present at the top of the file.
# 2) Assign a value to a variable (example)
example_var = "Hello, pyref!"  # string variable assignment example

# 3) Single line comment above demonstrates single-line comments.
# 4) Multi-line comments / docstrings are used throughout this file.

# File paths we will use for examples
TMP_FILE = Path("/tmp/pyref_example.txt")
MARKER_FILE = Path("/tmp/pyref_marker")

# 7) Write a multi-line file to /tmp
def write_initial_file():
    """
    Create /tmp/pyref_example.txt with several lines to serve as sample data.
    This overwrites any existing file at that path.
    """
    lines = [
        "Line 1: Header - pyref example file\n",
        "Line 2: This is the second line (we'll prepend numbers here later)\n",
        "Line 3: Menu item A - apples\n",
        "Line 4: Menu item B - bananas\n",
        "Line 5: Menu item C - cherries\n",
    ]
    TMP_FILE.write_text("".join(lines), encoding="utf-8")
    print(f"Wrote initial file to {TMP_FILE}")

# 5) Ask the user a yes/no question and wait for a response (Y/N case-insensitive).
def ask_yes_no(question="Do you want to continue? (y/n) "):  
    """
    Ask a yes/no question and return True for yes, False for no.
    The user can press 'y' or 'n' (case insensitive) — Enter is not required.
    Pressing Esc (ordinal 27) will be treated as a "no" (cancel).
    """
    sys.stdout.write(question)
    sys.stdout.flush()
    while True:
        ch, code = get_single_key()
        # Echo the pressed key so the user has feedback
        sys.stdout.write(ch + "\n")
        sys.stdout.flush()
        if ch.lower() == 'y':
            return True
        if ch.lower() == 'n':
            return False
        if code == 27:  # Esc key
            return False
        # Not a valid key, prompt again (still without Enter)
        sys.stdout.write("Please press 'y' or 'n': ")
        sys.stdout.flush()

# 8) Prompt the user for text and assign that text to a variable.
def ask_for_text(prompt="Enter some text (press Enter when done): "):  
    """
    Ask the user to type a full line of text (requires Enter).
    This returns the entered string which can be stored in a variable.
    """
    text = input(prompt)
    return text

# 9) Append the user's response to the multi-line file in /tmp
def append_text_to_file(text):
    """
    Append the provided text (plus a newline) to TMP_FILE.
    """
    with TMP_FILE.open("a", encoding="utf-8") as f:
        f.write(text + "\n")
    print(f"Appended your text to {TMP_FILE}")

# 10) Prompt the user for a number and prepend that to the second line in the file.
def prepend_number_to_second_line():
    """
    Prompt for an integer and prepend it to the second line (line index 1).
    If the file has fewer than two lines, it will create a second line and
    prepend the number there.
    """
    while True:
        num_str = input("Enter an integer to prepend to line 2 (blank to skip): ").strip()
        if num_str == "":
            print("No number entered; skipping.")
            return
        try:
            int(num_str)  # validate that it's an integer
            break
        except ValueError:
            print("Please enter a valid integer (e.g. 5 or -2).")

    # Read file contents and split into lines without losing text content
    text = TMP_FILE.read_text(encoding="utf-8")
    lines = text.splitlines()
    # Ensure there are at least two lines
    while len(lines) < 2:
        lines.append("")

    # Prepend number and a space to second line
    lines[1] = f"{num_str} {lines[1]}"
    TMP_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Prepended number to the second line of {TMP_FILE}.")

# 11) Create a menu from the file contents; selection via single-key press (no Enter)
def menu_from_file():
    """
    Build a menu from TMP_FILE's non-empty lines. Assign numeric keys 1..9
    to the first up-to-9 lines. The user presses the digit key to select (no Enter).
    Press Esc to cancel.
    Returns the chosen line (string) or None if cancelled.
    """
    content = TMP_FILE.read_text(encoding="utf-8")
    lines = [ln for ln in content.splitlines() if ln.strip()]
    if not lines:
        print("No menu items found in the file.")
        return None

    max_choices = min(9, len(lines))
    print("Menu (press the number key to choose; Esc to cancel):")
    for i in range(max_choices):
        print(f" {i+1}) {lines[i]}")

    while True:
        ch, code = get_single_key()
        if code == 27:  # Esc
            print("\nMenu cancelled.")
            return None
        if ch.isdigit():
            n = int(ch)
            if 1 <= n <= max_choices:
                choice = lines[n - 1]
                print(f"\nYou selected: {choice}")
                return choice
        # Invalid key pressed; prompt again
        print("\nPress a valid number key (1-{0}) or Esc: ".format(max_choices), end='', flush=True)

# 12) Execute a bash command (streamed output)
def run_bash_command(cmd="echo hello from bash"):
    """
    Execute a bash command and stream its stdout/stderr to the console.
    This uses subprocess.run and does not capture output into Python variables.
    """
    print(f"Executing shell command (streamed): {cmd}")
    subprocess.run(cmd, shell=True, check=False)

# 13) Assign the output of a bash command to a variable
def capture_bash_output(cmd="ls -l /tmp"):
    """
    Run a shell command and return its stdout as a decoded string.
    Demonstrates capturing the output into a Python variable.
    """
    try:
        output_bytes = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT)
        output = output_bytes.decode("utf-8", errors="replace")
        print(f"Captured output of command: {cmd!r}")
        return output
    except subprocess.CalledProcessError as e:
        print(f"Command failed with exit {e.returncode}. Output:\n{e.output.decode('utf-8', errors='replace')}")
        return ""

# 14) Code that demonstrates/explains data types
def demonstrate_data_types():
    """
    Show common Python data types and how to inspect them using type().
    """
    an_int = 42
    a_float = 3.14159
    a_str = "sample"
    a_bool = True
    a_list = [1, 2, 3]
    a_tuple = ("a", "b")
    a_dict = {"key": "value"}
    a_none = None

    print("\nData types and their values:")
    variables = {
        "an_int": an_int,
        "a_float": a_float,
        "a_str": a_str,
        "a_bool": a_bool,
        "a_list": a_list,
        "a_tuple": a_tuple,
        "a_dict": a_dict,
        "a_none": a_none,
    }
    for name, val in variables.items():
        print(f" {name}: value={val!r}, type={type(val).__name__}")

# 15) Code that demonstrates/explains variable scope
GLOBAL_VAR = "I am global"

def demonstrate_scope():
    """
    Demonstrates local vs global scope and how to use the 'global' keyword
    to modify module-level variables from inside a function.
    """
    local_var = "I am local"

    def inner_without_global():
        # This assignment creates a new local variable named GLOBAL_VAR inside this scope
        GLOBAL_VAR = "modified in inner_without_global (local)"
        return GLOBAL_VAR

    def inner_with_global():
        # Use the global keyword to refer to the module-level GLOBAL_VAR
        nonlocal_msg = "demonstrating global keyword"
        global GLOBAL_VAR
        GLOBAL_VAR = "modified in inner_with_global (global)"
        return GLOBAL_VAR

    print("\nScope demonstration:")
    print(" Before calls, GLOBAL_VAR =", GLOBAL_VAR)
    print(" inner_without_global returns:", inner_without_global())
    print(" After inner_without_global, GLOBAL_VAR still =", GLOBAL_VAR)
    print(" inner_with_global returns:", inner_with_global())
    print(" After inner_with_global, GLOBAL_VAR now =", GLOBAL_VAR)
    print(" local_var remains accessible inside demonstrate_scope:", local_var)

# 16) Functions demonstration - passing values and returning values
def add(a, b):
    """Return the sum of a and b."""
    return a + b
def greet(name="World"):
    """Return a greeting for the given name."""
    return f"Hello, {name}!"

def demonstrate_functions():
    print("\nFunctions demonstration:")
    print(" add(2,3) =>", add(2, 3))
    print(" greet('Alice') =>", greet("Alice"))

# 17) An if / elif / else example
def conditional_example(value):
    """
    Demonstrates if / elif / else using a numeric value.
    """
    if value < 0:
        print("Value is negative.")
    elif value == 0:
        print("Value is zero.")
    else:
        print("Value is positive.")

# 18) Demonstrate importing external libraries (requests)
def demonstrate_imports():
    """
    Show how to detect and use an optional external library ('requests').
    If it's not installed, suggest installation and show the fallback.
    """
    print("\nImports demonstration:")
    if HAS_REQUESTS:
        print("The 'requests' library is installed. Example: you could use requests.get(url).")
    else:
        print("The 'requests' library is NOT installed. Install with: pip install requests")
        print("Standard library alternative: urllib.request")

# 19) Marker file demo: write/detect marker file to branch logic
def marker_file_demo():
    """
    Demonstrate creating a marker file and using its presence/absence to control flow.
    """
    if MARKER_FILE.exists():
        print(f"Marker file {MARKER_FILE} exists. Taking branch A.")
        captured = capture_bash_output("date")
        print("Date output captured (example):", captured.strip())
    else:
        print(f"Marker file {MARKER_FILE} does not exist. Creating it now and taking branch B.")
        MARKER_FILE.write_text("marker\n", encoding="utf-8")
        print(f"Created marker file {MARKER_FILE}")

# 20) Text parsing/manipulation examples on the TMP_FILE
def text_parsing_demo():
    """
    Perform a variety of text operations on TMP_FILE:
     - search for a substring
     - replace text
     - move a word to the beginning of a line
     - append a suffix to a line
    """
    print("\nText parsing and manipulation demo:")
    text = TMP_FILE.read_text(encoding="utf-8")
    print("File contents (before):")
    print("-" * 40)
    print(text.rstrip())
    print("-" * 40) 
    # Search for substring "apples"
    if "apples" in text:
        print("Found substring 'apples' in file.")
    else:
        print("Did not find substring 'apples' in file.")
    # Replace first occurrence of "bananas" with "blueberries"
    if "bananas" in text:
        text = text.replace("bananas", "blueberries", 1)
        print("Replaced first occurrence of 'bananas' with 'blueberries'.")
    # Move the word "Header" to the start of the first line (if present)
    lines = text.splitlines()
    if lines:
        if "Header" in lines[0]:
            # Remove the word from where it was and prefix the line with it
            lines[0] = "Header: " + lines[0].replace("Header", "").strip()
            print("Moved 'Header' to start of first line.")
    # Ensure second line ends with " -- END"
    if len(lines) >= 2:
        if not lines[1].endswith(" -- END"):
            lines[1] = lines[1].rstrip() + " -- END"
            print("Appended marker to end of second line.")
    # Write the modified file back to disk
    TMP_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("File contents (after):")
    print("-" * 40)
    print(TMP_FILE.read_text(encoding="utf-8").rstrip())
    print("-" * 40)

# Main interactive flow
def main():
    print("pyref.py - interactive Python reference script (Linux-only)")
    print("example_var currently contains:", example_var)
    # Ensure initial example file exists with sample content
    write_initial_file()
    # 5) Ask yes/no immediately keyed (no Enter)
    try:
        if ask_yes_no("Would you like to edit the example file now? (y/n) "):
            # 8) Prompt the user for text and 9) append it to file
            user_text = ask_for_text("Please type a line to append to the file: ")
            append_text_to_file(user_text)
            # 10) Prompt for number and prepend it to the second line
            prepend_number_to_second_line()
        else:
            print("Skipping editing steps.")
    except KeyboardInterrupt:
        print("\nInterrupted by user; continuing with defaults.")
    # 6) Inform the user and wait for any keypress
    press_any_key("Informing you: editing steps are complete. Press any key to continue...")
    # 11) Show menu constructed from the file
    choice = menu_from_file()
    if choice is None:
        print("No menu choice selected.")
    else:
        print(f"You chose: {choice}")
    # 12) Execute a bash command (streamed output)
    run_bash_command("echo 'This is a shell command running from Python'; ls -l /tmp | head -n 3")
    # 13) Capture output from bash command into a variable
    ls_output = capture_bash_output("ls -1 /tmp | head -n 10")
    print("Captured listing of /tmp (first 10 entries):")
    print(ls_output.rstrip())
    # 14) Data types demonstration
    demonstrate_data_types()
    # 15) Variable scope demonstration
    demonstrate_scope()
    # 16) Functions demonstration
    demonstrate_functions()
    # 17) If/elif/else demonstration
    try:
        v = int(input("Enter an integer for the conditional demo (e.g. -1, 0, 5): "))
    except Exception:
        v = 0
    conditional_example(v)
    # 18) Show imports usage
    demonstrate_imports()
    # 19) Marker file demo (creates /tmp/pyref_marker if it does not exist)
    marker_file_demo()
    # 20) Text parsing/manipulation demo
    text_parsing_demo()
    # Cleanup prompt
    print("\nDemo complete. Clean up example files? (y/n) ")
    try:
        if ask_yes_no():
            # Remove files if they exist (compatible with older Python versions)
            if TMP_FILE.exists():
                TMP_FILE.unlink()
            if MARKER_FILE.exists():
                MARKER_FILE.unlink()
            print("Example files removed.")
        else:
            print(f"Files left in place: {TMP_FILE}, {MARKER_FILE}")
    except KeyboardInterrupt:
        print("\nInterrupted during cleanup prompt; leaving files in place.")
    print("Exiting pyref.py. Goodbye.")

if __name__ == "__main__":
    main()
