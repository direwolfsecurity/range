#!/usr/bin/env python3
"""Turn on the GNSS engine in the Quectel RM520N-GL if it is off.

The modem forgets this at power-up, so a systemd timer runs this script
at boot and every 5 minutes. It asks first and only acts when GNSS is off.
"""
import sys
import time

import serial

AT_PORT = "/dev/ttyUSB2"


def at(ser, cmd, wait=2.0):
    ser.reset_input_buffer()
    ser.write((cmd + "\r").encode())
    end = time.time() + wait
    buf = ""
    while time.time() < end:
        buf += ser.read(256).decode("ascii", errors="ignore")
        if "OK" in buf or "ERROR" in buf:
            break
    return buf


def main():
    try:
        ser = serial.Serial(AT_PORT, 115200, timeout=0.5)
    except Exception as e:
        print(f"cannot open {AT_PORT}: {e}")
        return 1
    with ser:
        state = at(ser, "AT+QGPS?")
        if "+QGPS: 1" in state:
            print("GNSS already on")
            return 0
        if "+QGPS:" not in state:
            print(f"no answer to AT+QGPS? (got {state!r})")
            return 1
        print(at(ser, 'AT+QGPSCFG="outport","usbnmea"').strip())
        reply = at(ser, "AT+QGPS=1", wait=5.0)
        print(reply.strip())
        return 0 if "OK" in reply else 1


if __name__ == "__main__":
    sys.exit(main())
