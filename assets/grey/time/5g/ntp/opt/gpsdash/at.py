#!/usr/bin/env python3
"""Send AT commands to the modem and print each reply. A safer stand-in for minicom.

Usage:
    sudo python3 at.py /dev/ttyUSB2 'ATI' 'AT+CGPS?'

Detailed errors (AT+CMEE=2) are switched on first, so a failure says why.

gnss_on.py imports open_modem() and at() from here. Both take a lock file first,
so two programs never talk to the AT port at the same time and mix up the replies.
"""
import contextlib
import fcntl
import re
import sys
import time

import serial

LOCK_FILE = "/run/lock/direwolf-modem-at.lock"
LOCK_WAIT_SECONDS = 30

# A reply is finished when it ends with one of these result lines.
FINAL = re.compile(r"\r\n(OK|ERROR|\+CME ERROR:[^\r\n]*|\+CMS ERROR:[^\r\n]*)\r\n")


@contextlib.contextmanager
def open_modem(port):
    """Open the AT port while holding the lock. Turns echo off and detailed errors on."""
    with open(LOCK_FILE, "w") as lock:
        end = time.time() + LOCK_WAIT_SECONDS
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.time() > end:
                    raise TimeoutError(f"another program has held {LOCK_FILE} for {LOCK_WAIT_SECONDS} s")
                time.sleep(0.5)
        with serial.Serial(port, 115200, timeout=0.3) as ser:
            time.sleep(0.2)
            ser.reset_input_buffer()  # drop anything left over from before
            at(ser, "ATE0")       # no echo, so replies are easier to read
            at(ser, "AT+CMEE=2")  # errors in words, not just "ERROR"
            yield ser


def at(ser, cmd, wait=5.0):
    """Send one command and return its whole reply, up to and including OK or ERROR."""
    ser.reset_input_buffer()
    ser.write((cmd + "\r").encode())
    end = time.time() + wait
    buf = ""
    while time.time() < end:
        buf += ser.read(256).decode("ascii", errors="ignore")
        if FINAL.search(buf):
            break
    return buf


def flat(reply):
    """Reply on one line, for logs."""
    return " | ".join(line.strip() for line in reply.splitlines() if line.strip()) or "(no reply)"


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    port, cmds = sys.argv[1], sys.argv[2:]
    with open_modem(port) as ser:
        for cmd in cmds:
            print(f">> {cmd}")
            reply = at(ser, cmd)
            lines = [line.strip() for line in reply.splitlines() if line.strip()]
            for line in lines or ["(no reply)"]:
                print(f"   {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
