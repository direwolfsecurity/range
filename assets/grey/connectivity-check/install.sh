#!/usr/bin/env bash
# install.sh - Dire Wolf range connectivity checks: answer the "am I online?" tests that
# Windows, Android, Apple, Firefox and Linux run, so range machines stop saying "No Internet".
# It also serves the "well-known names" in names.conf (real internet names the range answers itself).
#
# Usage (run from this folder, on Ubuntu 24.04, a VM or a Proxmox container):
#   sudo bash install.sh                 test mode: shows what it would do, changes nothing
#   sudo bash install.sh --go            does it, then prints a status check
#   sudo bash install.sh --check         services, every name, every check page, through the resolver too
#   sudo bash install.sh --registrar     prints the commands to run on the root primary (README step 3)
#
# Other options: --ip ADDRESS (this server's address, if it guesses wrong)   --https yes|no
#
# Safe to run again. Files it replaces are first copied to /var/backups/direwolf-check/.
#
# License: GPL-3.0, Dire Wolf Security.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HERE/check.conf"
NAMES_FILE="$HERE/names.conf"

ZONE_DIR="/etc/bind/zones/wellknown"
ZONES_CONF="/etc/bind/named.conf.wellknown"
OPTIONS_CONF="/etc/bind/named.conf.options"
LOCAL_CONF="/etc/bind/named.conf.local"
WEB_DIR="/var/www/check"
ACME_DIR="/var/www/check-acme"
NGINX_SITE="/etc/nginx/sites-available/direwolf-check"
NGINX_LINK="/etc/nginx/sites-enabled/direwolf-check"
CERT_NAME="direwolf-check"
CERT_DIR="/etc/letsencrypt/live/$CERT_NAME"
RANGE_ROOT="/usr/local/share/ca-certificates/direwolf-range-root.crt"
BACKUP_DIR="/var/backups/direwolf-check/$(date +%Y%m%d-%H%M%S)"

GO=0
CHECK=0
REGISTRAR=0
OPT_IP=""
OPT_HTTPS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --go)        GO=1 ;;
        --check)     CHECK=1 ;;
        --registrar) REGISTRAR=1 ;;
        --ip)        OPT_IP="${2:-}"; shift ;;
        --https)     OPT_HTTPS="${2:-}"; shift ;;
        -h|--help)   sed -n '2,15p' "$0"; exit 0 ;;
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

is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local part
    for part in "${BASH_REMATCH[@]:1}"; do (( part <= 255 )) || return 1; done
    return 0
}

# ---- Settings ----
[[ -f "$SETTINGS" ]]   || die "Missing check.conf. Run this from the repo folder (assets/grey/connectivity-check)."
[[ -f "$NAMES_FILE" ]] || die "Missing names.conf. Run this from the repo folder (assets/grey/connectivity-check)."
# shellcheck source=check.conf
source "$SETTINGS"
[[ -n "$OPT_HTTPS" ]] && HTTPS="$OPT_HTTPS"
[[ "$HTTPS" == "yes" || "$HTTPS" == "no" ]] || die "HTTPS must be yes or no (got '$HTTPS')."
is_ipv4 "$NTP_IP" || die "NTP_IP in check.conf is not an IPv4 address (got '$NTP_IP')."

SERVER_IP="$OPT_IP"
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' | head -n1)"
fi
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[[ -n "$SERVER_IP" ]] || die "Can't tell this server's address. Use --ip ADDRESS."

# ---- Read names.conf. Stops on the first bad line. ----
# NAMES[i] answers with IPS[i]. ZONES lists each zone once, in file order.
NAMES=()
KINDS=()
IPS=()
ZONES=()
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"
    [[ -z "${line// /}" ]] && continue
    read -r name answer extra <<< "$line"
    name="${name,,}"
    name="${name%.}"
    [[ -z "${extra:-}" ]] || die "names.conf line $lineno: too many words."
    [[ "$name" =~ ^(\*\.)?[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] || die "names.conf line $lineno: '$name' is not a DNS name."
    case "$answer" in
        check) ip="$SERVER_IP" ;;
        ntp)   ip="$NTP_IP" ;;
        *)     is_ipv4 "$answer" || die "names.conf line $lineno: answer must be check, ntp or an IPv4 address (got '$answer')."
               ip="$answer" ;;
    esac
    for n in "${NAMES[@]}"; do
        [[ "$n" == "$name" ]] && die "names.conf line $lineno: '$name' is listed twice."
    done
    # The zone is the last two parts of the name.
    zone="$(awk -F. '{print $(NF - 1) "." $NF}' <<< "$name")"
    [[ "${zone##*.}" == "${SERVER_NAME##*.}" ]] && die "names.conf line $lineno: '$name' is a range name (.${zone##*.}). Register it on the registrar with add-a instead."
    NAMES+=("$name")
    KINDS+=("$answer")
    IPS+=("$ip")
    seen=0
    for z in "${ZONES[@]}"; do [[ "$z" == "$zone" ]] && seen=1; done
    (( seen )) || ZONES+=("$zone")
done < "$NAMES_FILE"
(( ${#NAMES[@]} > 0 )) || die "names.conf has no names."

# Names for the HTTPS certificate: this server plus every "check" name that is not a wildcard.
cert_names() {
    local i
    echo "$SERVER_NAME"
    for i in "${!NAMES[@]}"; do
        [[ "${KINDS[$i]}" == "check" && "${NAMES[$i]}" != \** ]] && echo "${NAMES[$i]}"
    done
    return 0
}

# ---------------------------------------------------------------------------
# --registrar: commands for the root primary
# ---------------------------------------------------------------------------
if (( REGISTRAR )); then
    tlds="$(printf '%s\n' "${ZONES[@]}" | awk -F. '{print $NF}' | sort -u | tr '\n' ' ')"
    echo "# Run these on the ROOT PRIMARY (root-a), where the registrar is installed."
    echo "# This server ($SERVER_NAME, $SERVER_IP) becomes the name server for ${#ZONES[@]} real-world zones."
    echo "# The registrar must sell these TLDs: $tlds(see its 'list' command)."
    echo "# 'already registered' means someone owns that name: check with 'list', remove it with 'del <name>', run the line again."
    echo
    echo "sudo -u www-data php /opt/registrar/cli.php add-a $SERVER_NAME $SERVER_IP"
    for z in "${ZONES[@]}"; do
        echo "sudo -u www-data php /opt/registrar/cli.php add-ns $z $SERVER_NAME"
    done
    echo "sudo registrar-apply"
    exit 0
fi

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------
# One line per check page: name, path, expected HTTP code, expected text in the reply (may be empty).
PROBES=(
    "www.msftconnecttest.com|/connecttest.txt|200|Microsoft Connect Test|Windows 10 and 11"
    "www.msftncsi.com|/ncsi.txt|200|Microsoft NCSI|older Windows"
    "connectivitycheck.gstatic.com|/generate_204|204||Android"
    "www.google.com|/gen_204|204||Android (fallback)"
    "clients3.google.com|/generate_204|204||Chrome, ChromeOS"
    "captive.apple.com|/hotspot-detect.html|200|Success|Apple"
    "detectportal.firefox.com|/success.txt|200|success|Firefox"
    "connectivity-check.ubuntu.com|/|204||Ubuntu"
    "nmcheck.gnome.org|/check_network_status.txt|200|NetworkManager is online|GNOME, Kali, Arch"
    "network-test.debian.org|/nm|200|NetworkManager is online|Debian"
    "fedoraproject.org|/static/hotspot.txt|200|OK|Fedora"
)

check() {
    local i name want got via line path code text who body status ok bad
    say "Services"
    printf '   %-22s %s\n' "named.service" "$(systemctl is-active named.service 2>/dev/null || true)"
    printf '   %-22s %s\n' "nginx.service" "$(systemctl is-active nginx.service 2>/dev/null || true)"

    say "Listening ports (want 53 and 80; 443 when HTTPS is on)"
    ss -lntuH 2>/dev/null | awk '$5 ~ /:(53|80|443)$/ {print $1, $5}' | sort -u | sed 's/^/   /'

    say "DNS: every name in names.conf (this server / through the resolver $RESOLVER)"
    ok=0; bad=0
    for i in "${!NAMES[@]}"; do
        name="${NAMES[$i]}"
        want="${IPS[$i]}"
        [[ "$name" == \** ]] && name="test${name#\*}"
        got="$(dig +short +time=2 +tries=1 @127.0.0.1 "$name" A 2>/dev/null | tail -n1 || true)"
        via="$(dig +short +time=2 +tries=1 @"$RESOLVER" "$name" A 2>/dev/null | tail -n1 || true)"
        if [[ "$got" == "$want" && "$via" == "$want" ]]; then
            ok=$((ok + 1))
            printf '   ok     %-32s %s\n' "$name" "$want"
        else
            bad=$((bad + 1))
            printf '   CHECK  %-32s want %s, here: %s, resolver: %s\n' "$name" "$want" "${got:-nothing}" "${via:-nothing}"
        fi
    done
    echo "   $ok ok, $bad to check."
    (( bad )) && echo "   'here' wrong: re-run --go. 'resolver' wrong: README step 3 (the registrar), or wait 5 minutes for old answers to expire."

    say "Check pages (asked of this server by name)"
    for line in "${PROBES[@]}"; do
        IFS='|' read -r name path code text who <<< "$line"
        body="$(curl -s --noproxy '*' --max-time 5 --resolve "$name:80:127.0.0.1" -w '\n%{http_code}' "http://$name$path" || true)"
        status="${body##*$'\n'}"
        body="${body%$'\n'*}"
        if [[ "$status" == "$code" && ( -z "$text" || "$body" == *"$text"* ) ]]; then
            printf '   ok     %-20s http://%s%s\n' "$who" "$name" "$path"
        else
            printf '   FAILED %-20s http://%s%s (got %s)\n' "$who" "$name" "$path" "$status"
        fi
    done

    if [[ -f "$CERT_DIR/fullchain.pem" ]]; then
        say "HTTPS certificate"
        openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -issuer -enddate | sed 's/^/   /'
        status="$(curl -s --noproxy '*' --max-time 5 --resolve "www.google.com:443:127.0.0.1" -o /dev/null -w '%{http_code}' https://www.google.com/generate_204 || true)"
        echo "   https://www.google.com/generate_204 -> $status (204 = good, 000 = this server does not trust the range root)"
    fi
}

if (( CHECK )); then
    check
    exit 0
fi

[[ $EUID -eq 0 ]] || die "Run with sudo."

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
echo "   This server: $SERVER_NAME at $SERVER_IP (use --ip if that address is wrong)"
echo "   ${#NAMES[@]} names in ${#ZONES[@]} zones: ${ZONES[*]}"
echo "   HTTPS: $HTTPS"

say "1. Packages"
pkgs=(bind9 bind9-dnsutils nginx curl openssl)
[[ "$HTTPS" == "yes" ]] && pkgs+=(certbot)
run apt-get update
run apt-get install -y "${pkgs[@]}"

say "2. DNS: one zone per real-world domain"
tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT
cat > "$tmpd/options" <<EOF
// Made by the Dire Wolf connectivity-check install.sh. Edit check.conf and re-run instead.
// Authoritative only: this server answers for its own zones and nothing else.
options {
    directory "/var/cache/bind";
    recursion no;
    allow-query { any; };
    allow-transfer { none; };
    // Only the real address and localhost, so it never fights systemd-resolved over 127.0.0.53.
    listen-on { $SERVER_IP; 127.0.0.1; };
    listen-on-v6 { none; };
    dnssec-validation no;
    minimal-responses yes;
};
EOF
put "$tmpd/options" "$OPTIONS_CONF" 644 root:bind
printf '// Made by install.sh.\ninclude "%s";\n' "$ZONES_CONF" > "$tmpd/local"
put "$tmpd/local" "$LOCAL_CONF" 644 root:bind
{
    echo "// Made by install.sh from names.conf. Edit names.conf, not this file."
    for z in "${ZONES[@]}"; do
        echo "zone \"$z\" { type primary; file \"$ZONE_DIR/db.$z\"; };"
    done
} > "$tmpd/zones"
put "$tmpd/zones" "$ZONES_CONF" 644 root:bind

for z in "${ZONES[@]}"; do
    # The records first, so we can keep the old serial number when nothing changed.
    : > "$tmpd/body"
    for i in "${!NAMES[@]}"; do
        n="${NAMES[$i]}"
        [[ "$n" == "$z" || "$n" == *".$z" ]] || continue
        printf '%-40s IN A    %s\n' "$n." "${IPS[$i]}" >> "$tmpd/body"
    done
    dest="$ZONE_DIR/db.$z"
    serial="$(date +%s)"
    if [[ -f "$dest" ]] && cmp -s <(sed '1,/^;; records$/d' "$dest") "$tmpd/body"; then
        serial="$(awk '/; serial/ {print $1}' "$dest")"
    fi
    {
        echo "; $z - made by install.sh from names.conf. Edit names.conf, not this file."
        echo "; The real $z lives on the internet. On the range, this server answers for it."
        echo "\$TTL 300"
        echo "@ IN SOA $SERVER_NAME. hostmaster.$SERVER_NAME. ("
        echo "    $serial ; serial"
        echo "    3600 600 604800 300 )"
        echo "@ IN NS $SERVER_NAME."
        echo ";; records"
        cat "$tmpd/body"
    } > "$tmpd/zone"
    put "$tmpd/zone" "$dest" 644 root:bind
done
# Zones taken out of names.conf
if [[ -d "$ZONE_DIR" ]]; then
    for f in "$ZONE_DIR"/db.*; do
        [[ -e "$f" ]] || continue
        keep=0
        for z in "${ZONES[@]}"; do [[ "$f" == "$ZONE_DIR/db.$z" ]] && keep=1; done
        (( keep )) || remove "$f"
    done
fi
if (( GO )); then
    named-checkconf /etc/bind/named.conf || die "BIND config check failed (see above). Nothing was reloaded."
    for z in "${ZONES[@]}"; do
        named-checkzone -q "$z" "$ZONE_DIR/db.$z" || die "Zone $z failed its check."
    done
    echo "   BIND config and all zones check out"
fi
DNS_CHANGED=$CHANGED
CHANGED=0

say "3. Web pages"
cat > "$tmpd/index.html" <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Range connectivity check</title>
<style>body{font-family:system-ui,sans-serif;max-width:44rem;margin:2rem auto;padding:0 1rem;line-height:1.5;background:#fff;color:#111}code{background:#f2f2f2;padding:0 .3rem}</style></head>
<body>
<h1>Range connectivity check</h1>
<p>You reached <code>$SERVER_NAME</code> on the range's pretend internet. There is no real internet here.</p>
<p>This server answers the "am I online?" tests that Windows, Android, Apple, Firefox and Linux run,
so range machines do not show "No Internet". It also answers for some real names, like the time servers.
If you typed a real site's name and got this page, that site does not exist on the range.</p>
</body>
</html>
EOF
put "$tmpd/index.html" "$WEB_DIR/index.html" 644
if [[ ! -d "$ACME_DIR" ]]; then
    run install -d -m 755 "$ACME_DIR"
fi

# The nginx site. $1 = "yes" to add HTTPS (only once a certificate exists).
write_nginx() {
    local tls="$1" listen ssl=""
    listen="    listen 80;"
    if [[ "$tls" == "yes" ]]; then
        listen="$listen
    listen 443 ssl;"
        ssl="    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;"
    fi
    cat > "$tmpd/nginx" <<EOF
# Made by the Dire Wolf connectivity-check install.sh. Edit check.conf / names.conf and re-run instead.
# Each block answers one family of "am I online?" tests exactly the way the real servers do.
# Every name also serves /.well-known/acme-challenge/ so the range CA can check this server (HTTPS).

# Anything else, including $SERVER_NAME: the plain information page.
server {
    listen 80 default_server;
$( [[ "$tls" == "yes" ]] && echo "    listen 443 ssl default_server;" )
$ssl
    server_name $SERVER_NAME _;
    root $WEB_DIR;
    location /.well-known/acme-challenge/ { root $ACME_DIR; }
    location / { try_files \$uri /index.html; }
}

# Windows NCSI (the globe with "No Internet" in the taskbar)
server {
$listen
$ssl
    server_name www.msftconnecttest.com msftconnecttest.com www.msftncsi.com;
    location /.well-known/acme-challenge/ { root $ACME_DIR; }
    location = /connecttest.txt { default_type text/plain; return 200 "Microsoft Connect Test"; }
    location = /ncsi.txt        { default_type text/plain; return 200 "Microsoft NCSI"; }
    # Windows opens this when it thinks there is a sign-in page.
    location = /redirect        { return 302 http://$SERVER_NAME/; }
    location / { root $WEB_DIR; try_files /index.html =404; }
}

# Android and Chrome: any of these paths, an empty reply with code 204
server {
$listen
$ssl
    server_name connectivitycheck.gstatic.com connectivitycheck.android.com www.google.com google.com clients1.google.com clients3.google.com play.googleapis.com;
    location /.well-known/acme-challenge/ { root $ACME_DIR; }
    location ~ ^/(generate_204|gen_204)\$ { return 204; }
    location / { root $WEB_DIR; try_files /index.html =404; }
}

# Apple: captive.apple.com answers "Success" on any path
server {
$listen
$ssl
    server_name captive.apple.com;
    location /.well-known/acme-challenge/ { root $ACME_DIR; }
    location / { default_type text/html; return 200 "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>\n"; }
}
server {
$listen
$ssl
    server_name www.apple.com;
    location /.well-known/acme-challenge/ { root $ACME_DIR; }
    location = /library/test/success.html { default_type text/html; return 200 "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>\n"; }
    location / { root $WEB_DIR; try_files /index.html =404; }
}

# Firefox
server {
$listen
$ssl
    server_name detectportal.firefox.com;
    location /.well-known/acme-challenge/ { root $ACME_DIR; }
    location = /success.txt    { default_type text/plain; return 200 "success\n"; }
    location = /canonical.html { default_type text/html; return 200 '<meta http-equiv="refresh" content="0;url=https://support.mozilla.org/kb/captive-portal"/>\n'; }
    location / { root $WEB_DIR; try_files /index.html =404; }
}

# Linux NetworkManager (Ubuntu, GNOME and Kali, Debian, Fedora)
server {
$listen
$ssl
    server_name connectivity-check.ubuntu.com;
    location /.well-known/acme-challenge/ { root $ACME_DIR; }
    location / { add_header X-NetworkManager-Status online; return 204; }
}
server {
$listen
$ssl
    server_name nmcheck.gnome.org network-test.debian.org;
    location /.well-known/acme-challenge/ { root $ACME_DIR; }
    location = /check_network_status.txt { default_type text/plain; add_header X-NetworkManager-Status online; return 200 "NetworkManager is online\n"; }
    location = /nm                       { default_type text/plain; add_header X-NetworkManager-Status online; return 200 "NetworkManager is online\n"; }
    location / { root $WEB_DIR; try_files /index.html =404; }
}
server {
$listen
$ssl
    server_name fedoraproject.org;
    location /.well-known/acme-challenge/ { root $ACME_DIR; }
    location = /static/hotspot.txt { default_type text/plain; return 200 "OK"; }
    location / { root $WEB_DIR; try_files /index.html =404; }
}
EOF
    put "$tmpd/nginx" "$NGINX_SITE" 644
}

HAVE_CERT=no
[[ -f "$CERT_DIR/fullchain.pem" && "$HTTPS" == "yes" ]] && HAVE_CERT=yes
write_nginx "$HAVE_CERT"
if [[ ! -L "$NGINX_LINK" ]]; then
    run ln -sf "$NGINX_SITE" "$NGINX_LINK"
    CHANGED=1
fi
if [[ -L /etc/nginx/sites-enabled/default ]]; then
    run rm -f /etc/nginx/sites-enabled/default
    CHANGED=1
fi
WEB_CHANGED=$CHANGED
CHANGED=0

say "4. Firewall"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    run ufw allow 53
    run ufw allow 80/tcp
    run ufw allow 443/tcp
else
    echo "   ufw is off. Nothing to open."
fi

say "5. Start"
run systemctl enable named.service nginx.service
if (( DNS_CHANGED )) || ! systemctl is-active -q named.service; then
    run systemctl restart named.service
else
    echo "   DNS unchanged, left running"
fi
if (( WEB_CHANGED )) || ! systemctl is-active -q nginx.service; then
    if (( GO )); then nginx -t; fi
    run systemctl restart nginx.service
else
    echo "   web pages unchanged"
fi

say "6. HTTPS"
if [[ "$HTTPS" != "yes" ]]; then
    echo "   off (HTTPS=\"no\" in check.conf). The checks that matter use plain HTTP."
else
    # 6a. Trust the range root, so certbot can talk to the CA.
    if [[ -f "$RANGE_ROOT" ]]; then
        echo "   range root already trusted ($RANGE_ROOT)"
    elif (( GO )); then
        curl -fsS --noproxy '*' --max-time 15 "$CA_URL/root_ca.crt" -o "$tmpd/root.crt" || die "Could not download $CA_URL/root_ca.crt. Is the CA built and registered?"
        fp="$(openssl x509 -in "$tmpd/root.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')"
        echo "   range root fingerprint: $fp"
        if [[ -n "$CA_FINGERPRINT" ]]; then
            [[ "$fp" == "$(echo "$CA_FINGERPRINT" | tr -d ': ' | tr 'A-F' 'a-f')" ]] || die "Fingerprint does NOT match CA_FINGERPRINT in check.conf. Not trusting it."
            echo "   matches CA_FINGERPRINT"
        else
            warn "CA_FINGERPRINT is empty in check.conf, so the root was not checked."
        fi
        install -D -m 644 "$tmpd/root.crt" "$RANGE_ROOT"
        update-ca-certificates >/dev/null 2>&1
        echo "   + trusted the range root"
    else
        echo "   would download and trust $CA_URL/root_ca.crt"
    fi

    # 6b. Get (or grow) the certificate. The CA checks each name over HTTP, which is why DNS must be done first.
    mapfile -t cnames < <(cert_names)
    dargs=()
    for n in "${cnames[@]}"; do dargs+=(-d "$n"); done
    have_all=0
    if [[ -f "$CERT_DIR/fullchain.pem" ]]; then
        have_all=1
        sans="$(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -ext subjectAltName 2>/dev/null || true)"
        for n in "${cnames[@]}"; do [[ "$sans" == *"DNS:$n"* ]] || have_all=0; done
    fi
    if (( have_all )); then
        echo "   certificate already covers all ${#cnames[@]} names (certbot.timer renews it)"
    else
        run certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
            --server "$ACME_URL" --webroot -w "$ACME_DIR" --cert-name "$CERT_NAME" --expand \
            --deploy-hook "systemctl reload nginx" "${dargs[@]}"
    fi

    # 6c. Now that a certificate exists, add port 443.
    if [[ -f "$CERT_DIR/fullchain.pem" ]]; then
        write_nginx yes
        if (( CHANGED )); then
            nginx -t
            run systemctl reload nginx.service
        fi
    fi
fi

if (( GO )); then
    [[ -d "$BACKUP_DIR" ]] && echo "   Old files saved in $BACKUP_DIR"
    sleep 1
    check
    echo
    echo "   Next, if not done yet: sudo bash install.sh --registrar   (prints the commands for the root primary)"
else
    say "Test mode finished. Nothing changed. Run again with --go."
fi
