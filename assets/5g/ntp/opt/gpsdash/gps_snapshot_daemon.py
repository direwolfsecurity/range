#!/usr/bin/env python3
"""GPS snapshot daemon, version 2.

Version 1 read /dev/ttyUSB1 itself. That port now belongs to gpsd, so the
same port can also feed chrony (NTP). This version asks gpsd for the data
and writes the same files the dashboard already reads:

    /var/www/html/temp/gps.json         position, fix, time, NTP state
    /var/www/html/temp/satellites.json  one entry per satellite in view
"""
import json
import os
import socket
import subprocess
import threading
import time
from datetime import datetime, timezone

GPSD_HOST = "127.0.0.1"
GPSD_PORT = 2947
OUTPUT_DIR = "/var/www/html/temp"
JSON_FILE = os.path.join(OUTPUT_DIR, "gps.json")
SAT_FILE = os.path.join(OUTPUT_DIR, "satellites.json")

WRITE_EVERY_SECONDS = 1
STALE_SECONDS = 10       # gpsd data older than this counts as "no data"
NTP_EVERY_SECONDS = 10   # how often to ask chrony for its state
MS_TO_KNOTS = 1.94384

lock = threading.Lock()
state = {"tpv": {}, "sky": {}, "sats": [], "tpv_at": 0.0, "sky_at": 0.0,
         "connected": False}


def gpsd_reader():
    """Stay connected to gpsd and keep the newest TPV and SKY reports."""
    while True:
        try:
            with socket.create_connection((GPSD_HOST, GPSD_PORT), timeout=10) as s:
                s.sendall(b'?WATCH={"enable":true,"json":true}\n')
                with lock:
                    state["connected"] = True
                for line in s.makefile("r", encoding="ascii", errors="ignore"):
                    try:
                        msg = json.loads(line)
                    except ValueError:
                        continue
                    now = time.time()
                    with lock:
                        if msg.get("class") == "TPV":
                            state["tpv"] = msg
                            state["tpv_at"] = now
                        elif msg.get("class") == "SKY":
                            # Some SKY reports carry only DOP values.
                            state["sky"].update(msg)
                            if "satellites" in msg:
                                state["sats"] = msg["satellites"]
                            state["sky_at"] = now
        except Exception:
            pass
        with lock:
            state["connected"] = False
        time.sleep(3)


def ntp_status():
    """Ask chrony what it is synced to. Returns {} if chrony is not there."""
    try:
        out = subprocess.run(["chronyc", "-c", "tracking"], capture_output=True,
                             text=True, timeout=3).stdout.strip().split(",")
        return {
            "ntp_source": out[1],
            "ntp_stratum": int(out[2]),
            "ntp_offset_s": float(out[4]),
            "ntp_leap": out[13],
        }
    except Exception:
        return {}


def atomic_write(path, content):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(content)
    os.replace(tmp, path)


def build(ntp):
    now = time.time()
    with lock:
        connected = state["connected"]
        tpv = dict(state["tpv"]) if now - state["tpv_at"] < STALE_SECONDS else {}
        fresh_sky = now - state["sky_at"] < STALE_SECONDS
        sky = dict(state["sky"]) if fresh_sky else {}
        sats = list(state["sats"]) if fresh_sky else []

    mode = tpv.get("mode", 0)
    speed = tpv.get("speed")
    used = [s for s in sats if s.get("used")]

    payload = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "gps_time_utc": tpv.get("time"),
        "source": "gpsd",
        "status": "no_data",
        "lat": tpv.get("lat") if mode >= 2 else None,
        "lon": tpv.get("lon") if mode >= 2 else None,
        "speed_knots": round(speed * MS_TO_KNOTS, 2) if speed is not None else None,
        "course": tpv.get("track"),
        "altitude_m": tpv.get("altMSL", tpv.get("alt")) if mode >= 3 else None,
        "fix_quality": "1" if mode >= 2 else "0",
        "fix_mode": {2: "2D", 3: "3D"}.get(mode, "none"),
        "satellites_used": len(used) if sats else None,
        "satellites_in_view": len(sats) if sats else None,
        "hdop": sky.get("hdop"),
    }
    payload.update(ntp)

    if not connected:
        payload["status"] = "no_gpsd"
    elif payload["lat"] is not None and payload["lon"] is not None:
        payload["status"] = "ok"
    elif tpv or sats:
        payload["status"] = "no_fix"
    else:
        payload["status"] = "no_nmea"

    sat_payload = {
        "timestamp_utc": payload["timestamp_utc"],
        "satellites": sorted(
            [{
                "prn": s.get("PRN"),
                "gnss": {0: "GPS", 1: "SBAS", 2: "Galileo", 3: "BeiDou",
                         5: "QZSS", 6: "GLONASS"}.get(s.get("gnssid"), ""),
                "snr": s.get("ss"),
                "elevation": s.get("el"),
                "azimuth": s.get("az"),
                "used": bool(s.get("used")),
            } for s in sats],
            key=lambda x: (not x["used"], -(x["snr"] or 0)),
        ),
    }
    return payload, sat_payload


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    threading.Thread(target=gpsd_reader, daemon=True).start()
    ntp, ntp_at = {}, 0.0
    while True:
        if time.time() - ntp_at >= NTP_EVERY_SECONDS:
            ntp, ntp_at = ntp_status(), time.time()
        payload, sat_payload = build(ntp)
        atomic_write(JSON_FILE, json.dumps(payload, indent=2))
        atomic_write(SAT_FILE, json.dumps(sat_payload, indent=2))
        time.sleep(WRITE_EVERY_SECONDS)


if __name__ == "__main__":
    main()
