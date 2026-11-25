#!/usr/bin/env bash
# install.sh - Dire Wolf range time server
#
# GPS in the 5G modem (SIMCom SIM8200EA-M2 or Quectel RM520N-GL) -> gpsd -> chrony -> NTP for the range,
# plus the satellite dashboard web page.
#
# Usage (run from this folder, on the Pi):
#   sudo bash install.sh                     test mode: shows what it would do, changes nothing
#   sudo bash install.sh --go                does it
#   sudo bash install.sh --offset 0.180 --go sets the GPS offset (README step "Tune the offset")
#   sudo bash install.sh --check             shows GPS, NTP and service status, changes nothing
#
# Safe to run again. Files it replaces are first copied to /var/backups/direwolf-ntp/.
# A tuned offset already on the Pi is kept unless --offset is given.
#
# Licence: CC BY-SA 4.0, Dire Wolf Security.

set -euo pipefail

# ---- Settings. Change these if your modem enumerates differently (dmesg | grep ttyUSB). ----
NMEA_PORT="/dev/ttyUSB1"
AT_PORT="/dev/ttyUSB2"
DISABLE_MODEMMANAGER="yes"   # ModemManager fights us for the AT port. Set "no" once a SIM is in use.
LEAFLET_VERSION="1.9.4"
WEB_ROOT="/var/www/html"
# ---------------------------------------------------------------------------------------------

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHRONY_CONF="/etc/chrony/conf.d/direwolf-gps.conf"
BACKUP_DIR="/var/backups/direwolf-ntp/$(date +%Y%m%d-%H%M%S)"
GO=0
CHECK=0
OFFSET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --go)     GO=1 ;;
        --check)  CHECK=1 ;;
        --offset) OFFSET="${2:-}"; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
    esac
    shift
done

say()  { printf '\n== %s\n' "$*"; }
warn() { printf '   WARNING: %s\n' "$*"; }

# Run a command, or only print it in test mode.
run() {
    if (( GO )); then
        printf '   + %s\n' "$*"
        "$@"
    else
        printf '   would run: %s\n' "$*"
    fi
}

# Copy a file into place. $1 = source text file, $2 = destination, $3 = mode.
# Skips it if unchanged; backs up the old copy if it differs.
put() {
    local src="$1" dest="$2" mode="$3"
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        printf '   unchanged: %s\n' "$dest"
        return
    fi
    if (( GO )); then
        if [[ -f "$dest" ]]; then
            mkdir -p "$BACKUP_DIR$(dirname "$dest")"
            cp -p "$dest" "$BACKUP_DIR$dest"
            printf '   backed up: %s\n' "$dest"
        fi
        install -D -m "$mode" "$src" "$dest"
        printf '   installed: %s\n' "$dest"
    else
        printf '   would install: %s\n' "$dest"
    fi
}

check() {
    say "Services"
    for u in gnss-on.timer gpsd.socket gpsd.service chrony.service gps-snapshot.service apache2.service; do
        printf '   %-22s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"
    done
    say "Modem ports (NMEA $NMEA_PORT, AT $AT_PORT) and what holds them"
    echo "   $(compgen -G '/dev/ttyUSB*' | tr '\n' ' ')"
    [[ -e "$NMEA_PORT" || -e "$AT_PORT" ]] || echo "   no modem ports. Is the HAT's USB cable in?"
    if compgen -G '/dev/ttyUSB*' >/dev/null; then
        fuser -v /dev/ttyUSB* 2>&1 | grep -v '^ *USER' | sed 's/^/   /' || true
    fi
    printf '   ModemManager: %s\n' "$(systemctl is-active ModemManager 2>/dev/null || true)"
    say "GNSS engine: last result of gnss_on.py"
    systemctl is-active -q gnss-on.timer || echo "   gnss-on.timer not running"
    # Only the script's own lines, not systemd's start/stop messages.
    journalctl -u gnss-on.service -n 40 --no-pager -o cat 2>/dev/null \
        | grep -vE '^(Starting|Finished|Failed to start|gnss-on\.service: )' | tail -n 4 | sed 's/^/   /' || true
    say "GPS fix (10 seconds of gpsd reports)"
    if command -v gpspipe >/dev/null; then
        local tpv
        tpv="$(timeout 10 gpspipe -w 2>/dev/null | grep -m1 '"class":"TPV"' || true)"
        if [[ -n "$tpv" ]]; then
            echo "   $(grep -o '"mode":[0-9]\|"time":"[^"]*"' <<<"$tpv" | tr '\n' ' ')"
            echo "   (mode 1 = no fix, 2 = 2D, 3 = 3D)"
        else
            echo "   no report from gpsd"
        fi
    fi
    say "chrony sources (GPS line: * = in use, Reach should reach 377)"
    chronyc sources 2>/dev/null | sed 's/^/   /' || echo "   chrony not answering"
    say "chrony GPS offset (tune with --offset, see README)"
    chronyc sourcestats 2>/dev/null | grep -E '^Name|GPS' | sed 's/^/   /' || true
    say "Dashboard"
    echo "   http://$(hostname -I | awk '{print $1}')/"
}

if (( CHECK )); then check; exit 0; fi

# ---- Preflight ----
say "Preflight"
if [[ $EUID -ne 0 ]]; then echo "   Run with sudo."; exit 1; fi
for f in etc/default/gpsd etc/chrony/conf.d/direwolf-gps.conf opt/gpsdash/gnss_on.py \
         opt/gpsdash/gps_snapshot_daemon.py opt/gpsdash/at.py systemd/gnss-on.service systemd/gnss-on.timer \
         systemd/gps-snapshot.service html/index.html; do
    [[ -f "$HERE/$f" ]] || { echo "   Missing $f. Run this from the repo folder."; exit 1; }
done
[[ -e "$NMEA_PORT" ]] || warn "$NMEA_PORT not found. Is the HAT's USB cable in? (ls /dev/ttyUSB*)"
[[ -e "$AT_PORT"   ]] || warn "$AT_PORT not found."
if [[ -n "$OFFSET" ]] && ! [[ "$OFFSET" =~ ^-?[0-9]*\.?[0-9]+$ ]]; then
    echo "   --offset needs a number in seconds, for example 0.180"; exit 1
fi
(( GO )) || echo "   TEST MODE. Nothing will change. Add --go to do it."

# Build the final config files in a temp folder, with the settings above applied.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

sed "s|^DEVICES=.*|DEVICES=\"$NMEA_PORT\"|" "$HERE/etc/default/gpsd" > "$STAGE/gpsd"
sed "s|gnss_on.py.*|gnss_on.py $AT_PORT|" "$HERE/systemd/gnss-on.service" > "$STAGE/gnss-on.service"

# Offset: --offset wins, then whatever is already on the Pi, then the 0.0 in the repo.
if [[ -z "$OFFSET" && -f "$CHRONY_CONF" ]]; then
    OFFSET="$(grep -oP '^refclock SHM 0 .*offset \K-?[0-9.]+' "$CHRONY_CONF" || true)"
    [[ -n "$OFFSET" ]] && echo "   keeping the offset already on the Pi: $OFFSET s"
fi
sed "s|offset [-0-9.]*|offset ${OFFSET:-0.0}|" "$HERE/etc/chrony/conf.d/direwolf-gps.conf" > "$STAGE/chrony.conf"

# ---- 1. Packages ----
say "1. Packages"
run apt-get update
run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    gpsd gpsd-clients chrony python3-serial apache2 minicom wget

# ---- 2. Stop anything holding the modem ports ----
say "2. Free the modem ports"
for u in gps-snapshot.service gpsd.socket gpsd.service; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1; then run systemctl stop "$u"; fi
done
if pgrep -x minicom >/dev/null; then
    warn "minicom is running and may hold a port. Exit it with Ctrl-A then X."
fi
if [[ "$DISABLE_MODEMMANAGER" == "yes" ]] && systemctl list-unit-files ModemManager.service >/dev/null 2>&1; then
    run systemctl disable --now ModemManager.service
fi

# ---- 3. Files ----
say "3. Files"
put "$STAGE/gpsd"                                "/etc/default/gpsd"                         0644
put "$STAGE/chrony.conf"                         "$CHRONY_CONF"                              0644
put "$HERE/opt/gpsdash/gnss_on.py"               "/opt/gpsdash/gnss_on.py"                   0755
put "$HERE/opt/gpsdash/at.py"                    "/opt/gpsdash/at.py"                        0755
put "$HERE/opt/gpsdash/gps_snapshot_daemon.py"   "/opt/gpsdash/gps_snapshot_daemon.py"       0755
put "$STAGE/gnss-on.service"                     "/etc/systemd/system/gnss-on.service"       0644
put "$HERE/systemd/gnss-on.timer"                "/etc/systemd/system/gnss-on.timer"         0644
put "$HERE/systemd/gps-snapshot.service"         "/etc/systemd/system/gps-snapshot.service"  0644
put "$HERE/html/index.html"                      "$WEB_ROOT/index.html"                      0644
run mkdir -p "$WEB_ROOT/temp" "$WEB_ROOT/vendor/leaflet"
run chown -R www-data:www-data "$WEB_ROOT/temp"

# ---- 4. Leaflet (map library) - downloaded, not stored in the repo ----
say "4. Leaflet $LEAFLET_VERSION (https://leafletjs.com, BSD 2-Clause)"
for f in leaflet.js leaflet.css; do
    if [[ -s "$WEB_ROOT/vendor/leaflet/$f" ]]; then
        printf '   already there: %s\n' "$f"
    else
        run wget -q -O "$WEB_ROOT/vendor/leaflet/$f" "https://unpkg.com/leaflet@$LEAFLET_VERSION/dist/$f"
    fi
done

# ---- 5. Turn on GNSS and start everything ----
say "5. Start services"
run systemctl daemon-reload
run python3 /opt/gpsdash/gnss_on.py "$AT_PORT" \
    || warn "GNSS did not answer yet. The timer retries every 5 minutes; see README troubleshooting."
run systemctl enable --now gnss-on.timer
run systemctl enable gpsd.socket gpsd.service
run systemctl restart gpsd.socket gpsd.service
run systemctl restart chrony.service
run systemctl enable apache2.service
run systemctl enable gps-snapshot.service
run systemctl restart gps-snapshot.service

if (( GO )); then
    [[ -d "$BACKUP_DIR" ]] && echo "   Old files saved in $BACKUP_DIR"
    say "Done. Waiting 15 seconds, then checking."
    sleep 15
    check
    echo
    echo "A cold start can take 1 to 15 minutes to get a fix. Check again with: sudo bash install.sh --check"
else
    say "Test mode finished. Nothing changed. Run again with --go."
fi
