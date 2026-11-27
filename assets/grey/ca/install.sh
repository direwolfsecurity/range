#!/usr/bin/env bash
# install.sh - Dire Wolf range certificate authority: a fake Let's Encrypt (step-ca with ACME).
#
# Usage (run from this folder, on Ubuntu 24.04, a VM or a Proxmox container):
#   sudo bash install.sh                  test mode: shows what it would do, changes nothing
#   sudo bash install.sh --go             does it, then prints a status check
#   sudo bash install.sh --check          status, ports, fingerprint, ACME self-test, clock
#   sudo bash install.sh --root           prints the root certificate (PEM)
#   sudo bash install.sh --issue NAME [--san NAME_OR_IP]... [--days N]
#                                         makes a certificate by hand, for servers that can't use ACME
#
# Other options: --ip ADDRESS (this server's address, if it guesses wrong)
#
# Safe to run again. It never makes a second CA over the first one.
# The CA's private keys are made on this server and never leave it. Nothing secret is written to this folder.
#
# License: GPL-3.0, Dire Wolf Security.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HERE/ca.conf"

export STEPPATH="/etc/step-ca"
CA_JSON="$STEPPATH/config/ca.json"
ROOT_CRT="$STEPPATH/certs/root_ca.crt"
INT_CRT="$STEPPATH/certs/intermediate_ca.crt"
INT_KEY="$STEPPATH/secrets/intermediate_ca_key"
PASS_FILE="$STEPPATH/secrets/password.txt"
UNIT_FILE="/etc/systemd/system/step-ca.service"
WEB_DIR="/var/www/direwolf-ca"
NGINX_SITE="/etc/nginx/sites-available/direwolf-ca"
NGINX_LINK="/etc/nginx/sites-enabled/direwolf-ca"
ISSUED_DIR="/root/direwolf-ca-issued"
KEYRING="/etc/apt/keyrings/smallstep.asc"
APT_LIST="/etc/apt/sources.list.d/smallstep.list"
BACKUP_DIR="/var/backups/direwolf-ca/$(date +%Y%m%d-%H%M%S)"

GO=0
CHECK=0
SHOW_ROOT=0
ISSUE_NAME=""
ISSUE_SANS=()
ISSUE_DAYS=""
OPT_IP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --go)     GO=1 ;;
        --check)  CHECK=1 ;;
        --root)   SHOW_ROOT=1 ;;
        --issue)  ISSUE_NAME="${2:-}"; shift ;;
        --san)    ISSUE_SANS+=("${2:-}"); shift ;;
        --days)   ISSUE_DAYS="${2:-}"; shift ;;
        --ip)     OPT_IP="${2:-}"; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
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

# A readable random password. Long, because nobody types it: step-ca reads it from a file.
make_password() {
    LC_ALL=C tr -dc 'abcdefghijkmnpqrstuvwxyz23456789' < /dev/urandom | head -c 32 || true
}

# The step command is called "step" or "step-cli", depending on how it was installed.
find_step() {
    if command -v step >/dev/null; then echo step
    elif command -v step-cli >/dev/null; then echo step-cli
    else echo ""
    fi
}

# Root fingerprint as plain lowercase hex (what step and the client scripts use).
root_fingerprint() {
    openssl x509 -in "$ROOT_CRT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
}

[[ -f "$SETTINGS" ]] || die "Missing ca.conf. Run this from the repo folder (assets/grey/ca)."
# shellcheck source=ca.conf
source "$SETTINGS"

for n in DEFAULT_CERT_DAYS MAX_CERT_DAYS CA_PORT DOWNLOAD_PORT; do
    [[ "${!n}" =~ ^[0-9]+$ ]] || die "$n in ca.conf must be a number (got '${!n}')."
done
(( DEFAULT_CERT_DAYS <= MAX_CERT_DAYS )) || die "DEFAULT_CERT_DAYS must not be more than MAX_CERT_DAYS."

# This server's address: --ip, or the address of the interface with the default route.
SERVER_IP="$OPT_IP"
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' | head -n1)"
fi
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

# ---------------------------------------------------------------------------
# --root: print the root certificate
# ---------------------------------------------------------------------------
if (( SHOW_ROOT )); then
    [[ -f "$ROOT_CRT" ]] || die "No CA yet. Run: sudo bash install.sh --go"
    cat "$ROOT_CRT"
    echo "# SHA-256 fingerprint: $(root_fingerprint)" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# --check: is it working?
# ---------------------------------------------------------------------------
check() {
    say "Services"
    printf '   %-22s %s\n' "step-ca.service" "$(systemctl is-active step-ca.service 2>/dev/null || true)"
    printf '   %-22s %s\n' "nginx.service" "$(systemctl is-active nginx.service 2>/dev/null || true)"

    say "Listening ports (want $CA_PORT for the CA and $DOWNLOAD_PORT for the download page)"
    ss -ltnp 2>/dev/null | awk -v a=":$CA_PORT\$" -v b=":$DOWNLOAD_PORT\$" 'NR == 1 || $4 ~ a || $4 ~ b' | sed 's/^/   /'

    if [[ ! -f "$ROOT_CRT" ]]; then
        warn "No CA yet ($ROOT_CRT is missing). Run: sudo bash install.sh --go"
        return
    fi

    say "Root certificate (post this fingerprint where students can see it)"
    printf '   %-14s %s\n' "Name:" "$(openssl x509 -in "$ROOT_CRT" -noout -subject -nameopt multiline | awk -F' = ' '/commonName/ {print $2}')"
    printf '   %-14s %s\n' "Valid until:" "$(openssl x509 -in "$ROOT_CRT" -noout -enddate | cut -d= -f2)"
    printf '   %-14s %s\n' "SHA-256:" "$(root_fingerprint)"

    say "Self-test (as a client that trusts the root)"
    local base="https://$SERVER_NAME:$CA_PORT" pin="$SERVER_NAME:$CA_PORT:127.0.0.1" out
    out="$(curl -s --noproxy "*" --max-time 5 --cacert "$ROOT_CRT" --resolve "$pin" "$base/health" || true)"
    if [[ "$out" == *'"ok"'* ]]; then echo "   CA health:        ok"; else echo "   CA health:        FAILED ($out)"; fi
    out="$(curl -s --noproxy "*" --max-time 5 --cacert "$ROOT_CRT" --resolve "$pin" "$base/acme/acme/directory" || true)"
    if [[ "$out" == *newOrder* ]]; then echo "   ACME directory:   ok  ($base/acme/acme/directory)"; else echo "   ACME directory:   FAILED"; fi
    out="$(curl -s --noproxy "*" --max-time 5 "http://127.0.0.1:$DOWNLOAD_PORT/root_ca.crt" || true)"
    if [[ "$out" == "$(cat "$ROOT_CRT")" ]]; then echo "   Download page:    ok  (http://$SERVER_NAME$( [[ "$DOWNLOAD_PORT" == 80 ]] || echo ":$DOWNLOAD_PORT")/)"; else echo "   Download page:    FAILED"; fi

    say "Certificate lifetimes"
    echo "   default $DEFAULT_CERT_DAYS days, longest $MAX_CERT_DAYS days (ca.conf)"

    say "DNS: what does $SERVER_NAME point to?"
    local found
    found="$(getent hosts "$SERVER_NAME" | awk '{print $1}' | head -n1 || true)"
    if [[ -z "$found" ]]; then
        warn "$SERVER_NAME does not resolve here yet. Register it (README step 3)."
    elif [[ "$found" != "$SERVER_IP" ]]; then
        warn "$SERVER_NAME points to $found, but this server is $SERVER_IP."
    else
        echo "   $SERVER_NAME -> $found (this server)"
    fi
    echo "   The CA checks ACME requests with the resolver $RESOLVER:"
    if command -v dig >/dev/null; then
        dig +short +time=2 +tries=1 @"$RESOLVER" "$SERVER_NAME" | sed 's/^/     /' || true
    fi

    say "Clock (certificates fail on machines with the wrong time)"
    echo "   $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "   in sync with NTP: $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"

    say "Last log lines"
    journalctl -u step-ca.service -n 8 --no-pager 2>/dev/null | sed 's/^/   /' || true
}

if (( CHECK )); then
    check
    exit 0
fi

[[ $EUID -eq 0 ]] || die "Run with sudo."

# ---------------------------------------------------------------------------
# --issue: a certificate by hand (for servers that can't run an ACME client)
# ---------------------------------------------------------------------------
if [[ -n "$ISSUE_NAME" ]]; then
    STEP="$(find_step)"
    [[ -n "$STEP" ]] || die "The step command is not installed. Run: sudo bash install.sh --go"
    [[ -f "$INT_KEY" && -f "$PASS_FILE" ]] || die "No CA yet. Run: sudo bash install.sh --go"
    [[ "$ISSUE_NAME" =~ ^[a-z0-9.-]+$ ]] || die "'$ISSUE_NAME' is not a good DNS name."
    days="${ISSUE_DAYS:-$MAX_CERT_DAYS}"
    [[ "$days" =~ ^[0-9]+$ ]] && (( days >= 1 && days <= MAX_CERT_DAYS )) || die "--days must be 1 to $MAX_CERT_DAYS."
    out="$ISSUED_DIR/$ISSUE_NAME"
    sans=(--san "$ISSUE_NAME")
    for s in "${ISSUE_SANS[@]}"; do sans+=(--san "$s"); done
    if [[ -e "$out/$ISSUE_NAME.key" ]]; then
        die "$out already has a key. Copy it where it goes, then delete that folder and try again."
    fi
    say "Certificate for $ISSUE_NAME (${ISSUE_SANS[*]:-no extra names}), $days days"
    if (( ! GO )); then
        echo "   would make $out/$ISSUE_NAME.crt and $out/$ISSUE_NAME.key"
        say "Test mode finished. Nothing changed. Run again with --go."
        exit 0
    fi
    install -d -m 700 "$ISSUED_DIR" "$out"
    # --bundle puts the intermediate after the server certificate, which is what servers should send.
    "$STEP" certificate create "$ISSUE_NAME" "$out/$ISSUE_NAME.crt" "$out/$ISSUE_NAME.key" \
        --profile leaf --ca "$INT_CRT" --ca-key "$INT_KEY" --ca-password-file "$PASS_FILE" \
        --not-after "$(( days * 24 ))h" "${sans[@]}" --bundle --no-password --insecure
    chmod 600 "$out/$ISSUE_NAME.key"
    echo
    echo "   Made: $out/$ISSUE_NAME.crt  (certificate + intermediate)"
    echo "         $out/$ISSUE_NAME.key  (private key: keep it secret)"
    echo "   Copy both to the server that uses them, for example:"
    echo "     scp $out/$ISSUE_NAME.crt $out/$ISSUE_NAME.key root@$ISSUE_NAME:/root/"
    echo "   Then delete the copy here: rm -r $out"
    exit 0
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
say "Preflight"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "   OS: ${PRETTY_NAME:-unknown}"
    [[ "${ID:-}" == "ubuntu" ]] || warn "Written for Ubuntu 24.04. It may still work here."
fi
[[ -n "$SERVER_IP" ]] || die "Can't tell this server's address. Use --ip ADDRESS."
echo "   This server: $SERVER_NAME at $SERVER_IP (use --ip if that address is wrong)"
echo "   CA name:     $CA_NAME (root: \"$CA_NAME Root CA\", intermediate: \"$CA_NAME Intermediate CA\")"
if [[ -f "$CA_JSON" ]]; then
    echo "   A CA already exists in $STEPPATH. It is kept. Only settings are updated."
else
    echo "   No CA yet. A new root and intermediate will be made in $STEPPATH."
fi

say "1. Packages"
run apt-get update
run apt-get install -y curl ca-certificates openssl nginx python3 bind9-dnsutils
if [[ -n "$(find_step)" ]] && command -v step-ca >/dev/null; then
    echo "   step and step-ca are already installed: $("$(find_step)" version 2>/dev/null | head -n1)"
elif [[ "$STEP_PACKAGES" == "smallstep" ]]; then
    # Smallstep's own apt repository. Needs internet while installing.
    run install -d -m 755 /etc/apt/keyrings
    run curl -fsSL https://packages.smallstep.com/keys/apt/repo-signing-key.gpg -o "$KEYRING"
    if (( GO )); then
        echo "deb [signed-by=$KEYRING] https://packages.smallstep.com/stable/debian debs main" > "$APT_LIST"
        echo "   + wrote $APT_LIST"
    else
        echo "   would write: $APT_LIST"
    fi
    run apt-get update
    run apt-get install -y step-cli step-ca
else
    # A folder of .deb files you downloaded beforehand.
    [[ -d "$STEP_PACKAGES" ]] || die "STEP_PACKAGES is '$STEP_PACKAGES': not 'smallstep' and not a folder."
    shopt -s nullglob
    debs=("$STEP_PACKAGES"/step-cli*.deb "$STEP_PACKAGES"/step-ca*.deb)
    shopt -u nullglob
    (( ${#debs[@]} >= 2 )) || die "Put step-cli_*.deb and step-ca_*.deb in $STEP_PACKAGES."
    run apt-get install -y "${debs[@]}"
fi
STEP="$(find_step)"
if (( GO )); then
    [[ -n "$STEP" ]] || die "The step command did not install."
    command -v step-ca >/dev/null || die "step-ca did not install."
fi
STEP="${STEP:-step}"

say "2. CA user"
if id step >/dev/null 2>&1; then
    echo "   user 'step' exists"
else
    run useradd --system --home-dir "$STEPPATH" --no-create-home --shell /usr/sbin/nologin step
fi

say "3. The CA (root + intermediate)"
NEW_PROVISIONER_PASSWORD=""
if [[ -f "$CA_JSON" ]]; then
    echo "   kept: $CA_JSON (delete $STEPPATH only if you really want a new CA; every client must then trust the new root)"
elif (( GO )); then
    install -d -m 700 "$STEPPATH" "$STEPPATH/secrets"
    tmp_prov="$(mktemp)"
    make_password > "$PASS_FILE"
    NEW_PROVISIONER_PASSWORD="$(make_password)"
    printf '%s' "$NEW_PROVISIONER_PASSWORD" > "$tmp_prov"
    chmod 600 "$PASS_FILE" "$tmp_prov"
    # standalone = no Smallstep cloud account. --acme adds the ACME provisioner (the "Let's Encrypt" part).
    "$STEP" ca init --deployment-type standalone --name "$CA_NAME" \
        --dns "$SERVER_NAME" --dns "$SERVER_IP" --address ":$CA_PORT" \
        --provisioner admin --password-file "$PASS_FILE" --provisioner-password-file "$tmp_prov" --acme
    rm -f "$tmp_prov"
    echo "   + made a new CA in $STEPPATH"
else
    echo "   would run: $STEP ca init --deployment-type standalone --name \"$CA_NAME\" --dns $SERVER_NAME --dns $SERVER_IP --address :$CA_PORT --provisioner admin --acme"
    echo "   would save the key password in $PASS_FILE (only root and the step user can read it)"
fi

say "4. CA settings (names, port, certificate lifetimes)"
if [[ -f "$CA_JSON" ]]; then
    tmp="$(mktemp)"
    python3 - "$CA_JSON" "$tmp" "$SERVER_NAME" "$SERVER_IP" "$CA_PORT" "$DEFAULT_CERT_DAYS" "$MAX_CERT_DAYS" <<'PY'
import json, sys
src, dst, name, ip, port, default_days, max_days = sys.argv[1:]
with open(src) as f:
    cfg = json.load(f)
cfg["dnsNames"] = [name, ip]
cfg["address"] = ":" + port
claims = cfg.setdefault("authority", {}).setdefault("claims", {})
claims["minTLSCertDuration"] = "5m"
claims["defaultTLSCertDuration"] = str(int(default_days) * 24) + "h"
claims["maxTLSCertDuration"] = str(int(max_days) * 24) + "h"
with open(dst, "w") as f:
    json.dump(cfg, f, indent=4)
    f.write("\n")
PY
    put "$tmp" "$CA_JSON" 600 step:step
    rm -f "$tmp"
else
    echo "   would set: dnsNames $SERVER_NAME + $SERVER_IP, port $CA_PORT, certificates $DEFAULT_CERT_DAYS days (longest $MAX_CERT_DAYS)"
fi
if (( GO )); then
    chown -R step:step "$STEPPATH"
    chmod 700 "$STEPPATH/secrets"
fi
CA_CHANGED=$CHANGED

say "5. Service"
tmp="$(mktemp)"
cat > "$tmp" <<EOF
# Made by the Dire Wolf range CA install.sh. Edit ca.conf and re-run instead.
[Unit]
Description=Dire Wolf range certificate authority (step-ca with ACME)
After=network-online.target
Wants=network-online.target

[Service]
User=step
Group=step
Environment=STEPPATH=$STEPPATH
WorkingDirectory=$STEPPATH
# The password file unlocks the intermediate key, so the CA can start by itself after a reboot.
# --resolver: check ACME requests with the range resolver, whatever this container's resolv.conf says.
ExecStart=$(command -v step-ca || echo /usr/bin/step-ca) $CA_JSON --password-file $PASS_FILE --resolver $RESOLVER:53
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
# Lets the step user use port $CA_PORT without being root.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
put "$tmp" "$UNIT_FILE" 644
rm -f "$tmp"
CA_CHANGED=$(( CA_CHANGED | CHANGED ))
CHANGED=0

say "6. Download page (http://$SERVER_NAME/)"
if [[ -f "$ROOT_CRT" ]]; then
    FP="$(root_fingerprint)"
    tmpd="$(mktemp -d)"
    cp "$ROOT_CRT" "$tmpd/root_ca.crt"
    openssl x509 -in "$ROOT_CRT" -outform DER -out "$tmpd/root_ca.der"
    echo "$FP" > "$tmpd/fingerprint.txt"
    {
        echo "// Range root certificate for ESP32 and Pico W sketches."
        echo "// From $CA_NAME Root CA ($SERVER_NAME). SHA-256 fingerprint: $FP"
        echo "// Use it like this: client.setCACert(RANGE_ROOT_CA);"
        echo "const char RANGE_ROOT_CA[] = R\"EOF("
        cat "$ROOT_CRT"
        echo ")EOF\";"
    } > "$tmpd/root_ca.h"
    cp "$HERE/client/install-root-linux.sh" "$HERE/client/Install-RangeRoot.ps1" "$tmpd/"
    sed -e "s|@CA_NAME@|$CA_NAME Root CA|g" -e "s|@SERVER_NAME@|$SERVER_NAME|g" -e "s|@FP@|$FP|g" \
        -e "s|@ACME@|https://$SERVER_NAME/acme/acme/directory|g" "$HERE/client/index.html" > "$tmpd/index.html"
    for f in index.html root_ca.crt root_ca.der root_ca.h fingerprint.txt install-root-linux.sh Install-RangeRoot.ps1; do
        put "$tmpd/$f" "$WEB_DIR/$f" 644
    done
    rm -rf "$tmpd"
else
    echo "   would publish: root_ca.crt, root_ca.der, root_ca.h, fingerprint.txt and the client install scripts"
fi
tmp="$(mktemp)"
cat > "$tmp" <<EOF
# Made by the Dire Wolf range CA install.sh. Public files only: never put a key in $WEB_DIR.
server {
    listen $DOWNLOAD_PORT default_server;
    server_name $SERVER_NAME;
    root $WEB_DIR;
    index index.html;
    types {
        text/html                    html;
        application/x-x509-ca-cert   crt der;
        text/plain                   h txt sh ps1;
    }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
put "$tmp" "$NGINX_SITE" 644
rm -f "$tmp"
if [[ ! -L "$NGINX_LINK" ]]; then
    run ln -sf "$NGINX_SITE" "$NGINX_LINK"
    CHANGED=1
fi
if [[ -L /etc/nginx/sites-enabled/default ]]; then
    # The stock nginx page also wants port 80.
    run rm -f /etc/nginx/sites-enabled/default
    CHANGED=1
fi
WEB_CHANGED=$CHANGED

say "7. Firewall"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    run ufw allow "$CA_PORT/tcp"
    run ufw allow "$DOWNLOAD_PORT/tcp"
else
    echo "   ufw is off. Nothing to open."
fi

say "8. Start"
run systemctl daemon-reload
run systemctl enable step-ca.service nginx.service
if (( CA_CHANGED )) || ! systemctl is-active -q step-ca.service; then
    run systemctl restart step-ca.service
else
    echo "   CA unchanged, left running"
fi
if (( WEB_CHANGED )) || ! systemctl is-active -q nginx.service; then
    if (( GO )); then nginx -t; fi
    run systemctl restart nginx.service
else
    echo "   download page unchanged"
fi

if (( GO )); then
    [[ -d "$BACKUP_DIR" ]] && echo "   Old files saved in $BACKUP_DIR"
    if [[ -n "$NEW_PROVISIONER_PASSWORD" ]]; then
        say "ADMIN PROVISIONER PASSWORD. Shown once, saved nowhere."
        echo "   $NEW_PROVISIONER_PASSWORD"
        echo "   You only need it for 'step ca certificate' with the admin provisioner. ACME and --issue do not need it."
    fi
    sleep 2
    check
else
    say "Test mode finished. Nothing changed. Run again with --go."
fi
