#!/usr/bin/env bash
# =============================================================================
# setup-registrar.sh — Add a domain registrar (Apache + PHP + SQLite) to the
#                      range root servers. The root servers also become the
#                      authoritative servers for the TLDs the registrar sells.
#
# Run on BOTH root VMs, after setup-root-dns.sh (and again any time you re-run
# setup-root-dns.sh, which overwrites the BIND config):
#   PRIMARY  : installs Apache/PHP, the web app, and hosts the TLD zones
#   SECONDARY: subscribes to a BIND catalog zone, so every TLD added on the
#              primary appears here automatically — no further work needed
#
# Usage (run from this folder):
#   sudo bash setup-registrar.sh --root1-ip 10.0.0.10 --root2-ip 10.0.0.11
#   Options:
#     --tlds "com net org lab"     TLDs to offer (default below)
#     --registrar-domain nic.lab   web site name (created as an A record)
#     --admin-pass 'S3cret!'       admin password (random if omitted)
#     --title "ACME Range Registrar"
#     --role primary|secondary     override auto-detection
#
# License: GPL-3.0, Dire Wolf Security.
# =============================================================================
set -euo pipefail

# ----------------------------- EDIT THESE ------------------------------------
ROOT1_NAME="a.root-servers.net"; ROOT1_IP=""
ROOT2_NAME="b.root-servers.net"; ROOT2_IP=""
TLDS="com net org edu gov lab"
REGISTRAR_DOMAIN="nic.lab"            # must be under one of the TLDs above
TITLE="Range Registrar"
ADMIN_USER="admin"; ADMIN_PASS=""
CATALOG_ZONE="catz.invalid"
ROLE=""
# -----------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root1-name) ROOT1_NAME="$2"; shift 2 ;;  --root1-ip) ROOT1_IP="$2"; shift 2 ;;
    --root2-name) ROOT2_NAME="$2"; shift 2 ;;  --root2-ip) ROOT2_IP="$2"; shift 2 ;;
    --tlds) TLDS="$2"; shift 2 ;;              --registrar-domain) REGISTRAR_DOMAIN="$2"; shift 2 ;;
    --admin-pass) ADMIN_PASS="$2"; shift 2 ;;  --title) TITLE="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "Unknown option $1"; exit 1 ;;
  esac
done

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
[[ -n "$ROOT1_IP" && -n "$ROOT2_IP" ]] || die "Set --root1-ip and --root2-ip."
command -v named >/dev/null || die "BIND not installed — run setup-root-dns.sh first."
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATZ="${CATALOG_ZONE%.}"

if [[ -z "$ROLE" ]]; then
  LOCAL_IPS=$(ip -o addr show | awk '{print $4}' | cut -d/ -f1)
  if   grep -qxF "$ROOT1_IP" <<<"$LOCAL_IPS"; then ROLE=primary
  elif grep -qxF "$ROOT2_IP" <<<"$LOCAL_IPS"; then ROLE=secondary
  else die "Neither root IP is on this host; pass --role."; fi
fi
log "Role: $ROLE"

# =============================================================================
# SECONDARY — consume the catalog zone
# =============================================================================
if [[ "$ROLE" == secondary ]]; then
  OPT=/etc/bind/named.conf.options
  # Minimal images (Proxmox containers) may not have python3, used just below.
  command -v python3 >/dev/null || { apt-get update -y >/dev/null || true; DEBIAN_FRONTEND=noninteractive apt-get install -y python3 >/dev/null || die "Could not install python3."; }
  mkdir -p /var/cache/bind/catz; chown bind:bind /var/cache/bind/catz
  if ! grep -q 'catalog-zones' "$OPT"; then
    cp "$OPT" "$OPT.bak-$(date +%s)"
    python3 - "$OPT" "$CATZ" "$ROOT1_IP" <<'PY'
import re, sys
p, catz, prim = sys.argv[1:]
s = open(p).read()
block = (f'\n    // Registrar TLDs: auto-provisioned from the primary\'s catalog zone\n'
         f'    catalog-zones {{\n        zone "{catz}" default-primaries {{ {prim}; }}\n'
         f'            zone-directory "catz" in-memory no min-update-interval 5;\n    }};\n')
m = re.search(r'options\s*\{', s)
depth, i = 0, m.end() - 1
while True:                       # find the matching closing brace of options { }
    if s[i] == '{': depth += 1
    elif s[i] == '}':
        depth -= 1
        if depth == 0: break
    i += 1
open(p, 'w').write(s[:i] + block + s[i:])
PY
    log "Added catalog-zones to $OPT"
  fi
  if ! grep -q "zone \"$CATZ\"" /etc/bind/named.conf.local; then
    cat >> /etc/bind/named.conf.local <<EOF

// Registrar catalog zone (lists the TLDs hosted on the primary)
zone "$CATZ" {
    type secondary;
    primaries { $ROOT1_IP; };
    file "/var/cache/bind/catz.db";
    allow-notify { $ROOT1_IP; };
};
EOF
    log "Added catalog zone to named.conf.local"
  fi
  named-checkconf || die "named-checkconf failed (backup of options saved alongside)."
  systemctl restart named
  sleep 3; rndc retransfer "$CATZ" 2>/dev/null || true
  log "Secondary subscribed. TLDs added on the primary will appear here within seconds."
  exit 0
fi

# =============================================================================
# PRIMARY
# =============================================================================
[[ -f /etc/bind/zones/db.root ]] || die "/etc/bind/zones/db.root missing — run setup-root-dns.sh first."
for f in registrar-apply app/lib.php app/cli.php app/public/index.php; do
  [[ -f "$HERE/$f" ]] || die "Missing $HERE/$f — run from the registrar/ folder."
done
REG_TLD="${REGISTRAR_DOMAIN#*.}"
[[ " $TLDS " == *" $REG_TLD "* ]] || TLDS="$TLDS $REG_TLD"

log "Installing Apache, PHP, SQLite..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null || warn "apt-get update failed (offline?)"
apt-get install -y apache2 libapache2-mod-php php-cli php-sqlite3 apache2-utils sqlite3 python3 sudo >/dev/null \
  || die "Package install failed — needs apt access (mirror) at install time."

log "Installing app to /opt/registrar"
mkdir -p /opt/registrar
cp -r "$HERE/app/." /opt/registrar/
chown -R root:root /opt/registrar; find /opt/registrar -type d -exec chmod 755 {} +; find /opt/registrar -type f -exec chmod 644 {} +
install -m 755 -o root -g root "$HERE/registrar-apply" /usr/local/sbin/registrar-apply

mkdir -p /etc/registrar /var/lib/registrar
chown www-data:www-data /var/lib/registrar; chmod 750 /var/lib/registrar
cat > /etc/registrar/registrar.ini <<EOF
; Range Registrar settings — read by the web app and registrar-apply
[registrar]
title        = "$TITLE"
root1_name   = "$ROOT1_NAME"
root1_ip     = "$ROOT1_IP"
root2_name   = "$ROOT2_NAME"
root2_ip     = "$ROOT2_IP"
catalog_zone = "$CATZ"
hostmaster   = "hostmaster.${ROOT1_NAME#*.}"
db_path      = "/var/lib/registrar/registrar.db"
reserved     = "nic,whois,registry,registrar,localhost"
EOF
chmod 644 /etc/registrar/registrar.ini

# The web app may run exactly one root command, with no arguments.
cat > /etc/sudoers.d/registrar <<'EOF'
www-data ALL=(root) NOPASSWD: /usr/local/sbin/registrar-apply ""
EOF
chmod 440 /etc/sudoers.d/registrar
visudo -cf /etc/sudoers.d/registrar >/dev/null || { rm -f /etc/sudoers.d/registrar; die "sudoers syntax error"; }

# BIND hooks (idempotent; registrar-apply also enforces these)
mkdir -p /etc/bind/zones/registrar
[[ -f /etc/bind/named.conf.registrar ]] || echo '// populated by registrar-apply' > /etc/bind/named.conf.registrar
grep -q 'named.conf.registrar' /etc/bind/named.conf.local || echo 'include "/etc/bind/named.conf.registrar";' >> /etc/bind/named.conf.local
[[ -f /etc/bind/zones/root.registrar ]] || echo '; populated by registrar-apply' > /etc/bind/zones/root.registrar
grep -q 'root.registrar' /etc/bind/zones/db.root || printf '\n; ---- Registrar-hosted TLDs ----\n$INCLUDE /etc/bind/zones/root.registrar\n' >> /etc/bind/zones/db.root
chown root:bind /etc/bind/named.conf.registrar /etc/bind/zones/root.registrar

# Seed DB (as www-data so it owns the file)
PHPCLI="sudo -u www-data php /opt/registrar/cli.php"
# shellcheck disable=SC2086
$PHPCLI add-tld $TLDS >/dev/null
if ! $PHPCLI list | grep -q "^  ${REGISTRAR_DOMAIN} "; then
  $PHPCLI add-a "$REGISTRAR_DOMAIN" "$ROOT1_IP" >/dev/null && log "Registered $REGISTRAR_DOMAIN -> $ROOT1_IP"
  $PHPCLI add-a "whois.$REG_TLD" "$ROOT1_IP" >/dev/null 2>&1 || true
fi

log "Publishing zones..."
/usr/local/sbin/registrar-apply --force

# ---- Apache ------------------------------------------------------------------
if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 14)
  GENERATED=1
fi
htpasswd -cbB /etc/registrar/htpasswd "$ADMIN_USER" "$ADMIN_PASS" >/dev/null
chown root:www-data /etc/registrar/htpasswd; chmod 640 /etc/registrar/htpasswd

cat > /etc/apache2/sites-available/registrar.conf <<EOF
<VirtualHost *:80>
    ServerName ${REGISTRAR_DOMAIN}
    ServerAlias www.${REGISTRAR_DOMAIN} ${ROOT1_IP} *
    DocumentRoot /opt/registrar/public
    DirectoryIndex index.php

    <Directory /opt/registrar/public>
        Options -Indexes
        AllowOverride None
        Require all granted
    </Directory>
    <Location /admin>
        AuthType Basic
        AuthName "Registrar admin"
        AuthUserFile /etc/registrar/htpasswd
        Require valid-user
    </Location>

    Header always set X-Frame-Options DENY
    Header always set X-Content-Type-Options nosniff
    ErrorLog \${APACHE_LOG_DIR}/registrar-error.log
    CustomLog \${APACHE_LOG_DIR}/registrar-access.log combined
</VirtualHost>
EOF
a2enmod headers >/dev/null
a2dissite 000-default >/dev/null 2>&1 || true
a2ensite registrar >/dev/null
sed -i 's/^ServerTokens .*/ServerTokens Prod/; s/^ServerSignature .*/ServerSignature Off/' /etc/apache2/conf-available/security.conf
apache2ctl configtest 2>&1 | grep -v '^Syntax OK' || true
systemctl enable apache2 >/dev/null 2>&1 || true
systemctl restart apache2

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then ufw allow 80/tcp >/dev/null; log "Opened 80/tcp"; fi

echo "Admin password: $ADMIN_PASS" > /root/registrar-admin.txt; chmod 600 /root/registrar-admin.txt

cat <<EOF

$(log "Registrar is up.")
  Site:        http://${REGISTRAR_DOMAIN}/   (or http://${ROOT1_IP}/)
  Admin:       http://${REGISTRAR_DOMAIN}/admin/   user: ${ADMIN_USER}  pass: ${ADMIN_PASS}$([[ -n "${GENERATED:-}" ]] && echo "  (saved in /root/registrar-admin.txt)")
  TLDs:        $TLDS
  CLI:         sudo -u www-data php /opt/registrar/cli.php list
  Publish:     sudo registrar-apply

  Next: run this same script on the SECONDARY (${ROOT2_IP}) so it picks up the TLDs.
EOF
