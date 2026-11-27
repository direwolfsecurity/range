#!/usr/bin/env bash
# install.sh - Dire Wolf range MQTT broker (Mosquitto) for Cyber City tiles.
#
# Usage (run from this folder, on Ubuntu Server 24.04):
#   sudo bash install.sh                        test mode: shows what it would do, changes nothing
#   sudo bash install.sh --go                   does it (uses the mode in mqtt.conf, or the last one you set)
#   sudo bash install.sh --mode open --go       anyone can read and write every topic (attack labs)
#   sudo bash install.sh --mode secure --go     logins and per-tile rights from users.conf (defend labs)
#   sudo bash install.sh --new-password NAME --go   makes a new password for one user and shows it once
#   sudo bash install.sh --check                status, listeners, users, a self-test and the last log lines
#   sudo bash install.sh --cert                 prints the TLS certificate (to paste into ESP32 code)
#
# Other options: --tls yes|no   --anonymous-read yes|no   --syslog HOST (or --syslog none)
#   Options you give with --go are remembered for the next run. --forget goes back to mqtt.conf.
#
# Safe to run again. Files it replaces are first copied to /var/backups/direwolf-mqtt/.
# Passwords are never saved in plain text. Only their hashes are kept, in /etc/mosquitto/passwd.
#
# License: GPL-3.0, Dire Wolf Security.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HERE/mqtt.conf"
USERS="$HERE/users.conf"

CONF_FILE="/etc/mosquitto/conf.d/direwolf.conf"
PASSWD_FILE="/etc/mosquitto/passwd"
ACL_FILE="/etc/mosquitto/acl"
CERT_DIR="/etc/mosquitto/certs"
SAVED_FILE="/etc/mosquitto/direwolf-settings"
RSYSLOG_FILE="/etc/rsyslog.d/60-direwolf-mqtt.conf"
LOG_FILE="/var/log/mosquitto/mosquitto.log"
BACKUP_DIR="/var/backups/direwolf-mqtt/$(date +%Y%m%d-%H%M%S)"

GO=0
CHECK=0
SHOW_CERT=0
NEW_PASSWORD_FOR=""
OPT_MODE=""
OPT_TLS=""
OPT_ANON=""
OPT_SYSLOG=""
FORGET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --go)             GO=1 ;;
        --check)          CHECK=1 ;;
        --cert)           SHOW_CERT=1 ;;
        --mode)           OPT_MODE="${2:-}"; shift ;;
        --tls)            OPT_TLS="${2:-}"; shift ;;
        --anonymous-read) OPT_ANON="${2:-}"; shift ;;
        --syslog)         OPT_SYSLOG="${2:-}"; shift ;;
        --new-password)   NEW_PASSWORD_FOR="${2:-}"; shift ;;
        --forget)         FORGET=1 ;;
        -h|--help)        sed -n '2,20p' "$0"; exit 0 ;;
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

# Copy a file into place. $1 = source, $2 = destination, $3 = mode, $4 = owner (optional).
# Skips it if unchanged; backs up the old copy if it differs. Sets CHANGED=1 when it installs.
CHANGED=0
put() {
    local src="$1" dest="$2" mode="$3" owner="${4:-root:root}"
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
        install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dest"
        printf '   installed: %s\n' "$dest"
    else
        printf '   would install: %s\n' "$dest"
    fi
}

# Remove a file we made earlier (backed up first).
remove() {
    local dest="$1"
    [[ -f "$dest" ]] || return 0
    CHANGED=1
    if (( GO )); then
        mkdir -p "$BACKUP_DIR$(dirname "$dest")"
        mv "$dest" "$BACKUP_DIR$dest"
        printf '   removed (saved in backups): %s\n' "$dest"
    else
        printf '   would remove: %s\n' "$dest"
    fi
}

# A readable random password, like "k7mq-x9pt-4tnb". No 0/o or 1/l, so it is easy to type into a sketch.
make_password() {
    local raw
    raw="$(LC_ALL=C tr -dc 'abcdefghijkmnpqrstuvwxyz23456789' < /dev/urandom | head -c 12 || true)"
    echo "${raw:0:4}-${raw:4:4}-${raw:8:4}"
}

yes_no() {
    case "$1" in
        yes|no) return 0 ;;
        *) return 1 ;;
    esac
}

# ---- Settings: options win, then what is saved on the server (mode only), then mqtt.conf ----
[[ -f "$SETTINGS" ]] || die "Missing mqtt.conf. Run this from the repo folder (assets/grey/mqtt)."
[[ -f "$USERS" ]]    || die "Missing users.conf. Run this from the repo folder (assets/grey/mqtt)."
# shellcheck source=mqtt.conf
source "$SETTINGS"

# What --go set last time is saved on the server, so "--mode secure" stays secure on the next run.
# --forget ignores the saved settings and goes back to mqtt.conf.
FROM="mqtt.conf"
if [[ -f "$SAVED_FILE" ]] && (( ! FORGET )); then
    while IFS='=' read -r key value; do
        case "$key" in
            MODE|TLS|ANONYMOUS_READ|SYSLOG_HOST) printf -v "$key" '%s' "$value" ;;
        esac
    done < "$SAVED_FILE"
    FROM="mqtt.conf, then the settings saved in $SAVED_FILE"
fi
if [[ -n "$OPT_MODE$OPT_TLS$OPT_ANON$OPT_SYSLOG" ]]; then
    FROM="$FROM, then this run's options"
fi
[[ -n "$OPT_MODE" ]] && MODE="$OPT_MODE"
[[ -n "$OPT_TLS" ]]  && TLS="$OPT_TLS"
[[ -n "$OPT_ANON" ]] && ANONYMOUS_READ="$OPT_ANON"
if [[ -n "$OPT_SYSLOG" ]]; then
    SYSLOG_HOST="$OPT_SYSLOG"
    [[ "$SYSLOG_HOST" == "none" ]] && SYSLOG_HOST=""
fi

[[ "$MODE" == "open" || "$MODE" == "secure" ]] || die "MODE must be open or secure (got '$MODE')."
yes_no "$TLS"            || die "TLS must be yes or no (got '$TLS')."
yes_no "$ANONYMOUS_READ" || die "ANONYMOUS_READ must be yes or no (got '$ANONYMOUS_READ')."

# ---- Read users.conf into an ACL file. Stops on the first bad line. ----
# Fills USER_NAMES (in file order) and writes the ACL to $1.
USER_NAMES=()
build_acl() {
    local out="$1" line name kind rest perm topic tile id lineno=0
    {
        echo "# /etc/mosquitto/acl - made by install.sh from users.conf. Edit users.conf, not this file."
        echo "# Rules before the first 'user' line are for clients with no login."
        echo
        if [[ "$ANONYMOUS_READ" == "yes" ]]; then
            echo "# ANONYMOUS_READ=yes: anyone may watch the city, nobody without a login may control it."
            echo "topic read cybercity/#"
            echo
        fi
    } > "$out"
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%%#*}"                    # drop comments
        [[ -z "${line// /}" ]] && continue
        read -r name kind rest <<< "$line"
        [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "users.conf line $lineno: '$name' is not a good name (lowercase letters, numbers and dashes)."
        for n in "${USER_NAMES[@]}"; do
            [[ "$n" == "$name" ]] && die "users.conf line $lineno: '$name' is listed twice."
        done
        USER_NAMES+=("$name")
        echo "user $name" >> "$out"
        case "$kind" in
            teacher)
                echo "topic readwrite #" >> "$out"
                echo "topic read \$SYS/#" >> "$out" ;;
            monitor)
                echo "topic read #" >> "$out"
                echo "topic read \$SYS/#" >> "$out" ;;
            tile)
                [[ "$name" =~ ^([a-z0-9-]+)-([0-9]+)$ ]] || die "users.conf line $lineno: a tile name must end in -<number>, like intersection-1."
                tile="${BASH_REMATCH[1]}"; id="${BASH_REMATCH[2]}"
                echo "topic readwrite cybercity/$tile/$id/#" >> "$out"
                echo "topic read cybercity/city/alert" >> "$out" ;;
            *)
                die "users.conf line $lineno: kind must be teacher, monitor or tile (got '$kind')." ;;
        esac
        # Extra rights come in pairs: read|write|readwrite <topic>
        set -- $rest
        while [[ $# -gt 0 ]]; do
            perm="$1"; topic="${2:-}"
            [[ "$perm" =~ ^(read|write|readwrite)$ ]] || die "users.conf line $lineno: '$perm' should be read, write or readwrite."
            [[ -n "$topic" ]] || die "users.conf line $lineno: '$perm' needs a topic after it."
            echo "topic $perm $topic" >> "$out"
            shift 2
        done
        echo >> "$out"
    done < "$USERS"
    (( ${#USER_NAMES[@]} > 0 )) || die "users.conf has no users."
}

# ---- Build the broker's config file ----
build_conf() {
    local out="$1"
    {
        echo "# /etc/mosquitto/conf.d/direwolf.conf - made by install.sh. Edit mqtt.conf and re-run instead."
        echo "# Mode: $MODE"
        echo
        echo "# Plain MQTT. Anyone on the network can read these packets, logins included."
        echo "listener $PORT"
        if [[ "$TLS" == "yes" ]]; then
            echo
            echo "# Encrypted MQTT. Clients must trust $CERT_DIR/server.crt (see: install.sh --cert)."
            echo "listener $TLS_PORT"
            echo "certfile $CERT_DIR/server.crt"
            echo "keyfile $CERT_DIR/server.key"
            echo "tls_version tlsv1.2"
        fi
        echo
        if [[ "$MODE" == "open" ]]; then
            echo "# OPEN: no login, no rules. Every client can read and write every topic."
            echo "allow_anonymous true"
        else
            echo "# SECURE: logins from $PASSWD_FILE, rights from $ACL_FILE."
            if [[ "$ANONYMOUS_READ" == "yes" ]]; then
                echo "# Clients with no login may connect, but the ACL only lets them read cybercity/#."
                echo "allow_anonymous true"
            else
                echo "allow_anonymous false"
            fi
            echo "password_file $PASSWD_FILE"
            echo "acl_file $ACL_FILE"
        fi
        echo
        echo "# Logging: who connects, who subscribes to what. This is how defenders spot a '#' listener."
        echo "log_type error"
        echo "log_type warning"
        echo "log_type notice"
        echo "log_type information"
        echo "log_type subscribe"
        echo "log_type unsubscribe"
        echo "connection_messages true"
        echo "log_timestamp_format %Y-%m-%dT%H:%M:%S"
        if [[ -n "$SYSLOG_HOST" ]]; then
            echo "log_dest syslog"
        fi
    } > "$out"
}

# ---- The status check ----
self_test() {
    local topic="cybercity/selftest/$$" got="" pub_ok=1
    command -v mosquitto_sub >/dev/null || { echo "   mosquitto-clients not installed"; return; }
    # Listen for one message for up to 4 seconds, as a client with no login.
    timeout 6 mosquitto_sub -h 127.0.0.1 -p "$PORT" -t "$topic" -C 1 -W 4 > /tmp/direwolf-mqtt-test.$$ 2>&1 &
    local sub_pid=$!
    sleep 1
    mosquitto_pub -h 127.0.0.1 -p "$PORT" -t "$topic" -m "hello" -q 1 >/dev/null 2>&1 || pub_ok=0
    wait "$sub_pid" 2>/dev/null || true
    got="$(cat /tmp/direwolf-mqtt-test.$$ 2>/dev/null || true)"
    rm -f /tmp/direwolf-mqtt-test.$$
    if [[ "$got" == "hello" ]]; then
        echo "   no login: can read AND write  (expected in open mode)"
    elif grep -qi "not authori" <<< "$got"; then
        echo "   no login: refused             (expected in secure mode)"
    elif (( pub_ok )) && [[ -z "$got" || "$got" == *"Timed out"* ]]; then
        echo "   no login: can connect, but the test message did not arrive (expected in secure mode with ANONYMOUS_READ=yes)"
    else
        echo "   no login: $got"
    fi
}

check() {
    local saved="(not set)"
    [[ -f "$SAVED_FILE" ]] && saved="$(grep '^MODE=' "$SAVED_FILE" | cut -d= -f2)"
    say "Broker"
    printf '   %-22s %s\n' "mosquitto.service" "$(systemctl is-active mosquitto.service 2>/dev/null || true)"
    printf '   %-22s %s\n' "mode on this server" "$saved"
    printf '   %-22s %s\n' "version" "$( { mosquitto -h 2>/dev/null || true; } | head -n1)"
    say "Listening ports"
    ss -ltnp 2>/dev/null | grep -E ":($PORT|$TLS_PORT)\b" | awk '{print "   " $4}' || true
    ss -ltn 2>/dev/null | grep -qE ":$PORT\b" || echo "   nothing on port $PORT"
    say "Logins (secure mode)"
    if [[ -f "$PASSWD_FILE" ]]; then
        echo "   $(cut -d: -f1 "$PASSWD_FILE" | tr '\n' ' ')"
    else
        echo "   none yet"
    fi
    say "Self-test as a client with no login"
    self_test
    say "DNS: what does $SERVER_NAME point to?"
    local ans
    ans="$(getent hosts "$SERVER_NAME" | awk '{print $1}' | tr '\n' ' ' || true)"
    echo "   ${ans:-does not resolve here}   (this server: $(hostname -I | tr '\n' ' '))"
    if [[ -f "$RSYSLOG_FILE" ]]; then
        say "Log copy sent to"
        echo "   $(grep -oE '@[^ ]+' "$RSYSLOG_FILE" | head -n1 | tr -d '@') (UDP)"
    fi
    say "Last 12 log lines ($LOG_FILE)"
    tail -n 12 "$LOG_FILE" 2>/dev/null | sed 's/^/   /' || echo "   no log yet"
}

if (( CHECK )); then check; exit 0; fi

if (( SHOW_CERT )); then
    [[ -f "$CERT_DIR/server.crt" ]] || die "No certificate yet. Set TLS=\"yes\" (or --tls yes) and run with --go."
    openssl x509 -in "$CERT_DIR/server.crt" -noout -subject -ext subjectAltName -enddate | sed 's/^/# /'
    cat "$CERT_DIR/server.crt"
    exit 0
fi

# ---- Preflight ----
say "Preflight"
[[ $EUID -eq 0 ]] || die "Run with sudo."
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || warn "Written for Ubuntu Server 24.04. This is ${PRETTY_NAME:-unknown}."
fi
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
build_acl "$STAGE/acl"
build_conf "$STAGE/direwolf.conf"
if [[ -n "$NEW_PASSWORD_FOR" ]]; then
    found=0
    for n in "${USER_NAMES[@]}"; do [[ "$n" == "$NEW_PASSWORD_FOR" ]] && found=1; done
    (( found )) || die "'$NEW_PASSWORD_FOR' is not in users.conf."
fi
echo "   settings from:  $FROM"
echo "   mode:           $MODE"
echo "   plain port:     $PORT"
echo "   TLS:            $TLS$( [[ "$TLS" == "yes" ]] && echo " on port $TLS_PORT" )"
[[ "$MODE" == "secure" ]] && echo "   anonymous read: $ANONYMOUS_READ"
echo "   users.conf:     ${USER_NAMES[*]}"
echo "   syslog copy:    ${SYSLOG_HOST:-off}"
(( GO )) || echo "   TEST MODE. Nothing will change. Add --go to do it."

# ---- 1. Packages ----
say "1. Packages"
if command -v mosquitto >/dev/null && command -v mosquitto_passwd >/dev/null && command -v mosquitto_sub >/dev/null; then
    echo "   already installed: mosquitto, mosquitto-clients"
else
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y mosquitto mosquitto-clients openssl
fi

# ---- 2. Logins (only the password hashes are stored) ----
say "2. Logins"
NEW_LOGINS=()
# mosquitto_passwd wants the file owned by root while it edits it. The broker wants it owned by mosquitto.
if (( GO )); then
    [[ -f "$PASSWD_FILE" ]] || install -m 0600 /dev/null "$PASSWD_FILE"
    chown root:root "$PASSWD_FILE"
fi
for name in "${USER_NAMES[@]}"; do
    if [[ -f "$PASSWD_FILE" ]] && grep -q "^$name:" "$PASSWD_FILE" && [[ "$name" != "$NEW_PASSWORD_FOR" ]]; then
        printf '   has a password: %s\n' "$name"
        continue
    fi
    if (( GO )); then
        pw="$(make_password)"
        mosquitto_passwd -b "$PASSWD_FILE" "$name" "$pw"
        NEW_LOGINS+=("$name  $pw")
        CHANGED=1
        printf '   new password: %s\n' "$name"
    else
        printf '   would make a password for: %s\n' "$name"
    fi
done
# Names removed from users.conf lose their login.
if [[ -f "$PASSWD_FILE" ]]; then
    while IFS=: read -r old _; do
        [[ -z "$old" ]] && continue
        keep=0
        for n in "${USER_NAMES[@]}"; do [[ "$n" == "$old" ]] && keep=1; done
        if (( ! keep )); then
            CHANGED=1
            run mosquitto_passwd -D "$PASSWD_FILE" "$old"
        fi
    done < <(cut -d: -f1 "$PASSWD_FILE")
fi
if (( GO )) && [[ -f "$PASSWD_FILE" ]]; then
    chown mosquitto:mosquitto "$PASSWD_FILE"
    chmod 0600 "$PASSWD_FILE"
fi
[[ "$MODE" == "open" ]] && echo "   (open mode does not use these logins, but keeps them for when you switch to secure)"

# ---- 3. TLS certificate (only if TLS=yes) ----
say "3. TLS certificate"
if [[ "$TLS" != "yes" ]]; then
    echo "   TLS is off. Skipped."
elif [[ -f "$CERT_DIR/server.crt" && -f "$CERT_DIR/server.key" ]]; then
    echo "   keeping the certificate already in $CERT_DIR"
else
    # A self-signed certificate: clients trust this one file. No CA key is made or kept.
    IP="$(hostname -I | awk '{print $1}')"
    run mkdir -p "$CERT_DIR"
    run openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=$SERVER_NAME" -addext "subjectAltName=DNS:$SERVER_NAME,IP:$IP" \
        -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt"
    run chown mosquitto:mosquitto "$CERT_DIR/server.key" "$CERT_DIR/server.crt"
    run chmod 0600 "$CERT_DIR/server.key"
    CHANGED=1
fi

# ---- 4. Broker config and rights ----
say "4. Broker config"
put "$STAGE/direwolf.conf" "$CONF_FILE" 0644
put "$STAGE/acl"           "$ACL_FILE"  0600 mosquitto:mosquitto
if (( GO )); then
    printf 'MODE=%s\nTLS=%s\nANONYMOUS_READ=%s\nSYSLOG_HOST=%s\n' \
        "$MODE" "$TLS" "$ANONYMOUS_READ" "$SYSLOG_HOST" > "$SAVED_FILE"
fi

# ---- 5. Copy of the log to the range syslog server ----
say "5. Syslog copy"
if [[ -n "$SYSLOG_HOST" ]]; then
    printf '# Made by Dire Wolf mqtt install.sh: send the broker log to the range syslog server (UDP).\nif $programname == '"'"'mosquitto'"'"' then @%s:%s\n' \
        "$SYSLOG_HOST" "$SYSLOG_PORT" > "$STAGE/rsyslog.conf"
    before=$CHANGED; CHANGED=0
    put "$STAGE/rsyslog.conf" "$RSYSLOG_FILE" 0644
    (( CHANGED )) && run systemctl restart rsyslog.service
    CHANGED=$(( before | CHANGED ))
else
    echo "   off (set SYSLOG_HOST in mqtt.conf, or --syslog syslog.lab)"
    before=$CHANGED; CHANGED=0
    remove "$RSYSLOG_FILE"
    (( CHANGED )) && run systemctl restart rsyslog.service
    CHANGED=$(( before | CHANGED ))
fi

# ---- 6. Firewall (only if ufw is turned on) ----
say "6. Firewall"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    run ufw allow "$PORT/tcp"
    [[ "$TLS" == "yes" ]] && run ufw allow "$TLS_PORT/tcp"
else
    echo "   ufw is off. Nothing to open."
fi

# ---- 7. Start ----
say "7. Start the broker"
run systemctl enable mosquitto.service
if (( CHANGED )) || ! systemctl is-active -q mosquitto.service; then
    # A restart drops every client for a moment. Tiles reconnect by themselves.
    run systemctl restart mosquitto.service
else
    echo "   nothing changed, broker left running"
fi

if (( GO )); then
    [[ -d "$BACKUP_DIR" ]] && echo "   Old files saved in $BACKUP_DIR"
    if (( ${#NEW_LOGINS[@]} > 0 )); then
        say "NEW PASSWORDS. Write these down now. They are shown only once and are not saved anywhere."
        for l in "${NEW_LOGINS[@]}"; do echo "   $l"; done
        echo "   Lost one? sudo bash install.sh --new-password <name> --go"
    fi
    sleep 2
    check
else
    say "Test mode finished. Nothing changed. Run again with --go."
fi
