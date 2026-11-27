#!/usr/bin/env bash
# install-root-linux.sh - trust the range root certificate on Kali, Ubuntu or Debian.
#
# Usage:
#   sudo bash install-root-linux.sh --fingerprint <sha256>      download from http://ca.lab and check it
#   sudo bash install-root-linux.sh --file root_ca.crt --fingerprint <sha256>
#   sudo bash install-root-linux.sh --remove                    stop trusting it
#
# Other options: --url http://ca.lab   --yes (no question when you give no fingerprint)
#
# It adds the root to the system store (curl, wget, apt, Python, Chromium on most setups),
# to Firefox (a policy file) and to each user's Chrome/Chromium store if certutil is installed.
#
# License: GPL-3.0, Dire Wolf Security.

set -euo pipefail

URL="http://ca.lab"
FILE=""
WANT_FP=""
REMOVE=0
YES=0
NAME="direwolf-range-root"
SYSTEM_CRT="/usr/local/share/ca-certificates/$NAME.crt"
NICK="Dire Wolf Range Root CA"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)         URL="${2:-}"; shift ;;
        --file)        FILE="${2:-}"; shift ;;
        --fingerprint) WANT_FP="${2:-}"; shift ;;
        --remove)      REMOVE=1 ;;
        --yes)         YES=1 ;;
        -h|--help)     sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
    esac
    shift
done

say() { printf '\n== %s\n' "$*"; }
die() { printf '   ERROR: %s\n' "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo."
command -v openssl >/dev/null || die "openssl is missing: apt install openssl"

# Firefox reads policies from these places on Linux. We write only where Firefox is installed.
firefox_policy_files() {
    [[ -d /usr/lib/firefox-esr ]] && echo /usr/lib/firefox-esr/distribution/policies.json
    [[ -d /usr/lib/firefox ]] && echo /usr/lib/firefox/distribution/policies.json
    if [[ -d /usr/lib/firefox-esr || -d /usr/lib/firefox || -d /snap/firefox ]] || command -v firefox >/dev/null; then
        echo /etc/firefox/policies/policies.json
    fi
    return 0
}

# Add or remove our root in a Firefox policies.json, keeping any other policies in it.
# $1 = file, $2 = add|remove
firefox_policy() {
    python3 - "$1" "$2" "$SYSTEM_CRT" <<'PY'
import json, os, sys
path, action, crt = sys.argv[1:]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
certs = data.setdefault("policies", {}).setdefault("Certificates", {})
install = certs.setdefault("Install", [])
if action == "add" and crt not in install:
    install.append(crt)
if action == "remove" and crt in install:
    install.remove(crt)
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

# Chrome and Chromium on Linux also use each user's own NSS store (~/.pki/nssdb).
nss_dbs() {
    local h
    for h in /root /home/*; do
        [[ -d "$h/.pki/nssdb" ]] && echo "$h/.pki/nssdb"
    done
    return 0
}

if (( REMOVE )); then
    say "Removing the range root"
    rm -f "$SYSTEM_CRT"
    update-ca-certificates --fresh >/dev/null 2>&1 || true
    echo "   system store: removed"
    if command -v python3 >/dev/null; then
        while read -r p; do
            [[ -f "$p" ]] && firefox_policy "$p" remove && echo "   Firefox policy: removed from $p"
        done < <(firefox_policy_files)
    fi
    if command -v certutil >/dev/null; then
        while read -r db; do
            certutil -d "sql:$db" -D -n "$NICK" 2>/dev/null && echo "   removed from $db"
        done < <(nss_dbs)
    fi
    echo "   Done. Restart browsers."
    exit 0
fi

say "1. Get the root certificate"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if [[ -n "$FILE" ]]; then
    cp "$FILE" "$tmp"
    echo "   from file $FILE"
else
    curl -fsS --max-time 15 "$URL/root_ca.crt" -o "$tmp" || die "Could not download $URL/root_ca.crt. Does ca.lab resolve? (dig ca.lab)"
    echo "   downloaded $URL/root_ca.crt"
fi
openssl x509 -in "$tmp" -noout 2>/dev/null || die "That is not a certificate."
openssl x509 -in "$tmp" -noout -text | grep -q "CA:TRUE" || die "That certificate is not a CA certificate. Not installing it."

GOT_FP="$(openssl x509 -in "$tmp" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')"
echo "   name:        $(openssl x509 -in "$tmp" -noout -subject | sed 's/^subject= *//')"
echo "   fingerprint: $GOT_FP"

say "2. Check the fingerprint"
if [[ -n "$WANT_FP" ]]; then
    WANT_FP="$(echo "$WANT_FP" | tr -d ': ' | tr 'A-F' 'a-f')"
    [[ "$GOT_FP" == "$WANT_FP" ]] || die "Fingerprint does NOT match. Someone may have swapped the certificate. Not installing it."
    echo "   matches the one you gave"
elif (( YES )); then
    echo "   not checked (--yes)"
else
    printf '   Does it match the fingerprint your teacher posted? [y/N] '
    read -r answer < /dev/tty || answer=""
    [[ "$answer" == "y" || "$answer" == "Y" ]] || die "Not installing it."
fi

say "3. System store"
install -D -m 644 "$tmp" "$SYSTEM_CRT"
update-ca-certificates >/dev/null 2>&1 || die "update-ca-certificates failed."
echo "   added: $SYSTEM_CRT (curl, wget, apt, git and Python's system certificates now trust it)"

say "4. Firefox"
found=0
if command -v python3 >/dev/null; then
    while read -r p; do
        firefox_policy "$p" add
        echo "   policy: $p"
        found=1
    done < <(firefox_policy_files)
fi
(( found )) || echo "   Firefox not found (or python3 missing). Skipped."
(( found )) && echo "   Restart Firefox. Check it at about:policies."

say "5. Chrome / Chromium (per user)"
if command -v certutil >/dev/null; then
    n=0
    while read -r db; do
        certutil -d "sql:$db" -D -n "$NICK" 2>/dev/null || true
        certutil -d "sql:$db" -A -t "C,," -n "$NICK" -i "$SYSTEM_CRT"
        chown -R --reference="$db/.." "$db" 2>/dev/null || true
        echo "   added to $db"
        n=$((n + 1))
    done < <(nss_dbs)
    (( n )) || echo "   No browser profiles yet (open Chromium once, then run this again)."
else
    echo "   certutil not installed. If Chromium does not trust range sites: apt install libnss3-tools, run this again."
fi

say "Done"
echo "   Test it: curl -I https://ca.lab/health"
echo "   Python with pip packages (requests, certifi) may need: export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt"
