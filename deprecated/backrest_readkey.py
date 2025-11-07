#!/usr/bin/env python3
# backrest_readkey.py v1.0
# Reads bytes from stdin (which should be connected to /dev/tty) in raw mode,
# collects any immediately-available following bytes, and prints them as
# literal \xHH sequences (e.g. \x1b or \x62\x5b\x4b).
import sys, tty, termios, select

def main():
    fd = sys.stdin.fileno()
    try:
        old = termios.tcgetattr(fd)
    except Exception:
        old = None
    try:
        if old:
            tty.setraw(fd)
        b = sys.stdin.buffer.read(1)
        if not b:
            return
        out = bytearray(b)
        # grab any immediately-available trailing bytes from an escape sequence
        # using a short timeout so we don't block waiting for slow input
        while True:
            r, _, _ = select.select([sys.stdin], [], [], 0.02)
            if not r:
                break
            nb = sys.stdin.buffer.read(1)
            if not nb:
                break
            out.extend(nb)
        # print literal \xHH sequences
        sys.stdout.write(''.join('\\x%02x' % c for c in out))
    finally:
        if old:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)

if __name__ == '__main__':
    main()
