#!/usr/bin/env bash
# =============================================================================
# add-tld.sh  —  Manage TLD delegations in the range root zone.
# Run on the ROOT PRIMARY only. Bumps the serial, validates, reloads, and the
# secondary picks up the change via NOTIFY.
#
#   sudo ./add-tld.sh add    <tld> <ns-fqdn> <ns-ip>   # add delegation + glue
#   sudo ./add-tld.sh remove <tld>                     # remove a TLD entirely
#   sudo ./add-tld.sh list                             # show delegations
#   sudo ./add-tld.sh bump                             # just bump serial + reload
#
# Examples:
#   sudo ./add-tld.sh add com   ns1.nic.com   10.0.1.53
#   sudo ./add-tld.sh add com   ns2.nic.com   10.0.1.54     # 2nd NS for .com
#   sudo ./add-tld.sh add corp  dc01.corp     10.20.0.10    # fake internal TLD
# =============================================================================
set -euo pipefail

ZONE=/etc/bind/zones/db.root
DELEG=/etc/bind/zones/root.delegations
TTL=172800

die() { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }
log() { echo -e "\e[1;32m[+]\e[0m $*"; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
[[ -f $ZONE && -f $DELEG ]] || die "Root zone not found — is this the root PRIMARY (run setup-root-dns.sh first)?"

fqdn() { local n="${1%.}"; echo "${n,,}."; }

bump_serial() {
  local cur today new
  cur=$(awk '/; serial/{print $1; exit}' "$ZONE")
  today=$(date +%Y%m%d)
  if [[ "${cur:0:8}" == "$today" ]]; then new=$((cur + 1)); else new="${today}01"; fi
  # Never go backwards (e.g. clock skew)
  (( new > cur )) || new=$((cur + 1))
  sed -i "s/^\(\s*\)${cur}\(\s*; serial\)/\1${new}\2/" "$ZONE"
  log "Serial $cur -> $new"
}

apply() {
  bump_serial
  named-checkzone . "$ZONE" >/dev/null || { named-checkzone . "$ZONE"; die "Zone invalid — fix $DELEG"; }
  rndc reload . >/dev/null && log "Reloaded root zone (secondary will be NOTIFYed)."
}

case "${1:-}" in
  add)
    [[ $# -eq 4 ]] || die "Usage: $0 add <tld> <ns-fqdn> <ns-ip>"
    TLD=$(fqdn "$2"); NS=$(fqdn "$3"); IP="$4"
    [[ "$TLD" == *.*.* ]] && die "'$2' isn't a TLD (has a dot). Delegate second-level domains from the TLD server."
    RTYPE=A; [[ "$IP" == *:* ]] && RTYPE=AAAA
    cp "$DELEG" "$DELEG.bak"
    if grep -qiE "^${TLD//./\\.}\s+[0-9]+\s+IN\s+NS\s+${NS//./\\.}\s*$" "$DELEG"; then
      log "NS $NS already present for $TLD"
    else
      printf '%-30s %s IN NS   %s\n' "$TLD" "$TTL" "$NS" >> "$DELEG"
    fi
    if ! grep -qiE "^${NS//./\\.}\s+[0-9]+\s+IN\s+${RTYPE}\s+${IP//./\\.}\s*$" "$DELEG"; then
      printf '%-30s %s IN %-4s %s\n' "$NS" "$TTL" "$RTYPE" "$IP" >> "$DELEG"
    fi
    apply || { mv "$DELEG.bak" "$DELEG"; die "Rolled back."; }
    log "Delegated $TLD -> $NS ($IP)"
    ;;
  remove)
    [[ $# -eq 2 ]] || die "Usage: $0 remove <tld>"
    TLD=$(fqdn "$2")
    cp "$DELEG" "$DELEG.bak"
    # Remove NS lines for the TLD and any glue that lives under it
    sed -i -E "/^${TLD//./\\.}\s+[0-9]+\s+IN\s+NS\s/Id; /^([A-Za-z0-9_-]+\.)+${TLD//./\\.}\s+[0-9]+\s+IN\s+(A|AAAA)\s/Id" "$DELEG"
    apply || { mv "$DELEG.bak" "$DELEG"; die "Rolled back."; }
    log "Removed $TLD (out-of-bailiwick glue for other TLDs, if any, was left in place)."
    ;;
  list)
    grep -vE '^\s*(;|$)' "$DELEG" || echo "(no delegations yet)"
    ;;
  bump)
    apply ;;
  *)
    sed -n '2,18p' "$0"; exit 1 ;;
esac
