#!/usr/bin/env bash
# =============================================================================
# setup-root-dns.sh  —  Turn an Ubuntu 24.04 VM into a ROOT (".") DNS server
#                      for an offline / air-gapped cyber range.
#
# Run the SAME script on both root servers. It works out whether this box is
# the primary or secondary by checking which ROOT IP is bound to a local NIC.
#   Primary   = holds the master copy of the "." zone (you edit it here)
#   Secondary = pulls the "." zone from the primary via AXFR (NOTIFY-driven)
#
# Usage:
#   sudo ./setup-root-dns.sh                         # uses values below
#   sudo ./setup-root-dns.sh --root1-ip 10.0.0.10 --root2-ip 10.0.0.11
#   sudo ./setup-root-dns.sh --role primary          # force the role
#
# Requires: static IPs already set (netplan), and apt access to bind9 at
# install time (local mirror, apt-cacher, or install before going offline).
#
# License: GPL-3.0, Dire Wolf Security.
# =============================================================================
set -euo pipefail

# ----------------------------- EDIT THESE ------------------------------------
ROOT1_NAME="a.root-servers.net"     # primary root server name
ROOT1_IP=""                          # e.g. 10.0.0.10   (REQUIRED)
ROOT1_IP6=""                         # optional IPv6, leave blank to skip
ROOT2_NAME="b.root-servers.net"     # secondary root server name
ROOT2_IP=""                          # e.g. 10.0.0.11   (REQUIRED)
ROOT2_IP6=""                         # optional IPv6
SOA_EMAIL="hostmaster.root-servers.net."   # SOA RNAME (@ written as .)
ROLE=""                              # "primary" | "secondary" | "" = auto
ROOT_TTL="518400"                    # TTL for root NS / glue (6 days, like real root)
# -----------------------------------------------------------------------------

usage() { sed -n '2,19p' "$0"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root1-name) ROOT1_NAME="$2"; shift 2 ;;
    --root1-ip)   ROOT1_IP="$2";   shift 2 ;;
    --root1-ip6)  ROOT1_IP6="$2";  shift 2 ;;
    --root2-name) ROOT2_NAME="$2"; shift 2 ;;
    --root2-ip)   ROOT2_IP="$2";   shift 2 ;;
    --root2-ip6)  ROOT2_IP6="$2";  shift 2 ;;
    --role)       ROLE="$2";       shift 2 ;;
    -h|--help)    usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
[[ -n "$ROOT1_IP" && -n "$ROOT2_IP" ]] || die "Set ROOT1_IP and ROOT2_IP (edit the script or use --root1-ip/--root2-ip)."

# Normalise names to FQDN with trailing dot
fqdn() { local n="${1%.}"; echo "${n}."; }
R1=$(fqdn "$ROOT1_NAME"); R2=$(fqdn "$ROOT2_NAME")

# ---- Determine role ---------------------------------------------------------
LOCAL_IPS=$(ip -o addr show | awk '{print $4}' | cut -d/ -f1)
if [[ -z "$ROLE" ]]; then
  if   grep -qxF "$ROOT1_IP" <<<"$LOCAL_IPS"; then ROLE="primary"
  elif grep -qxF "$ROOT2_IP" <<<"$LOCAL_IPS"; then ROLE="secondary"
  else die "Neither $ROOT1_IP nor $ROOT2_IP is on this host. Set the static IP first, or pass --role."
  fi
fi
[[ "$ROLE" == "primary" || "$ROLE" == "secondary" ]] || die "--role must be primary or secondary"
log "Configuring this host as the ROOT ${ROLE^^} ($( [[ $ROLE == primary ]] && echo "$R1 / $ROOT1_IP" || echo "$R2 / $ROOT2_IP"))"

# ---- Install ----------------------------------------------------------------
if ! command -v named >/dev/null 2>&1 || ! command -v dig >/dev/null 2>&1; then
  log "Installing bind9 and dig..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y || warn "apt-get update failed (offline?) — trying install anyway"
  apt-get install -y bind9 bind9-utils bind9-dnsutils || die "Could not install bind9. Point apt at a local mirror or install before going offline."
else
  log "bind9 already installed."
fi

# ---- Back up existing config -------------------------------------------------
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="/etc/bind/backup-$TS"
mkdir -p "$BACKUP"
cp -a /etc/bind/named.conf* "$BACKUP"/ 2>/dev/null || true
log "Backed up existing config to $BACKUP"

mkdir -p /etc/bind/zones /var/log/named
chown bind:bind /var/log/named
chown root:bind /etc/bind/zones; chmod 2775 /etc/bind/zones

# ---- named.conf (no default-zones: they contain a "." hint zone that would clash)
cat > /etc/bind/named.conf <<'EOF'
// Managed by setup-root-dns.sh — cyber range ROOT server
// NOTE: named.conf.default-zones is intentionally NOT included
// (it defines zone "." as type hint, which conflicts with serving the root).
include "/etc/bind/named.conf.options";
include "/etc/bind/named.conf.logging";
include "/etc/bind/named.conf.local";
EOF

# ---- named.conf.options -------------------------------------------------------
LISTEN6="none;"
[[ -n "$ROOT1_IP6$ROOT2_IP6" ]] && LISTEN6="any;"
cat > /etc/bind/named.conf.options <<EOF
// Managed by setup-root-dns.sh
options {
    directory "/var/cache/bind";

    // Authoritative only — a root server never recurses
    recursion no;
    allow-recursion { none; };
    allow-query { any; };
    allow-query-cache { none; };

    listen-on { any; };
    listen-on-v6 { ${LISTEN6} };

    // Offline range: no real trust anchors, no DNSSEC validation
    dnssec-validation no;

    // Transfers are only allowed to the other root (set per-zone below)
    allow-transfer { none; };

    notify yes;
    minimal-responses no-auth-recursive;
    version "range-root";
    hostname none;
    server-id none;
};
EOF

# ---- logging -------------------------------------------------------------------
cat > /etc/bind/named.conf.logging <<'EOF'
// Managed by setup-root-dns.sh
logging {
    channel general_log {
        file "/var/log/named/named.log" versions 5 size 20m;
        print-time yes; print-severity yes; print-category yes;
        severity info;
    };
    channel query_log {
        file "/var/log/named/query.log" versions 5 size 50m;
        print-time yes;
        severity info;
    };
    category default  { general_log; };
    category xfer-in  { general_log; };
    category xfer-out { general_log; };
    category notify   { general_log; };
    category queries  { query_log; };   // handy for range scoring/forensics
    category lame-servers { null; };
};
EOF

# AppArmor: allow writing logs to /var/log/named (Ubuntu profile already allows
# /var/log/named/** on 24.04, but make sure).
if [[ -d /etc/apparmor.d/local ]]; then
  LOCAL_AA=/etc/apparmor.d/local/usr.sbin.named
  grep -q '/var/log/named' "$LOCAL_AA" 2>/dev/null || {
    echo "/var/log/named/** rw," >> "$LOCAL_AA"
    echo "/var/log/named/ rw,"  >> "$LOCAL_AA"
    apparmor_parser -r /etc/apparmor.d/usr.sbin.named 2>/dev/null || true
  }
fi

# ---- Zone definition ----------------------------------------------------------
if [[ "$ROLE" == "primary" ]]; then
  XFR_PEERS="${ROOT2_IP};"; [[ -n "$ROOT2_IP6" ]] && XFR_PEERS+=" ${ROOT2_IP6};"
  cat > /etc/bind/named.conf.local <<EOF
// Managed by setup-root-dns.sh — ROOT PRIMARY
zone "." {
    type primary;
    file "/etc/bind/zones/db.root";
    allow-transfer { ${XFR_PEERS} };
    also-notify { ${XFR_PEERS} };
    notify explicit;
};
EOF
else
  cat > /etc/bind/named.conf.local <<EOF
// Managed by setup-root-dns.sh — ROOT SECONDARY
zone "." {
    type secondary;
    primaries { ${ROOT1_IP}; };
    file "/var/cache/bind/db.root";
    allow-notify { ${ROOT1_IP}; };
};
EOF
fi

# ---- Root zone file (primary only) --------------------------------------------
if [[ "$ROLE" == "primary" ]]; then
  SERIAL=$(date +%Y%m%d)01
  DELEG=/etc/bind/zones/root.delegations
  cat > /etc/bind/zones/db.root <<EOF
; =====================================================================
; ROOT ZONE "."  — cyber range (managed by setup-root-dns.sh)
; Add TLD delegations in: ${DELEG}  (or use add-tld.sh)
; Remember to bump the serial after edits (add-tld.sh does it for you).
; =====================================================================
\$TTL 86400
\$ORIGIN .
@   IN SOA ${R1} ${SOA_EMAIL} (
        ${SERIAL} ; serial
        1800       ; refresh
        900        ; retry
        604800     ; expire
        86400 )    ; negative TTL

; ---- Root name servers ----
@               ${ROOT_TTL} IN NS  ${R1}
@               ${ROOT_TTL} IN NS  ${R2}

; ---- Root server addresses ----
${R1}  ${ROOT_TTL} IN A    ${ROOT1_IP}
${R2}  ${ROOT_TTL} IN A    ${ROOT2_IP}
EOF
  [[ -n "$ROOT1_IP6" ]] && echo "${R1}  ${ROOT_TTL} IN AAAA ${ROOT1_IP6}" >> /etc/bind/zones/db.root
  [[ -n "$ROOT2_IP6" ]] && echo "${R2}  ${ROOT_TTL} IN AAAA ${ROOT2_IP6}" >> /etc/bind/zones/db.root
  cat >> /etc/bind/zones/db.root <<EOF

; ---- TLD delegations ----
\$INCLUDE ${DELEG}
EOF

  if [[ ! -f "$DELEG" ]]; then
    cat > "$DELEG" <<'EOF'
; =====================================================================
; TLD delegations for the range root zone.
; Format (one TLD can have several NS lines):
;   <tld>.            172800 IN NS  <nameserver-fqdn>.
;   <nameserver-fqdn>. 172800 IN A   <ip>          ; glue
; Example:
;   com.              172800 IN NS  ns1.nic.com.
;   ns1.nic.com.      172800 IN A   10.0.1.53
; Use add-tld.sh to add/remove entries and bump the serial automatically.
; =====================================================================
EOF
    log "Created empty delegations file $DELEG"
  else
    log "Kept existing delegations in $DELEG"
  fi
  chown root:bind /etc/bind/zones/*; chmod 644 /etc/bind/zones/*

  named-checkzone . /etc/bind/zones/db.root || die "Root zone failed validation."
fi

# ---- Validate & start -------------------------------------------------------------
named-checkconf /etc/bind/named.conf || die "named-checkconf failed — config restored? see $BACKUP"

# Firewall
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 53/udp >/dev/null; ufw allow 53/tcp >/dev/null
  log "Opened 53/udp and 53/tcp in ufw"
fi

systemctl enable named >/dev/null 2>&1 || true
systemctl restart named
sleep 2
systemctl is-active --quiet named || { journalctl -u named --no-pager -n 30; die "named failed to start"; }

# Secondary: ask for a transfer right away
[[ "$ROLE" == "secondary" ]] && { rndc retransfer . 2>/dev/null || true; sleep 2; }

# ---- Self-test ---------------------------------------------------------------------
MYIP=$([[ $ROLE == primary ]] && echo "$ROOT1_IP" || echo "$ROOT2_IP")
log "Self-test against $MYIP:"
echo "  SOA: $(dig +short @"$MYIP" . SOA)"
echo "  NS : $(dig +short @"$MYIP" . NS | tr '\n' ' ')"
if dig @"$MYIP" . SOA +norec | grep -q 'flags:.* aa'; then
  log "Answering authoritatively for \".\" (aa flag set). Done."
else
  warn "No authoritative answer yet. Secondary? Make sure the primary is up, then: rndc retransfer ."
fi

cat <<EOF

Root ${ROLE} ready.
  Zone file (primary): /etc/bind/zones/db.root
  Delegations:         /etc/bind/zones/root.delegations
  Logs:                /var/log/named/named.log, query.log
  Reload after edits:  sudo rndc reload .   (bump serial first, or use add-tld.sh)
EOF
