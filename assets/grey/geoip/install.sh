#!/usr/bin/env bash
# install.sh - Dire Wolf range GeoIP server (geoip.lab): builds MaxMind-format GeoIP databases
# from the range registry and hands them out, the way MaxMind does on the real internet.
#
# Usage (run from this folder, on Ubuntu 24.04, a VM or a Proxmox container):
#   sudo bash install.sh                 test mode: shows what it would do, changes nothing
#   sudo bash install.sh --go            does it (or rebuilds after a registry change), then checks
#   sudo bash install.sh --check         services, downloads, update endpoint, a lookup for every network
#   sudo bash install.sh --registrar     prints the command to run on the root primary (README step 3)
#
# Other options: --ip ADDRESS (this server's address, if it guesses wrong)   --https yes|no
#
# Safe to run again. Files it replaces are first copied to /var/backups/direwolf-geoip/.
# After you change registry.csv: git pull, then sudo bash install.sh --go
#
# License: GPL-3.0, Dire Wolf Security.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HERE/geoip.conf"
BUILDER="$HERE/tools/build-mmdb.py"
TESTER="$HERE/tools/test-mmdb.py"
CLIENT_DIR="$HERE/client"

WORK_DIR="/var/lib/direwolf-geoip"
WEB_DIR="/var/www/geoip"
DL_DIR="$WEB_DIR/download"
UPDATE_DIR="$WEB_DIR/updates"
ACME_DIR="/var/www/geoip-acme"
DB_DIR="/var/lib/GeoIP"
NGINX_SITE="/etc/nginx/sites-available/direwolf-geoip"
NGINX_LINK="/etc/nginx/sites-enabled/direwolf-geoip"
CERT_NAME="direwolf-geoip"
CERT_DIR="/etc/letsencrypt/live/$CERT_NAME"
RANGE_ROOT="/usr/local/share/ca-certificates/direwolf-range-root.crt"
BACKUP_DIR="/var/backups/direwolf-geoip/$(date +%Y%m%d-%H%M%S)"
EDITIONS=(GeoLite2-City GeoLite2-Country GeoLite2-ASN)

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
        -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
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
[[ -f "$SETTINGS" ]] || die "Missing geoip.conf. Run this from the repo folder (assets/grey/geoip)."
# shellcheck source=geoip.conf
source "$SETTINGS"
[[ -n "$OPT_HTTPS" ]] && HTTPS="$OPT_HTTPS"
[[ "$HTTPS" == "yes" || "$HTTPS" == "no" ]] || die "HTTPS must be yes or no (got '$HTTPS')."

if [[ "$REGISTRY_FILE" == /* ]]; then
    REGISTRY="$REGISTRY_FILE"
else
    REGISTRY="$HERE/$REGISTRY_FILE"
fi
if [[ ! -f "$REGISTRY" || ! -f "$(dirname "$REGISTRY")/registry.py" ]]; then
    die "Can't find the registry at $REGISTRY. Clone both folders:  git sparse-checkout set assets/grey/geoip network/registry"
fi
REGISTRY="$(cd "$(dirname "$REGISTRY")" && pwd)/$(basename "$REGISTRY")"

SERVER_IP="$OPT_IP"
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' | head -n1)"
fi
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[[ -n "$SERVER_IP" ]] || die "Can't tell this server's address. Use --ip ADDRESS."

# ---- --registrar: the command for the root primary ----
if (( REGISTRAR )); then
    say "Run this on the root primary (root-a), then publish:"
    echo "   sudo -u www-data php /opt/registrar/cli.php add-a $SERVER_NAME $SERVER_IP"
    echo "   sudo registrar-apply"
    exit 0
fi

# ---- --check ----
check() {
    local fails=0 e
    say "Services"
    if systemctl is-active -q nginx.service; then echo "   ok    nginx is running"; else echo "   FAIL  nginx is not running"; fails=$((fails + 1)); fi

    say "Databases in $DB_DIR (the copies this server's own web page uses)"
    for e in "${EDITIONS[@]}"; do
        if [[ -s "$DB_DIR/$e.mmdb" ]]; then
            echo "   ok    $e.mmdb  $(stat -c %s "$DB_DIR/$e.mmdb") bytes, md5 $(md5sum "$DB_DIR/$e.mmdb" | cut -c1-32)"
        else
            echo "   FAIL  $e.mmdb is missing"; fails=$((fails + 1))
        fi
    done

    say "A lookup for every network in the registry (python3-maxminddb, a different reader from our writer)"
    if python3 "$TESTER" --registry "$REGISTRY" --db "$DB_DIR"; then :; else fails=$((fails + 1)); fi

    say "mmdblookup, the C library Apache and nginx use"
    local first
    first="$(awk -F, 'NR==2 {split($1, a, "/"); print a[1]}' "$REGISTRY")"
    if mmdblookup --file "$DB_DIR/GeoLite2-City.mmdb" --ip "$first" city names en >/dev/null 2>&1; then
        echo "   ok    $first -> $(mmdblookup --file "$DB_DIR/GeoLite2-City.mmdb" --ip "$first" city names en | tr -d '\n' | sed 's/ *<utf8_string>//; s/^ *//')"
    else
        echo "   FAIL  mmdblookup found nothing for $first"; fails=$((fails + 1))
    fi

    say "Web (http://$SERVER_NAME/)"
    local url
    for url in "/" "/whoami" "/download/SHA256SUMS" "/download/GeoLite2-City.mmdb" "/download/range-geoip-client.sh"; do
        if curl -fsS --noproxy '*' --max-time 5 -o /dev/null "http://127.0.0.1:$HTTP_PORT$url"; then
            echo "   ok    $url"
        else
            echo "   FAIL  $url"; fails=$((fails + 1))
        fi
    done
    if [[ -s "$DL_DIR/mod_maxminddb-$MOD_MAXMINDDB_VERSION.tar.gz" ]]; then
        echo "   ok    /download/mod_maxminddb-$MOD_MAXMINDDB_VERSION.tar.gz (for Apache servers)"
    else
        echo "   WARN  mod_maxminddb source is not here yet. Run --go once while this server has internet."
    fi

    say "Update endpoint (what the stock geoipupdate tool asks for)"
    local md5 code
    md5="$(md5sum "$DB_DIR/GeoLite2-City.mmdb" 2>/dev/null | cut -c1-32)"
    code="$(curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HTTP_PORT/geoip/databases/GeoLite2-City/update?db_md5=0")"
    if [[ "$code" == "200" ]]; then echo "   ok    new copy offered (200)"; else echo "   FAIL  got $code, want 200"; fails=$((fails + 1)); fi
    code="$(curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HTTP_PORT/geoip/databases/GeoLite2-City/update?db_md5=$md5")"
    if [[ "$code" == "304" ]]; then echo "   ok    up to date answer (304)"; else echo "   FAIL  got $code, want 304"; fails=$((fails + 1)); fi
    if [[ "$HTTPS" == "yes" ]]; then
        if [[ -f "$CERT_DIR/fullchain.pem" ]] && curl -fsS --max-time 5 -o /dev/null --resolve "$SERVER_NAME:443:127.0.0.1" "https://$SERVER_NAME/"; then
            echo "   ok    HTTPS on 443 (geoipupdate can use it)"
        else
            echo "   FAIL  HTTPS is on in geoip.conf but https://$SERVER_NAME/ does not work"; fails=$((fails + 1))
        fi
    else
        echo "   note  HTTPS is off: the stock geoipupdate tool needs it. Web servers use the client script instead."
    fi

    say "Through DNS"
    if getent hosts "$SERVER_NAME" >/dev/null; then
        echo "   ok    $SERVER_NAME -> $(getent hosts "$SERVER_NAME" | awk '{print $1}')"
    else
        echo "   WARN  $SERVER_NAME does not resolve yet. Run: sudo bash install.sh --registrar"
    fi

    echo
    if (( fails )); then echo "   $fails check(s) failed."; return 1; fi
    echo "   All checks passed."
}

if (( CHECK )); then
    check
    exit $?
fi

# ---- Install ----
say "GeoIP server: $SERVER_NAME at $SERVER_IP"
echo "   registry: $REGISTRY"
echo "   HTTPS:    $HTTPS"
(( GO )) || echo "   TEST MODE: nothing will change. Add --go to do it."
if (( GO )) && [[ $EUID -ne 0 ]]; then die "Run with sudo."; fi
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || warn "Written for Ubuntu 24.04. This is ${PRETTY_NAME:-unknown}."

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

say "1. Check the registry"
python3 "$(dirname "$REGISTRY")/registry.py" "$REGISTRY" || die "Fix the registry first."

say "2. Packages"
pkgs=(nginx libnginx-mod-http-geoip2 mmdb-bin python3 python3-maxminddb curl gzip openssl)
[[ "$HTTPS" == "yes" ]] && pkgs+=(certbot)
missing=()
for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if (( ${#missing[@]} )); then
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
else
    echo "   all installed"
fi

say "3. Build the databases"
if (( GO )); then
    build="$WORK_DIR/build-$(date +%Y%m%d-%H%M%S)"
    install -d -m 755 "$build"
    # Same date all day, so running --go again with no registry change gives the very same files.
    python3 "$BUILDER" --registry "$REGISTRY" --out "$build" --name "$REGISTRY_NAME" --date "$(date -u +%F)"
    python3 "$TESTER" --registry "$REGISTRY" --db "$build" || die "The new databases failed their test. Nothing was published."
    # Keep the last five builds.
    ls -1d "$WORK_DIR"/build-* 2>/dev/null | sort | head -n -5 | xargs -r rm -rf
else
    build="$tmpd/build"
    echo "   would build into $WORK_DIR/build-<date> and test every network"
fi

say "4. Publish"
DB_CHANGED=0
for d in "$DB_DIR" "$DL_DIR" "$UPDATE_DIR" "$ACME_DIR"; do
    [[ -d "$d" ]] || run install -d -m 755 "$d"
done
if (( GO )); then
    for e in "${EDITIONS[@]}"; do
        CHANGED=0
        put "$build/$e.mmdb" "$DB_DIR/$e.mmdb" 644
        put "$build/$e.mmdb" "$DL_DIR/$e.mmdb" 644
        (( CHANGED )) && DB_CHANGED=1
        gzip -9nc "$build/$e.mmdb" > "$tmpd/$e.mmdb.gz"
        put "$tmpd/$e.mmdb.gz" "$DL_DIR/$e.mmdb.gz" 644
        put "$tmpd/$e.mmdb.gz" "$UPDATE_DIR/$e.mmdb.gz" 644
    done
    cp "$REGISTRY" "$tmpd/registry.csv"
    put "$tmpd/registry.csv" "$DL_DIR/registry.csv" 644
    (cd "$DL_DIR" && sha256sum GeoLite2-*.mmdb GeoLite2-*.mmdb.gz registry.csv > "$tmpd/SHA256SUMS")
else
    echo "   would copy the databases to $DB_DIR and $DL_DIR (plain and .gz) and write SHA256SUMS"
    : > "$tmpd/SHA256SUMS"
fi

# Client files for range web servers.
sed -e "s|@SERVER_NAME@|$SERVER_NAME|g" -e "s|@MOD_VERSION@|$MOD_MAXMINDDB_VERSION|g" \
    "$CLIENT_DIR/range-geoip-client.sh" > "$tmpd/range-geoip-client.sh"
put "$tmpd/range-geoip-client.sh" "$DL_DIR/range-geoip-client.sh" 644
for f in apache-maxminddb.conf nginx-geoip2.conf geoip-demo.php GeoIP.conf.example; do
    sed -e "s|@SERVER_NAME@|$SERVER_NAME|g" "$CLIENT_DIR/$f" > "$tmpd/$f"
    put "$tmpd/$f" "$DL_DIR/$f" 644
done

# mod_maxminddb source, fetched once while there is internet, checked against its SHA-256.
mod_file="$DL_DIR/mod_maxminddb-$MOD_MAXMINDDB_VERSION.tar.gz"
if [[ -s "$mod_file" ]] && echo "$MOD_MAXMINDDB_SHA256  $mod_file" | sha256sum -c --quiet - 2>/dev/null; then
    echo "   mod_maxminddb $MOD_MAXMINDDB_VERSION source already here"
elif (( GO )); then
    if curl -fsSL --max-time 60 "$MOD_MAXMINDDB_URL" -o "$tmpd/mod.tar.gz" &&
       echo "$MOD_MAXMINDDB_SHA256  $tmpd/mod.tar.gz" | sha256sum -c --quiet -; then
        install -m 644 "$tmpd/mod.tar.gz" "$mod_file"
        echo "   + downloaded and checked mod_maxminddb $MOD_MAXMINDDB_VERSION"
    else
        warn "Could not download mod_maxminddb (no internet?). Apache servers can't build it until you run --go again online."
    fi
else
    echo "   would download $MOD_MAXMINDDB_URL and check its SHA-256"
fi
if (( GO )); then
    (cd "$DL_DIR" && sha256sum ./*.sh ./*.conf ./*.php ./*.example ./mod_maxminddb-*.tar.gz 2>/dev/null | sed 's|\./||' >> "$tmpd/SHA256SUMS")
    put "$tmpd/SHA256SUMS" "$DL_DIR/SHA256SUMS" 644
fi

say "5. Web site"
cp "$HERE/web/index.html" "$tmpd/index.html"
sed -i -e "s|@SERVER_NAME@|$SERVER_NAME|g" -e "s|@REGISTRY_NAME@|$REGISTRY_NAME|g" "$tmpd/index.html"
put "$tmpd/index.html" "$WEB_DIR/index.html" 644

# The update endpoint the stock geoipupdate tool calls:
#   GET /geoip/databases/<edition>/update?db_md5=<md5 of the copy it has>
# 304 = you are up to date. 200 = here is a new copy (gzip), with its md5 in X-Database-MD5.
update_locations() {
    local e md5
    for e in "${EDITIONS[@]}"; do
        if [[ -f "$DB_DIR/$e.mmdb" ]]; then md5="$(md5sum "$DB_DIR/$e.mmdb" | cut -c1-32)"; else md5="none"; fi
        cat <<EOF
    location = /geoip/databases/$e/update {
        if (\$arg_db_md5 = $md5) { return 304; }
        add_header X-Database-MD5 $md5 always;
        default_type application/gzip;
        alias $UPDATE_DIR/$e.mmdb.gz;
    }
EOF
    done
}

# Everything both ports serve.
site_body() {
    cat <<EOF
    root $WEB_DIR;
    location = / { try_files /index.html =404; }
    location = /whoami {
        default_type application/json;
        add_header Access-Control-Allow-Origin * always;
        add_header Cache-Control no-store always;
        return 200 '{"ip":"\$remote_addr","country":"\$geo_country","country_name":"\$geo_country_name","region":"\$geo_region","city":"\$geo_city","postal":"\$geo_postal","latitude":"\$geo_lat","longitude":"\$geo_lon","accuracy_km":"\$geo_accuracy","time_zone":"\$geo_tz","asn":"\$geo_asn","as_org":"\$geo_as_org"}\n';
    }
    location /download/ { autoindex on; }
    location /.well-known/acme-challenge/ { root $ACME_DIR; }
$(update_locations)
    location / { return 404; }
EOF
}

write_nginx() {
    local with_https="$1"
    {
        cat <<EOF
# Dire Wolf range GeoIP server. Written by assets/grey/geoip/install.sh. Changes here are overwritten.
# Looks up every visitor in our own database, the same way a range web server would.
geoip2 $DB_DIR/GeoLite2-City.mmdb {
    \$geo_country      country iso_code;
    \$geo_country_name country names en;
    \$geo_region       subdivisions 0 names en;
    \$geo_city         city names en;
    \$geo_postal       postal code;
    \$geo_lat          location latitude;
    \$geo_lon          location longitude;
    \$geo_accuracy     location accuracy_radius;
    \$geo_tz           location time_zone;
}
geoip2 $DB_DIR/GeoLite2-ASN.mmdb {
    \$geo_asn    autonomous_system_number;
    \$geo_as_org autonomous_system_organization;
}

server {
    listen $HTTP_PORT default_server;
    server_name $SERVER_NAME;
$(site_body)
}
EOF
        if [[ "$with_https" == "yes" ]]; then
            cat <<EOF

server {
    listen 443 ssl default_server;
    server_name $SERVER_NAME;
    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
$(site_body)
}
EOF
        fi
    } > "$tmpd/nginx"
    put "$tmpd/nginx" "$NGINX_SITE" 644
}

HAVE_CERT=no
[[ -f "$CERT_DIR/fullchain.pem" && "$HTTPS" == "yes" ]] && HAVE_CERT=yes
CHANGED=0
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

say "6. Start"
if (( GO )); then
    nginx -t
    run systemctl enable nginx.service
    # nginx reads the databases when it starts, so a new database needs a reload too.
    if (( WEB_CHANGED || DB_CHANGED )) || ! systemctl is-active -q nginx.service; then
        if systemctl is-active -q nginx.service; then run systemctl reload nginx.service; else run systemctl restart nginx.service; fi
    else
        echo "   nothing changed, left running"
    fi
else
    echo "   would check the nginx settings and start or reload nginx"
fi

say "7. HTTPS"
if [[ "$HTTPS" != "yes" ]]; then
    echo "   off (HTTPS=\"no\" in geoip.conf). Downloads and the web page use plain HTTP."
else
    if [[ -f "$RANGE_ROOT" ]]; then
        echo "   range root already trusted ($RANGE_ROOT)"
    elif (( GO )); then
        curl -fsS --noproxy '*' --max-time 15 "$CA_URL/root_ca.crt" -o "$tmpd/root.crt" || die "Could not download $CA_URL/root_ca.crt. Is the CA built and registered?"
        fp="$(openssl x509 -in "$tmpd/root.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')"
        echo "   range root fingerprint: $fp"
        if [[ -n "$CA_FINGERPRINT" ]]; then
            [[ "$fp" == "$(echo "$CA_FINGERPRINT" | tr -d ': ' | tr 'A-F' 'a-f')" ]] || die "Fingerprint does NOT match CA_FINGERPRINT in geoip.conf. Not trusting it."
            echo "   matches CA_FINGERPRINT"
        else
            warn "CA_FINGERPRINT is empty in geoip.conf, so the root was not checked."
        fi
        install -D -m 644 "$tmpd/root.crt" "$RANGE_ROOT"
        update-ca-certificates >/dev/null 2>&1
        echo "   + trusted the range root"
    else
        echo "   would download and trust $CA_URL/root_ca.crt"
    fi

    cnames=("$SERVER_NAME")
    for n in $EXTRA_CERT_NAMES; do cnames+=("$n"); done
    dargs=()
    for n in "${cnames[@]}"; do dargs+=(-d "$n"); done
    have_all=0
    if [[ -f "$CERT_DIR/fullchain.pem" ]]; then
        have_all=1
        sans="$(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -ext subjectAltName 2>/dev/null || true)"
        for n in "${cnames[@]}"; do [[ "$sans" == *"DNS:$n"* ]] || have_all=0; done
    fi
    if (( have_all )); then
        echo "   certificate already covers ${cnames[*]} (certbot.timer renews it)"
    else
        run certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
            --server "$ACME_URL" --webroot -w "$ACME_DIR" --cert-name "$CERT_NAME" --expand \
            --deploy-hook "systemctl reload nginx" "${dargs[@]}"
    fi
    if [[ -f "$CERT_DIR/fullchain.pem" ]]; then
        CHANGED=0
        write_nginx yes
        if (( CHANGED )) && (( GO )); then
            nginx -t
            run systemctl reload nginx.service
        fi
    fi
fi

if (( GO )); then
    [[ -d "$BACKUP_DIR" ]] && echo "   Old files saved in $BACKUP_DIR"
    sleep 1
    check || true
    echo
    echo "   Next, if not done yet: sudo bash install.sh --registrar   (prints the command for the root primary)"
else
    say "Test mode finished. Nothing changed. Run again with --go."
fi
