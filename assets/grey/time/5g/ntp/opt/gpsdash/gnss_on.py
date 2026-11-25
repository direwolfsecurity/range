#!/usr/bin/env python3
"""Turn on the GNSS (GPS) engine in the 5G modem if it is off.

Works with both modules Waveshare sells on its 5G HAT:
    SIMCom  SIM8200EA-M2   AT+CGPS?  /  AT+CGPS=1
    Quectel RM520N-GL      AT+QGPS?  /  AT+QGPS=1
It asks the modem which one it is (ATI) and uses the right commands.

The modem forgets this at power-up, so a systemd timer runs this script
at boot and every 5 minutes. It asks first and only acts when GNSS is off.
It uses at.py (same folder) for the port, so the two never talk over each other.
After it turns GNSS on, it restarts gpsd so gpsd starts clean on a port that now has data.

Usage: sudo python3 gnss_on.py [AT port, default /dev/ttyUSB2]
"""
import subprocess
import sys
import time

from at import at, flat, open_modem

AT_PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB2"
IDENT_TRIES = 3

# Per module: the query, the reply text that means "on", and the commands to turn it on.
MODULES = {
    "SIMCOM": {
        "query": "AT+CGPS?",
        "on_reply": "+CGPS: 1",
        "turn_on": ["AT+CGPS=1"],
    },
    "QUECTEL": {
        "query": "AT+QGPS?",
        "on_reply": "+QGPS: 1",
        "turn_on": ['AT+QGPSCFG="outport","usbnmea"', "AT+QGPS=1"],
    },
}


def identify(ser):
    """Return (maker, raw ATI reply). Asks up to IDENT_TRIES times."""
    ident = ""
    for _ in range(IDENT_TRIES):
        ident = at(ser, "ATI")
        maker = next((m for m in MODULES if m in ident.upper()), None)
        if maker:
            return maker, ident
        time.sleep(1)
    return None, ident


def restart_gpsd():
    """Restart gpsd if it is running, so it picks up the NMEA that has just started."""
    try:
        subprocess.run(["systemctl", "try-restart", "gpsd.service"], check=True, timeout=30)
        print("gpsd restarted")
    except Exception as e:
        print(f"could not restart gpsd: {e}")


def main():
    try:
        modem = open_modem(AT_PORT)
        ser = modem.__enter__()
    except Exception as e:
        print(f"cannot open {AT_PORT}: {e}")
        return 1
    turned_on = False
    try:
        maker, ident = identify(ser)
        if maker is None:
            if not ident.strip():
                print(f"no answer on {AT_PORT}. Is this the AT port? (dmesg | grep ttyUSB)")
            else:
                print(f"unknown modem after {IDENT_TRIES} tries: {flat(ident)}")
            return 1
        mod = MODULES[maker]

        state = at(ser, mod["query"])
        if mod["on_reply"] in state:
            print(f"{maker}: GNSS already on")
            return 0
        print(f"{maker}: {mod['query']} -> {flat(state)}")

        for cmd in mod["turn_on"]:
            print(f"{maker}: {cmd} -> {flat(at(ser, cmd))}")

        # The only answer that counts is the modem saying it is on.
        time.sleep(1)
        state = at(ser, mod["query"])
        if mod["on_reply"] in state:
            print(f"{maker}: GNSS on")
            turned_on = True
            return 0
        print(f"{maker}: still off after turn-on ({flat(state)})")
        return 1
    finally:
        modem.__exit__(None, None, None)
        # After the AT port is released, so the restart never waits on the modem.
        if turned_on:
            restart_gpsd()


if __name__ == "__main__":
    sys.exit(main())
