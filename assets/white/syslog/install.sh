#!/usr/bin/env bash
# install.sh - Dire Wolf range syslog server (rsyslog). Collects logs from tiles, the MQTT broker, DNS and more.
#
# Usage (run from this folder, on Ubuntu Server 24.04):
#   sudo bash install.sh            test mode: shows what it would do, changes nothing
#   sudo bash install.sh --go       does it, then prints a status check
#   sudo bash install.sh --check    status, ports, log files, a self-test and the last log lines
#
# Safe to run again. Files it replaces are first copied to /var/backups/direwolf-syslog/.
#
# License: GPL-3.0, Dire Wolf Security.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HERE/range-syslog.conf"
RSYSLOG_FILE="/etc/rsyslog.d/10-direwolf-range.conf"
ROTATE_FILE="/etc/logrotate.d/direwolf-range"
BACKUP_DIR="/var/backups/direwolf-syslog/$(date +%Y%m%d-%H%M%S)"
GO=0
CHECK=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --go)    GO=1 ;;
        --check) CHECK=1 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
    esac
    shift
done

say()  { printf '\n== %s\n' "$*"; }
warn() { printf '   WARNING: %s\n' "$*"; }
die()  { printf '   ERROR: %s\n' "$*"; exit 1; }

# Run a command, or only print it in test mode.
run() {
    if (( GO )); then
        printf '   + %s\n' "$*"
        "$@"
    else
        printf '   would run: %s\n' "$*"
    fi
}

# Copy a file into place. $1 = source, $2 = destination, $3 = mode.
# Skips it if unchanged; backs up the old copy if it differs. Sets CHANGED=1 when it installs.
CHANGED=0
put() {
    local src="$1" dest="$2" mode="$3"
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        printf '   unchanged: %s\n' "$dest"
        return
    fi
    CHANGED=1
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

[[ -f "$SETTINGS" ]] || die "Missing range-syslog.conf. Run this from the repo folder (assets/white/syslog)."
# shellcheck source=range-syslog.conf
source "$SETTINGS"
[[ "$PORT" =~ ^[0-9]+$ ]]      || die "PORT must be a number."
[[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || die "KEEP_DAYS must be a number."
[[ "$TCP" == "yes" || "$TCP" == "no" ]] || die "TCP must be yes or no."
[[ "$LOG_DIR" == /var/log/* ]] || die "LOG_DIR must be under /var/log (rsyslog's AppArmor profile only allows that)."

check() {
    say "Service"
    printf '   %-18s %s\n' "rsyslog.service" "$(systemctl is-active rsyslog.service 2>/dev/null || true)"
    say "Listening on port $PORT"
    ss -lnup 2>/dev/null | grep -E ":$PORT\b" | awk '{print "   UDP " $4}' || true
    ss -lntp 2>/dev/null | grep -E ":$PORT\b" | awk '{print "   TCP " $4}' || true
    say "Self-test: send one UDP message to ourselves"
    local tag="direwolf-selftest" word="hello-$$-$RANDOM"
    logger -n 127.0.0.1 -P "$PORT" -d -t "$tag" "$word" 2>/dev/null || true
    sleep 1
    if grep -q "$word" "$LOG_DIR/all.log" 2>/dev/null; then
        echo "   received and written to $LOG_DIR/all.log"
    else
        echo "   NOT received. See 'If something is wrong' in the README."
    fi
    say "DNS: what does $SERVER_NAME point to?"
    local ans
    ans="$(getent hosts "$SERVER_NAME" | awk '{print $1}' | tr '\n' ' ' || true)"
    echo "   ${ans:-does not resolve here}   (this server: $(hostname -I | tr '\n' ' '))"
    say "Log files in $LOG_DIR (one per sending address)"
    ls -lh "$LOG_DIR" 2>/dev/null | tail -n +2 | awk '{print "   " $5 "\t" $9}' || echo "   none yet"
    say "Last 10 lines of $LOG_DIR/all.log"
    tail -n 10 "$LOG_DIR/all.log" 2>/dev/null | sed 's/^/   /' || echo "   empty"
}

if (( CHECK )); then check; exit 0; fi

# ---- Preflight ----
say "Preflight"
[[ $EUID -eq 0 ]] || die "Run with sudo."
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || warn "Written for Ubuntu Server 24.04. This is ${PRETTY_NAME:-unknown}."
fi
echo "   port:      $PORT (UDP$( [[ "$TCP" == "yes" ]] && echo " and TCP" ))"
echo "   logs:      $LOG_DIR, kept $KEEP_DAYS days"
(( GO )) || echo "   TEST MODE. Nothing will change. Add --go to do it."

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# The rsyslog rules. Messages from the network go to their own "range" ruleset,
# so they never mix with this server's own logs in /var/log/syslog.
{
    echo "# Made by Dire Wolf syslog install.sh. Edit range-syslog.conf and re-run instead."
    echo
    echo "# Each line shows the address the message REALLY came from (from=) and the name the"
    echo "# device CLAIMS to be (host=). If they do not match the device list, someone may be faking logs."
    echo "template(name=\"RangeLine\" type=\"string\""
    echo "         string=\"%timegenerated:::date-rfc3339% from=%fromhost-ip% host=%hostname% %syslogtag%%msg:::sp-if-no-1st-sp%%msg:::drop-last-lf%\\n\")"
    echo "template(name=\"RangeFile\" type=\"string\" string=\"$LOG_DIR/%fromhost-ip%.log\")"
    echo
    echo "ruleset(name=\"range\") {"
    echo "    action(type=\"omfile\" file=\"$LOG_DIR/all.log\" template=\"RangeLine\")"
    echo "    action(type=\"omfile\" dynaFile=\"RangeFile\" template=\"RangeLine\" dynaFileCacheSize=\"200\")"
    echo "    stop"
    echo "}"
    echo
    echo "module(load=\"imudp\")"
    echo "input(type=\"imudp\" port=\"$PORT\" ruleset=\"range\")"
    if [[ "$TCP" == "yes" ]]; then
        echo "module(load=\"imtcp\")"
        echo "input(type=\"imtcp\" port=\"$PORT\" ruleset=\"range\")"
    fi
} > "$STAGE/rsyslog.conf"

{
    echo "# Made by Dire Wolf syslog install.sh: keep $KEEP_DAYS days of range logs."
    echo "$LOG_DIR/*.log {"
    echo "    daily"
    echo "    rotate $KEEP_DAYS"
    echo "    missingok"
    echo "    notifempty"
    echo "    compress"
    echo "    delaycompress"
    echo "    sharedscripts"
    echo "    postrotate"
    echo "        /usr/lib/rsyslog/rsyslog-rotate"
    echo "    endscript"
    echo "}"
} > "$STAGE/logrotate"

# ---- 1. Packages ----
say "1. Packages"
if command -v rsyslogd >/dev/null && command -v logrotate >/dev/null; then
    echo "   already installed: rsyslog, logrotate"
else
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y rsyslog logrotate
fi

# ---- 2. Log folder (rsyslog runs as user syslog) ----
say "2. Log folder"
if [[ -d "$LOG_DIR" ]]; then
    echo "   already there: $LOG_DIR"
else
    run install -d -m 0750 -o syslog -g adm "$LOG_DIR"
fi

# ---- 3. Config ----
say "3. Config"
put "$STAGE/rsyslog.conf" "$RSYSLOG_FILE" 0644
put "$STAGE/logrotate"    "$ROTATE_FILE"  0644
if (( GO )) && (( CHANGED )); then
    rsyslogd -N1 -f /etc/rsyslog.conf >/dev/null 2>"$STAGE/n1" \
        || { cat "$STAGE/n1"; die "rsyslog does not like the new config. Old files are in $BACKUP_DIR."; }
    echo "   rsyslog config check passed"
fi

# ---- 4. Firewall (only if ufw is turned on) ----
say "4. Firewall"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    run ufw allow "$PORT/udp"
    [[ "$TCP" == "yes" ]] && run ufw allow "$PORT/tcp"
else
    echo "   ufw is off. Nothing to open."
fi

# ---- 5. Start ----
say "5. Start rsyslog"
run systemctl enable rsyslog.service
if (( CHANGED )) || ! systemctl is-active -q rsyslog.service; then
    run systemctl restart rsyslog.service
else
    echo "   nothing changed, rsyslog left running"
fi

if (( GO )); then
    [[ -d "$BACKUP_DIR" ]] && echo "   Old files saved in $BACKUP_DIR"
    sleep 2
    check
else
    say "Test mode finished. Nothing changed. Run again with --go."
fi
