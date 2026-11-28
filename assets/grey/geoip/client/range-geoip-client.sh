#!/usr/bin/env bash
# range-geoip-client.sh - make a range web server geo-aware, with the range GeoIP databases.
#
# Get it from the GeoIP server and run it on the web server (Ubuntu 24.04):
#   curl -O http://@SERVER_NAME@/download/range-geoip-client.sh
#   sudo bash range-geoip-client.sh --apache          test mode: shows what it would do
#   sudo bash range-geoip-client.sh --apache --go     does it
#
# Pick one or more:
#   --apache   build and turn on mod_maxminddb (MaxMind's Apache module)
#   --nginx    install and turn on the nginx geoip2 module
#   --php      install the PHP reader (php-maxminddb) and the demo page geoip-demo.php
#   (none)     only download the databases to /var/lib/GeoIP and keep them updated
#
# Other options: --server NAME (default @SERVER_NAME@)
#
# Every run downloads the newest databases. A daily cron job does the same.
# License: GPL-3.0, Dire Wolf Security.

set -euo pipefail

SERVER="@SERVER_NAME@"
MOD_VERSION="@MOD_VERSION@"
DB_DIR="/var/lib/GeoIP"
UPDATER="/usr/local/sbin/range-geoip-update"
CRON_FILE="/etc/cron.d/range-geoip"

GO=0
APACHE=0
NGINX=0
PHP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --go)     GO=1 ;;
        --apache) APACHE=1 ;;
        --nginx)  NGINX=1 ;;
        --php)    PHP=1 ;;
        --server) SERVER="${2:-}"; shift ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
    esac
    shift
done

say()  { printf '\n== %s\n' "$*"; }
die()  { printf '   ERROR: %s\n' "$*"; exit 1; }
run() {
    if (( GO )); then printf '   + %s\n' "$*"; "$@"; else printf '   would run: %s\n' "$*"; fi
}

BASE="http://$SERVER/download"
(( GO )) && [[ $EUID -ne 0 ]] && die "Run with sudo."
say "Range GeoIP client, databases from $BASE"
(( GO )) || echo "   TEST MODE: nothing will change. Add --go to do it."
curl -fsS --noproxy '*' --max-time 10 -o /dev/null "$BASE/SHA256SUMS" || die "Can't reach $BASE/SHA256SUMS. Is $SERVER built and in DNS?"

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

# ---- 1. The updater: downloads the databases, checks them, swaps them in ----
say "1. Database updater ($UPDATER, runs daily)"
cat > "$tmpd/updater" <<EOF
#!/usr/bin/env bash
# range-geoip-update - fetch the range GeoIP databases from $SERVER. Written by range-geoip-client.sh.
# Prints what changed. Reloads Apache or nginx when a database changed (they read it at start).
set -euo pipefail
BASE="$BASE"
DB_DIR="$DB_DIR"
tmp="\$(mktemp -d)"
trap 'rm -rf "\$tmp"' EXIT
curl -fsS --noproxy '*' --max-time 30 -o "\$tmp/SHA256SUMS" "\$BASE/SHA256SUMS"
changed=0
mkdir -p "\$DB_DIR"
for e in GeoLite2-City GeoLite2-Country GeoLite2-ASN; do
    want="\$(awk -v f="\$e.mmdb" '\$2 == f {print \$1}' "\$tmp/SHA256SUMS")"
    [[ -n "\$want" ]] || { echo "\$e.mmdb is not listed on the server"; exit 1; }
    if [[ -f "\$DB_DIR/\$e.mmdb" ]] && [[ "\$(sha256sum "\$DB_DIR/\$e.mmdb" | cut -d' ' -f1)" == "\$want" ]]; then
        continue
    fi
    curl -fsS --noproxy '*' --max-time 60 -o "\$tmp/\$e.mmdb" "\$BASE/\$e.mmdb"
    got="\$(sha256sum "\$tmp/\$e.mmdb" | cut -d' ' -f1)"
    [[ "\$got" == "\$want" ]] || { echo "\$e.mmdb failed its SHA-256 check. Not installed."; exit 1; }
    install -m 644 "\$tmp/\$e.mmdb" "\$DB_DIR/\$e.mmdb.new"
    mv -f "\$DB_DIR/\$e.mmdb.new" "\$DB_DIR/\$e.mmdb"
    echo "updated \$DB_DIR/\$e.mmdb"
    changed=1
done
if (( changed )); then
    systemctl is-active -q apache2 2>/dev/null && systemctl reload apache2
    systemctl is-active -q nginx 2>/dev/null && systemctl reload nginx
fi
exit 0
EOF
if (( GO )); then
    install -m 755 "$tmpd/updater" "$UPDATER"
    printf '# Range GeoIP databases from %s. Written by range-geoip-client.sh.\n17 5 * * * root %s >/dev/null\n' "$SERVER" "$UPDATER" > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    "$UPDATER" || die "The download failed."
    echo "   databases in $DB_DIR: $(ls "$DB_DIR" | tr '\n' ' ')"
else
    echo "   would install $UPDATER and $CRON_FILE, then download the databases to $DB_DIR"
fi

# ---- 2. Apache: build mod_maxminddb ----
if (( APACHE )); then
    say "2. Apache mod_maxminddb $MOD_VERSION"
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y apache2 apache2-dev libmaxminddb-dev build-essential curl
    if [[ -f /usr/lib/apache2/modules/mod_maxminddb.so ]]; then
        echo "   mod_maxminddb is already built"
    elif (( GO )); then
        tarball="mod_maxminddb-$MOD_VERSION.tar.gz"
        curl -fsS --noproxy '*' --max-time 60 -o "$tmpd/$tarball" "$BASE/$tarball" || die "No $tarball on $SERVER. Run install.sh --go there while it has internet."
        curl -fsS --noproxy '*' --max-time 10 -o "$tmpd/SHA256SUMS" "$BASE/SHA256SUMS"
        want="$(awk -v f="$tarball" '$2 == f {print $1}' "$tmpd/SHA256SUMS")"
        [[ -n "$want" && "$(sha256sum "$tmpd/$tarball" | cut -d' ' -f1)" == "$want" ]] || die "$tarball failed its SHA-256 check."
        tar -xzf "$tmpd/$tarball" -C "$tmpd"
        (cd "$tmpd/mod_maxminddb-$MOD_VERSION" && ./configure && make && make install)
        [[ -f /usr/lib/apache2/modules/mod_maxminddb.so ]] || die "The build finished but mod_maxminddb.so is not in /usr/lib/apache2/modules."
        echo "   + built and installed mod_maxminddb.so"
    else
        echo "   would download $BASE/mod_maxminddb-$MOD_VERSION.tar.gz, check it, then ./configure && make && make install"
    fi
    if (( GO )); then
        # make install may add a LoadModule line to apache2.conf; Ubuntu wants it in mods-available instead.
        sed -i '/^LoadModule maxminddb_module/d' /etc/apache2/apache2.conf
        echo "LoadModule maxminddb_module /usr/lib/apache2/modules/mod_maxminddb.so" > /etc/apache2/mods-available/maxminddb.load
        curl -fsS --noproxy '*' --max-time 10 -o /etc/apache2/mods-available/maxminddb.conf "$BASE/apache-maxminddb.conf"
        a2enmod -q maxminddb
        apache2ctl configtest
        systemctl restart apache2
        echo "   + mod_maxminddb is on. Settings: /etc/apache2/mods-available/maxminddb.conf"
    else
        echo "   would write /etc/apache2/mods-available/maxminddb.{load,conf}, a2enmod maxminddb, restart Apache"
    fi
fi

# ---- 3. nginx: the packaged geoip2 module ----
if (( NGINX )); then
    say "3. nginx geoip2 module"
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y nginx libnginx-mod-http-geoip2
    if (( GO )); then
        curl -fsS --noproxy '*' --max-time 10 -o /etc/nginx/conf.d/range-geoip2.conf "$BASE/nginx-geoip2.conf"
        nginx -t
        systemctl reload-or-restart nginx
        echo "   + variables \$geoip2_city, \$geoip2_country_code ... are ready. Settings: /etc/nginx/conf.d/range-geoip2.conf"
    else
        echo "   would write /etc/nginx/conf.d/range-geoip2.conf and reload nginx"
    fi
fi

# ---- 4. PHP reader and the demo page ----
if (( PHP )); then
    say "4. PHP reader and demo page"
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y php-maxminddb
    if (( GO )); then
        if [[ -d /var/www/html ]]; then
            curl -fsS --noproxy '*' --max-time 10 -o /var/www/html/geoip-demo.php "$BASE/geoip-demo.php"
            echo "   + demo page: http://<this server>/geoip-demo.php"
        else
            echo "   no /var/www/html here. Get the demo page yourself: $BASE/geoip-demo.php"
        fi
        systemctl is-active -q apache2 2>/dev/null && systemctl restart apache2
        systemctl list-units --type=service --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}' | xargs -r systemctl restart
    else
        echo "   would put geoip-demo.php in /var/www/html"
    fi
fi

say "Done"
if (( GO )); then
    echo "   Test it: mmdblookup --file $DB_DIR/GeoLite2-City.mmdb --ip 192.168.103.1 city names en"
    echo "   (sudo apt install mmdb-bin for mmdblookup)"
else
    echo "   Test mode finished. Nothing changed. Run again with --go."
fi
