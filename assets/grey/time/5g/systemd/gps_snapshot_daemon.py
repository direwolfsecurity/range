#!/usr/bin/env python3
import json
import os
import time
from datetime import datetime, timezone

SERIAL_DEVICE = "/dev/ttyUSB1"
OUTPUT_DIR = "/var/www/html/temp"
JSON_FILE = os.path.join(OUTPUT_DIR, "gps.json")
RAW_FILE = os.path.join(OUTPUT_DIR, "gps_raw.txt")

READ_WINDOW_SECONDS = 8
SLEEP_SECONDS = 5
BAUD_HINT = 115200  # informational only; pyserial sets this

def nmea_to_decimal(raw, hemi, is_lat=True):
    if not raw or not hemi:
        return None
    try:
        if is_lat:
            deg = int(raw[:2])
            minutes = float(raw[2:])
        else:
            deg = int(raw[:3])
            minutes = float(raw[3:])
        dec = deg + (minutes / 60.0)
        if hemi in ("S", "W"):
            dec *= -1
        return dec
    except Exception:
        return None

def parse_rmc(parts):
    if len(parts) < 10:
        return {}
    return {
        "rmc_time": parts[1],
        "rmc_status": parts[2],
        "lat": nmea_to_decimal(parts[3], parts[4], True) if parts[3] and parts[4] else None,
        "lon": nmea_to_decimal(parts[5], parts[6], False) if parts[5] and parts[6] else None,
        "speed_knots": float(parts[7]) if parts[7] else 0.0,
        "course": float(parts[8]) if parts[8] else 0.0,
        "rmc_date": parts[9],
    }

def parse_gga(parts):
    if len(parts) < 10:
        return {}
    return {
        "gga_time": parts[1],
        "lat": nmea_to_decimal(parts[2], parts[3], True) if parts[2] and parts[3] else None,
        "lon": nmea_to_decimal(parts[4], parts[5], False) if parts[4] and parts[5] else None,
        "fix_quality": parts[6],
        "satellites_used": int(parts[7]) if parts[7].isdigit() else None,
        "hdop": float(parts[8]) if parts[8] else None,
        "altitude_m": float(parts[9]) if parts[9] else None,
    }

def parse_gsv(parts):
    if len(parts) < 4:
        return {}
    return {
        "satellites_in_view": int(parts[3]) if parts[3].isdigit() else None
    }

def atomic_write(path, content):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(content)
    os.replace(tmp, path)

def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    while True:
        payload = {
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "source": SERIAL_DEVICE,
            "status": "no_data",
            "lat": None,
            "lon": None,
            "speed_knots": None,
            "course": None,
            "altitude_m": None,
            "fix_quality": None,
            "satellites_used": None,
            "satellites_in_view": None,
            "hdop": None,
        }

        raw_lines = []
        latest_rmc = {}
        latest_gga = {}
        latest_gsv = {}

        try:
            import serial

            with serial.Serial(SERIAL_DEVICE, 115200, timeout=1) as ser:
                end_time = time.time() + READ_WINDOW_SECONDS

                while time.time() < end_time:
                    line = ser.readline().decode("ascii", errors="ignore").strip()
                    if not line.startswith("$"):
                        continue

                    raw_lines.append(line)
                    parts = line.split(",")

                    sentence = parts[0]
                    if sentence.endswith("RMC"):
                        latest_rmc = parse_rmc(parts)
                    elif sentence.endswith("GGA"):
                        latest_gga = parse_gga(parts)
                    elif sentence.endswith("GSV"):
                        parsed = parse_gsv(parts)
                        if parsed.get("satellites_in_view") is not None:
                            latest_gsv = parsed

            merged = {}
            merged.update(latest_gsv)
            merged.update(latest_gga)
            merged.update(latest_rmc)

            for key, value in merged.items():
                if value is not None:
                    payload[key] = value

            if payload["lat"] is not None and payload["lon"] is not None:
                payload["status"] = "ok"
            elif raw_lines:
                payload["status"] = "nmea_seen"
            else:
                payload["status"] = "no_nmea"

        except Exception as e:
            payload["status"] = "error"
            payload["error"] = str(e)

        atomic_write(JSON_FILE, json.dumps(payload, indent=2))
        atomic_write(RAW_FILE, "\n".join(raw_lines[-200:]))

        time.sleep(SLEEP_SECONDS)

if __name__ == "__main__":
    main()
