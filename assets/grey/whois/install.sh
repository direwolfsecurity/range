#!/usr/bin/env bash
# install.sh - Dire Wolf range whois server (whois.lab): the fake internet's address registry.
# whois on port 43, RDAP and a lookup page on port 80, all from the range registry file.
#
# Usage (run from this folder, on Ubuntu 24.04, a VM or a Proxmox container):
#   sudo bash install.sh                 test mode: shows what it would do, changes nothing
#   sudo bash install.sh --go            does it (or updates after a git pull), then checks
#   sudo bash install.sh --check         the service, a lookup for every network, RDAP, the web page, DNS
#   sudo bash install.sh --registrar     prints the commands to run on the root primary (README step 3)
#
# Other options: --ip ADDRESS (this server's address, if it guesses wrong)
#
# Safe to run again. Files it replaces are first copied to /var/backups/direwolf-whois/.
# After you change registry.csv: git pull, then sudo bash install.sh --go
# Exercise teams (the overlay, OVERLAY_FILE in whois.conf) come from the range control server
# (assets/white/control), which runs whois-apply. The server picks them up by itself.
#
# License: GPL-3.0, Dire Wolf Security.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HERE/whois.conf"

APP="/opt/direwolf-whois"
ETC="/etc/direwolf-whois"
UNIT="/etc/systemd/system/direwolf-whois.service"
SERVICE_USER="whoisd"
BACKUP_DIR="/var/backups/direwolf-whois/$(date +%Y%m%d-%H%M%S)"

GO=0
CHECK=0
REGISTRAR=0
OPT_IP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --go)        GO=1 ;;
        --check)     CHECK=1 ;;
        --registrar) REGISTRAR=1 ;;
        --ip)        OPT_IP="${2:-}"; shift ;;
        -h|--help)   sed -n '2,17p' "$0"; exit 0 ;;
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
        fi
        install -D -m "$mode" -o root -g root "$src" "$dest"
        printf '   installed: %s\n' "$dest"
    else
        printf '   would install: %s\n' "$dest"
    fi
}

# ---- Settings ----
[[ -f "$SETTINGS" ]] || die "Missing whois.conf. Run this from the repo folder (assets/grey/whois)."
# shellcheck source=whois.conf
source "$SETTINGS"

if [[ "$REGISTRY_FILE" == /* ]]; then
    REGISTRY="$REGISTRY_FILE"
else
    REGISTRY="$HERE/$REGISTRY_FILE"
fi
if [[ ! -f "$REGISTRY" || ! -f "$(dirname "$REGISTRY")/registry.py" ]]; then
    die "Can't find the registry at $REGISTRY. Clone both folders:  git sparse-checkout set assets/grey/whois network/registry"
fi
REGISTRY="$(cd "$(dirname "$REGISTRY")" && pwd)/$(basename "$REGISTRY")"
OVERLAY="${OVERLAY_FILE:-/etc/direwolf-range/overlay.csv}"

SERVER_IP="$OPT_IP"
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' | head -n1)"
fi
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[[ -n "$SERVER_IP" ]] || die "Can't tell this server's address. Use --ip ADDRESS."

# ---- --registrar: the commands for the root primary ----
if (( REGISTRAR )); then
    say "Run these on the root primary (root-a)."
    echo "   The registrar's own setup pointed $SERVER_NAME at root-a. Move it to this server:"
    echo "   sudo -u www-data php /opt/registrar/cli.php del $SERVER_NAME"
    echo "   sudo -u www-data php /opt/registrar/cli.php add-a $SERVER_NAME $SERVER_IP"
    echo "   sudo registrar-apply"
    echo
    echo "   So the stock whois command works with no -h (it asks whois.arin.net for addresses,"
    echo "   whois.verisign-grs.com for .com, and so on): the connectivity-check server answers"
    echo "   those real names with this address (they are in its names.conf). On check.lab:"
    echo "   cd ~/range/assets/grey/connectivity-check && git pull && sudo bash install.sh --go"
    echo "   sudo bash install.sh --registrar      (and run what it prints on root-a)"
    exit 0
fi

# ---- --check ----
check() {
    local fails=0
    say "Service"
    if systemctl is-active -q direwolf-whois.service; then
        echo "   ok    direwolf-whois is running"
    else
        echo "   FAIL  direwolf-whois is not running (journalctl -u direwolf-whois)"; fails=$((fails + 1))
    fi
    say "whois (port $WHOIS_PORT), RDAP and the web page (port $HTTP_PORT), for one address in every network"
    python3 - "$APP/registry/registry.csv" "$OVERLAY" "$SERVER_IP" "$WHOIS_PORT" "$HTTP_PORT" <<'PY' || fails=$((fails + 1))
import json, os, socket, sys, urllib.request
path, overlay, ip, wport, hport = sys.argv[1:]
sys.path.insert(0, os.path.dirname(path))
import registry
overlay = overlay if os.path.exists(overlay) and os.path.getsize(overlay) else None
rows, errors = registry.read_with_overlay(path, overlay)
bad = 0
def whois(q):
    s = socket.create_connection((ip, int(wport)), timeout=5)
    s.sendall((q + "\r\n").encode())
    out = b""
    while True:
        part = s.recv(65536)
        if not part:
            break
        out += part
    s.close()
    return out.decode()
for row in rows:
    if row.network.version != 4:
        continue
    addr = row.network.network_address if row.network.prefixlen == 32 else row.network.network_address + 5
    try:
        text = whois("n + %s" % addr)
        ok = "Organization:   %s (%s)" % (row.org, row.org_handle) in text
    except OSError as e:
        text, ok = str(e), False
    print("   %-5s %-16s %s" % ("ok" if ok else "FAIL", addr, row.org if ok else text.strip()[-80:]))
    bad += not ok
try:
    with urllib.request.urlopen("http://%s:%s/rdap/ip/%s" % (ip, hport, rows[-1].network.network_address), timeout=5) as r:
        obj = json.load(r)
    print("   ok    RDAP answers (%s)" % obj["handle"])
except Exception as e:
    print("   FAIL  RDAP: %s" % e); bad += 1
try:
    with urllib.request.urlopen("http://%s:%s/?q=AS%d" % (ip, hport, rows[-1].asn), timeout=5) as r:
        ok = b"ASNumber" in r.read()
    print("   %-5s the web page answers" % ("ok" if ok else "FAIL")); bad += not ok
except Exception as e:
    print("   FAIL  web page: %s" % e); bad += 1
try:
    text = whois("nic.lab")
    if "Domain Name: NIC.LAB" in text:
        print("   ok    domains: the registrar answered for nic.lab")
    else:
        print("   WAIT  domains: %s" % [l for l in text.splitlines() if l and not l.startswith("#")][:1])
except OSError as e:
    print("   FAIL  domain lookup: %s" % e); bad += 1
sys.exit(1 if bad else 0)
PY
    say "DNS (through this server's resolver)"
    local got
    got="$(getent ahostsv4 "$SERVER_NAME" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
    if [[ "$got" == "$SERVER_IP" ]]; then
        echo "   ok    $SERVER_NAME -> $got"
    else
        echo "   WAIT  $SERVER_NAME -> ${got:-nothing} (should be $SERVER_IP). Run what --registrar prints on root-a."
    fi
    got="$(getent ahostsv4 whois.arin.net 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
    if [[ "$got" == "$SERVER_IP" ]]; then
        echo "   ok    whois.arin.net -> $got (plain \"whois 192.168.103.5\" works)"
    else
        echo "   WAIT  whois.arin.net -> ${got:-nothing}. Until check.lab answers it, use: whois -h $SERVER_NAME ..."
    fi
    echo
    if (( fails )); then echo "   $fails part(s) failed."; return 1; fi
    echo "   All checks passed."
}

if (( CHECK )); then
    check
    exit $?
fi

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

say "Whois server: $SERVER_NAME at $SERVER_IP (use --ip if that address is wrong)"
echo "   Registry: $REGISTRY"
echo "   Exercise overlay: $OVERLAY ($([[ -s "$OVERLAY" ]] && echo "in use" || echo "none"))"
echo "   Domains are asked from: $REGISTRAR_URL"
(( GO )) || echo "   TEST MODE: nothing is changed. Add --go to do it."

if command -v python3 >/dev/null; then
    python3 "$(dirname "$REGISTRY")/registry.py" "$REGISTRY" >/dev/null || die "registry.csv has problems (run registry.py to see them)."
fi

say "1. Packages"
missing=()
for p in python3 whois; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
done
if (( ${#missing[@]} )); then
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
else
    echo "   all installed"
fi

say "2. Service user"
if id "$SERVICE_USER" >/dev/null 2>&1; then
    echo "   $SERVICE_USER exists"
else
    run useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
fi

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

say "3. The program and its copy of the registry"
put "$HERE/whoisd.py" "$APP/whoisd.py" 755
put "$(dirname "$REGISTRY")/registry.py" "$APP/registry/registry.py" 644
put "$REGISTRY" "$APP/registry/registry.csv" 644
# The installed settings point at that copy, so the service never reads the git folder.
sed -e "s|^REGISTRY_FILE=.*|REGISTRY_FILE=\"$APP/registry/registry.csv\"|" "$SETTINGS" > "$tmpd/whois.conf"
put "$tmpd/whois.conf" "$ETC/whois.conf" 644
sed -e "s|@OVERLAY@|$OVERLAY|g" "$HERE/tools/whois-apply" > "$tmpd/whois-apply"
put "$tmpd/whois-apply" /usr/local/sbin/whois-apply 755

say "4. systemd service"
cat > "$tmpd/unit" <<EOF
# Made by the Dire Wolf whois install.sh. Edit whois.conf and re-run instead.
[Unit]
Description=Dire Wolf range whois, RDAP and lookup page ($SERVER_NAME)
After=network-online.target
Wants=network-online.target

[Service]
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=/usr/bin/python3 $APP/whoisd.py --conf $ETC/whois.conf
# Ports 43 and 80 are below 1024. This lets the service use them without running as root.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
put "$tmpd/unit" "$UNIT" 644

if (( ! GO )); then
    say "Test mode: nothing was changed. Run again with --go."
    exit 0
fi

say "5. Start"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$WHOIS_PORT/tcp" >/dev/null; ufw allow "$HTTP_PORT/tcp" >/dev/null
    echo "   opened $WHOIS_PORT/tcp and $HTTP_PORT/tcp in ufw"
fi
systemctl daemon-reload
systemctl enable direwolf-whois.service >/dev/null 2>&1 || true
if (( CHANGED )) || ! systemctl is-active -q direwolf-whois.service; then
    run systemctl restart direwolf-whois.service
else
    echo "   nothing changed, the service is left running"
fi
sleep 2

check || true
cat <<EOF

   Next, if not done yet:
     1. On root-a, run what this prints:  sudo bash install.sh --registrar
     2. Try it from any range machine:  whois -h $SERVER_NAME 192.168.103.5   or   http://$SERVER_NAME/
EOF
