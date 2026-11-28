#!/usr/bin/env bash
# install.sh - Dire Wolf range reverse DNS server (a.in-addr-servers.arpa): answers "who is this
# address?" (PTR lookups) for every network in the range registry, and runs the forward zones of
# the made-up ISPs, so 192.168.103.5 -> 192-168-103-5.austin.bluestem.lab -> 192.168.103.5.
#
# Usage (run from this folder, on Ubuntu 24.04, a VM or a Proxmox container):
#   sudo bash install.sh                 test mode: shows what it would do, changes nothing
#   sudo bash install.sh --go            does it (or rebuilds after a registry change), then checks
#   sudo bash install.sh --check         the service, the zones, a lookup for every network
#   sudo bash install.sh --registrar     prints the commands to run on the root primary (README step 3)
#
# Other options: --ip ADDRESS (this server's address, if it guesses wrong)
#                --quiet (with --go: skip the long check at the end; dns-apply uses it)
#
# Safe to run again. Files it replaces are first copied to /var/backups/direwolf-rdns/.
# After you change registry.csv or names.conf: git pull, then sudo bash install.sh --go
# Exercise teams (the overlay, OVERLAY_FILE in dns.conf) are laid over registry.csv when it exists.
# The range control server (assets/white/control) sends it and runs dns-apply, which re-runs --go.
#
# License: GPL-3.0, Dire Wolf Security.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HERE/dns.conf"
NAMES_FILE="$HERE/names.conf"
BUILDER="$HERE/tools/build-zones.py"

ZONE_DIR="/etc/bind/zones/rdns"
ZONES_CONF="/etc/bind/named.conf.rdns"
STATE_DIR="/var/lib/direwolf-rdns"
BACKUP_DIR="/var/backups/direwolf-rdns/$(date +%Y%m%d-%H%M%S)"

GO=0
CHECK=0
REGISTRAR=0
QUIET=0
OPT_IP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --go)        GO=1 ;;
        --check)     CHECK=1 ;;
        --registrar) REGISTRAR=1 ;;
        --quiet)     QUIET=1 ;;
        --ip)        OPT_IP="${2:-}"; shift ;;
        -h|--help)   sed -n '2,19p' "$0"; exit 0 ;;
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
        (( QUIET )) || printf '   unchanged: %s\n' "$dest"
        return
    fi
    CHANGED=1
    if (( GO )); then
        if [[ -f "$dest" ]]; then
            mkdir -p "$BACKUP_DIR$(dirname "$dest")"
            cp -p "$dest" "$BACKUP_DIR$dest"
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

# ---- Settings ----
[[ -f "$SETTINGS" ]]   || die "Missing dns.conf. Run this from the repo folder (assets/grey/reverse-dns)."
[[ -f "$NAMES_FILE" ]] || die "Missing names.conf. Run this from the repo folder (assets/grey/reverse-dns)."
# shellcheck source=dns.conf
source "$SETTINGS"
[[ "$QUERY_LOG" == "yes" || "$QUERY_LOG" == "no" ]] || die "QUERY_LOG must be yes or no (got '$QUERY_LOG')."
read -r -a ISP <<< "${ISP_DOMAINS:-}"

if [[ "$REGISTRY_FILE" == /* ]]; then
    REGISTRY="$REGISTRY_FILE"
else
    REGISTRY="$HERE/$REGISTRY_FILE"
fi
if [[ ! -f "$REGISTRY" || ! -f "$(dirname "$REGISTRY")/registry.py" ]]; then
    die "Can't find the registry at $REGISTRY. Clone both folders:  git sparse-checkout set assets/grey/reverse-dns network/registry"
fi
REGISTRY="$(cd "$(dirname "$REGISTRY")" && pwd)/$(basename "$REGISTRY")"
OVERLAY="${OVERLAY_FILE:-}"

# This server's address: --ip, else the one saved by the last --go, else a guess.
SERVER_IP="$OPT_IP"
if [[ -z "$SERVER_IP" && -f "$STATE_DIR/server-ip" ]]; then
    SERVER_IP="$(cat "$STATE_DIR/server-ip")"
fi
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}' | head -n1)"
fi
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[[ -n "$SERVER_IP" ]] || die "Can't tell this server's address. Use --ip ADDRESS."

# ---- --registrar: the commands for the root primary ----
if (( REGISTRAR )); then
    say "Run these on the root primary (root-a). They hand arpa and the ISP domains to this server."
    echo "   cd ~/range/assets/grey/root-dns"
    echo "   sudo bash add-tld.sh add arpa $NS_NAME $SERVER_IP"
    for d in "${ISP[@]}"; do
        echo "   sudo -u www-data php /opt/registrar/cli.php add-ns $d ns1.$d $SERVER_IP"
    done
    echo "   sudo registrar-apply"
    echo
    echo "   If a domain says \"already registered\", see who has it (cli.php list). If it is an old test,"
    echo "   delete it first (cli.php del DOMAIN), or take it out of ISP_DOMAINS in dns.conf."
    echo "   Then on the resolver (172.16.11.10) run set-root-hints-ubuntu.sh again (README step 4),"
    echo "   so it asks the range for private reverse names instead of answering \"no such name\" itself."
    exit 0
fi

# ---- --check ----
check() {
    local fails=0 z addr want got
    say "Service"
    if systemctl is-active -q named.service 2>/dev/null || pgrep -x named >/dev/null; then
        echo "   ok    named is running"
    else
        echo "   FAIL  named is not running"; fails=$((fails + 1))
    fi
    say "Zones (asked directly, with the aa flag = this server is the boss of the zone)"
    while read -r z _; do
        if dig +norec @"$SERVER_IP" "$z" SOA | grep -q 'flags:.* aa'; then
            echo "   ok    $z  serial $(dig +short @"$SERVER_IP" "$z" SOA | awk '{print $3}')"
        else
            echo "   FAIL  $z gives no authoritative answer"; fails=$((fails + 1))
        fi
    done < "$STATE_DIR/zones.txt"
    say "One address in every network: PTR, then the name back to an address"
    while read -r addr; do
        got="$(dig +short @"$SERVER_IP" -x "$addr" | head -n1)"
        if [[ -z "$got" ]]; then
            echo "   FAIL  $addr has no PTR"; fails=$((fails + 1)); continue
        fi
        want=""
        for z in "${ISP[@]}"; do
            [[ "$got" == *".$z." ]] && want="$(dig +short @"$SERVER_IP" "$got" A | head -n1)"
        done
        if [[ -n "$want" && "$want" != "$addr" ]]; then
            echo "   FAIL  $addr -> $got -> $want (should come back to $addr)"; fails=$((fails + 1))
        elif [[ -n "$want" ]]; then
            echo "   ok    $addr -> $got -> $want"
        else
            echo "   ok    $addr -> $got"
        fi
    done < <(python3 - "$REGISTRY" "$OVERLAY" <<'PY'
import ipaddress, os, sys
sys.path.insert(0, os.path.dirname(sys.argv[1]))
import registry
overlay = sys.argv[2] if sys.argv[2] and os.path.exists(sys.argv[2]) and os.path.getsize(sys.argv[2]) else None
rows, errors = registry.read_with_overlay(sys.argv[1], overlay)
for row in rows:
    net = row.network
    print(net.network_address if net.prefixlen == 32 else net.network_address + 5)
PY
)
    if [[ -n "${RESOLVER_IP:-}" ]]; then
        say "Through the range resolver ($RESOLVER_IP): the way every machine on the range asks"
        got="$(dig +short @"$RESOLVER_IP" -x "$SERVER_IP" 2>/dev/null | head -n1 || true)"
        if [[ "$got" == "$NS_NAME." ]]; then
            echo "   ok    $SERVER_IP -> $got"
        else
            echo "   WAIT  the resolver says '${got:-nothing}' for $SERVER_IP."
            echo "         Did root-a get the commands from --registrar, and did the resolver re-run step 4?"
        fi
    fi
    echo
    if (( fails )); then echo "   $fails check(s) failed."; return 1; fi
    echo "   All checks passed."
}

if (( CHECK )); then
    [[ -f "$STATE_DIR/zones.txt" ]] || die "Not built yet. Run: sudo bash install.sh --go"
    check
    exit $?
fi

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

say "Reverse DNS server: $NS_NAME at $SERVER_IP (use --ip if that address is wrong)"
echo "   Registry: $REGISTRY"
if [[ -n "$OVERLAY" && -s "$OVERLAY" ]]; then echo "   Exercise overlay: $OVERLAY"; else echo "   Exercise overlay: none"; fi
echo "   ISP domains with forward zones here: ${ISP[*]:-none}"
(( GO )) || echo "   TEST MODE: nothing is changed. Add --go to do it."

say "1. Packages"
missing=()
for p in bind9 bind9-utils bind9-dnsutils python3; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
done
if (( ${#missing[@]} )); then
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
else
    echo "   all installed"
fi

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

say "2. BIND settings: authoritative only, no recursion"
cat > "$tmpd/named.conf" <<'EOF'
// Made by the Dire Wolf reverse-dns install.sh. Edit dns.conf and re-run instead.
// named.conf.default-zones is left out on purpose: this server answers only for its own zones.
include "/etc/bind/named.conf.options";
include "/etc/bind/named.conf.logging";
include "/etc/bind/named.conf.rdns";
EOF
put "$tmpd/named.conf" /etc/bind/named.conf 644 root:bind
cat > "$tmpd/options" <<EOF
// Made by the Dire Wolf reverse-dns install.sh. Edit dns.conf and re-run instead.
options {
    directory "/var/cache/bind";
    recursion no;                // authoritative only, like the real in-addr.arpa servers
    allow-query { any; };
    allow-transfer { none; };
    // Only the real address and localhost, so it never fights systemd-resolved over 127.0.0.53.
    listen-on { $SERVER_IP; 127.0.0.1; };
    listen-on-v6 { none; };
    dnssec-validation no;
    minimal-responses no-auth-recursive;
    version "range-rdns";
};
EOF
put "$tmpd/options" /etc/bind/named.conf.options 644 root:bind
queries="null;"
[[ "$QUERY_LOG" == "yes" ]] && queries="query_log;"
cat > "$tmpd/logging" <<EOF
// Made by the Dire Wolf reverse-dns install.sh.
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
    category default { general_log; };
    category queries { $queries };
    category lame-servers { null; };
};
EOF
put "$tmpd/logging" /etc/bind/named.conf.logging 644 root:bind
if (( GO )); then
    install -d -m 755 -o bind -g bind /var/log/named
    install -d -m 2775 -o root -g bind "$ZONE_DIR"
    install -d -m 700 "$STATE_DIR"
fi
CONF_CHANGED=$CHANGED
CHANGED=0

say "3. Zones from the registry"
args=(--registry "$REGISTRY" --names "$NAMES_FILE" --server-ip "$SERVER_IP" --ns-name "$NS_NAME"
      --hostmaster "$HOSTMASTER" --zone-dir "$ZONE_DIR" --out "$tmpd/zones")
[[ -n "$OVERLAY" ]] && args+=(--overlay "$OVERLAY")
[[ -f "$STATE_DIR/state.json" ]] && args+=(--state "$STATE_DIR/state.json")
(( ${#ISP[@]} )) && args+=(--isp "${ISP[@]}")
if ! command -v python3 >/dev/null; then
    # Test mode on a fresh container: python3 comes with step 1, which only runs with --go.
    say "Test mode: python3 is not installed yet, so the zones can't be built for a preview."
    echo "   Run again with --go: it installs the packages first."
    exit 0
fi
python3 "$BUILDER" "${args[@]}" | sed 's/^/   /' || die "The zones could not be built (see above). Nothing was changed."
# Check every zone before any of them goes live.
# named-checkzone comes with bind9-utils (step 1). In test mode on a fresh container it may not be there yet.
if command -v named-checkzone >/dev/null; then
    while read -r z f; do
        named-checkzone -q "$z" "$tmpd/zones/$f" || { named-checkzone "$z" "$tmpd/zones/$f" || true; die "Zone $z failed its check. Nothing was changed."; }
    done < "$tmpd/zones/zones.txt"
    echo "   every zone checks out"
elif (( GO )); then
    die "named-checkzone is missing even after step 1. Install it: apt install -y bind9-utils, then run --go again."
else
    echo "   (zones not checked: BIND is not installed yet. --go installs it first, then checks them.)"
fi
while read -r z f; do
    put "$tmpd/zones/$f" "$ZONE_DIR/$f" 644 root:bind
done < "$tmpd/zones/zones.txt"
put "$tmpd/zones/named.conf.rdns" "$ZONES_CONF" 644 root:bind
# Zones that are not built any more (an ISP domain taken out of dns.conf)
for f in "$ZONE_DIR"/db.*; do
    [[ -e "$f" ]] || continue
    grep -q " ${f##*/}\$" "$tmpd/zones/zones.txt" || remove "$f"
done
ZONES_CHANGED=$CHANGED

say "4. dns-apply (what the range control server runs over SSH)"
sed -e "s|@HERE@|$HERE|g" -e "s|@OVERLAY@|${OVERLAY:-/etc/direwolf-range/overlay.csv}|g" \
    "$HERE/tools/dns-apply" > "$tmpd/dns-apply"
put "$tmpd/dns-apply" /usr/local/sbin/dns-apply 755

if (( ! GO )); then
    say "Test mode: nothing was changed. Run again with --go."
    exit 0
fi

say "5. Start or reload BIND"
named-checkconf /etc/bind/named.conf || die "BIND config check failed (see above). The old files are in $BACKUP_DIR."
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 53/udp >/dev/null; ufw allow 53/tcp >/dev/null
    echo "   opened 53/udp and 53/tcp in ufw"
fi
systemctl enable named.service >/dev/null 2>&1 || true
if (( CONF_CHANGED )) || ! systemctl is-active -q named.service; then
    run systemctl restart named.service
elif (( ZONES_CHANGED )); then
    run rndc reload
else
    echo "   nothing changed, BIND left as it is"
fi
cp "$tmpd/zones/state.json" "$STATE_DIR/state.json"
cp "$tmpd/zones/zones.txt" "$STATE_DIR/zones.txt"
echo "$SERVER_IP" > "$STATE_DIR/server-ip"
sleep 1

if (( QUIET )); then
    exit 0
fi
check || true
cat <<EOF

   Next, if not done yet:
     1. On root-a, run what this prints:  sudo bash install.sh --registrar
     2. On the resolver, run set-root-hints-ubuntu.sh again (root-dns README step 4).
     3. Try it from any range machine:  dig -x 192.168.103.5   or   nslookup 192.168.103.5
EOF
