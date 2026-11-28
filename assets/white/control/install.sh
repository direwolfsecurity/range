#!/usr/bin/env bash
# install.sh - the range control server (greyctl): one place to change the fake internet,
# by hand (greyctl) or from ForgeRange (the API). Ubuntu 24.04, a VM or a Proxmox container.
#
#   sudo bash install.sh            test mode: shows what it would do, changes nothing
#   sudo bash install.sh --go       does it (or updates after a git pull), then checks
#   sudo bash install.sh --check    API, state folder, and every grey server greyctl can reach
#   sudo bash install.sh --keys     prints the line to add on each grey server for greyctl's SSH key
#
# Safe to run again. Your teams, snapshots and tokens in /var/lib/greyctl are never touched.
#
# License: GPL-3.0, Dire Wolf Security.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_SRC="$HERE/../../../network/registry"
OPT="/opt/greyctl"
ETC="/etc/greyctl"
UNIT="/etc/systemd/system/greyctl-api.service"
BACKUP_DIR="/var/backups/direwolf-greyctl/$(date +%Y%m%d-%H%M%S)"

GO=0; CHECK=0; KEYS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --go)    GO=1 ;;
        --check) CHECK=1 ;;
        --keys)  KEYS=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
    esac
    shift
done

say()  { printf '\n== %s\n' "$*"; }
warn() { printf '   WARNING: %s\n' "$*"; }
die()  { printf '   ERROR: %s\n' "$*"; exit 1; }
run()  { if (( GO )); then printf '   + %s\n' "$*"; "$@"; else printf '   would run: %s\n' "$*"; fi; }

# Copy a file into place (backs up a changed one). $1 source, $2 destination, $3 mode, $4 owner:group
put() {
    local src="$1" dest="$2" mode="$3" owner="${4:-root:root}"
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then printf '   unchanged: %s\n' "$dest"; return; fi
    if (( GO )); then
        if [[ -f "$dest" ]]; then mkdir -p "$BACKUP_DIR$(dirname "$dest")"; cp -p "$dest" "$BACKUP_DIR$dest"; fi
        install -D -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$src" "$dest"
        printf '   installed: %s\n' "$dest"
    else
        printf '   would install: %s\n' "$dest"
    fi
}

[[ -f "$HERE/control.conf" ]] || die "Run this from the control folder (assets/white/control)."
# shellcheck source=control.conf
source "$HERE/control.conf"

# ---- --keys: what to add on each grey server ----
if (( KEYS )); then
    pub="$STATE_DIR/.ssh/id_ed25519.pub"
    [[ -f "$pub" ]] || die "No key yet. Run: sudo bash install.sh --go"
    key="$(cat "$pub")"
    say "On root-a (the registrar), once:  cd .../assets/grey/root-dns/registrar && sudo bash install-remote.sh"
    say "Then add ONE line to /root/.ssh/authorized_keys on each grey server:"
    echo
    echo "root-a (172.16.11.11):"
    echo "  echo 'from=\"$CONTROL_IP\",restrict,command=\"/usr/local/sbin/registrar-remote\" $key' | sudo tee -a /root/.ssh/authorized_keys"
    echo
    echo "geoip.lab (172.16.11.50):"
    echo "  echo 'from=\"$CONTROL_IP\",restrict,command=\"/usr/local/sbin/geoip-apply\" $key' | sudo tee -a /root/.ssh/authorized_keys"
    echo
    echo "The key can run only that one command, and only from $CONTROL_IP. Then set REGISTRAR and GEOIP"
    echo "in control.conf, run --go again, and check with: greyctl status"
    exit 0
fi

check() {
    local fails=0
    say "Service"
    if systemctl is-active -q greyctl-api.service; then echo "   ok    greyctl-api is running"; else echo "   FAIL  greyctl-api is not running"; fails=$((fails + 1)); fi
    local scheme="http"
    [[ -f "$TLS_CERT" && -f "$TLS_KEY" ]] && scheme="https"
    local code
    code="$(curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 "$scheme://127.0.0.1:$API_PORT/v1/info" || true)"
    if [[ "$code" == "401" ]]; then echo "   ok    $scheme://$CONTROL_IP:$API_PORT/ answers (and wants a token)"; else echo "   FAIL  the API answered '$code', expected 401 without a token"; fails=$((fails + 1)); fi
    [[ "$scheme" == "http" ]] && warn "No certificate yet: the API is plain HTTP (README step 4)."
    say "greyctl status"
    sudo -u greyctl GREYCTL_CONF="$ETC/control.conf" python3 "$OPT/greyctl.py" status || fails=$((fails + 1))
    say "Result"
    if (( fails )); then echo "   $fails problem(s)"; return 1; fi
    echo "   all good"
}
if (( CHECK )); then check; exit $?; fi

say "Range control server (greyctl) at $CONTROL_IP"
(( GO )) || echo "   TEST MODE: nothing will change. Add --go to do it."
if (( GO )) && [[ $EUID -ne 0 ]]; then die "Run with sudo."; fi
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || warn "Written for Ubuntu 24.04. This is ${PRETTY_NAME:-unknown}."
[[ -f "$REGISTRY_SRC/registry.csv" && -f "$REGISTRY_SRC/registry.py" ]] \
    || die "Can't find network/registry. Clone both folders:  git sparse-checkout set assets/white/control network/registry"

tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT

say "1. Check the registry"
python3 "$REGISTRY_SRC/registry.py" "$REGISTRY_SRC/registry.csv" || die "Fix the registry first."

say "2. Packages"
pkgs=(python3 openssh-client curl sudo)
[[ "$FIREWALL" == "yes" ]] && pkgs+=(ufw)
missing=()
for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if (( ${#missing[@]} )); then
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
else
    echo "   all installed"
fi

say "3. The greyctl user and its folders"
if id greyctl >/dev/null 2>&1; then echo "   user greyctl exists"; else run useradd --system --home-dir "$STATE_DIR" --shell /usr/sbin/nologin greyctl; fi
run install -d -m 700 -o greyctl -g greyctl "$STATE_DIR" "$STATE_DIR/snapshots" "$STATE_DIR/.ssh"
run install -d -m 755 "$OPT" "$OPT/registry"
run install -d -m 750 -o root -g greyctl "$ETC" "$ETC/tls"

say "4. Program and settings"
put "$HERE/greyctl.py" "$OPT/greyctl.py" 755
put "$HERE/greyctl-api.py" "$OPT/greyctl-api.py" 755
put "$REGISTRY_SRC/registry.csv" "$OPT/registry/registry.csv" 644
put "$REGISTRY_SRC/registry.py" "$OPT/registry/registry.py" 644
put "$HERE/control.conf" "$ETC/control.conf" 640 root:greyctl
cat > "$tmpd/greyctl" <<WRAP
#!/bin/sh
# greyctl: runs as the greyctl user, which owns the state, snapshots and SSH key.
export GREYCTL_CONF="$ETC/control.conf"
if [ "\$(id -un)" = greyctl ]; then exec python3 "$OPT/greyctl.py" "\$@"; fi
exec sudo -u greyctl GREYCTL_CONF="$ETC/control.conf" GREYCTL_CLIENT="cli:\${SUDO_USER:-\$(id -un)}" python3 "$OPT/greyctl.py" "\$@"
WRAP
put "$tmpd/greyctl" /usr/local/bin/greyctl 755

say "5. SSH key for reaching the grey servers"
if [[ -f "$SSH_KEY" ]]; then
    echo "   key exists: $SSH_KEY"
else
    run sudo -u greyctl ssh-keygen -q -t ed25519 -N "" -C "greyctl@$CONTROL_IP" -f "$SSH_KEY"
fi
echo "   Next: sudo bash install.sh --keys   (prints the line for each grey server)"

say "6. API service"
cat > "$tmpd/unit" <<UNIT
[Unit]
Description=Range control API (greyctl)
After=network-online.target
Wants=network-online.target

[Service]
User=greyctl
Group=greyctl
Environment=GREYCTL_CONF=$ETC/control.conf
ExecStart=/usr/bin/python3 $OPT/greyctl-api.py
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$STATE_DIR
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT
put "$tmpd/unit" "$UNIT" 644
if (( GO )); then
    systemctl daemon-reload
    systemctl enable -q greyctl-api.service
    systemctl restart greyctl-api.service
    echo "   + greyctl-api restarted"
else
    echo "   would enable and (re)start greyctl-api.service"
fi
[[ -f "$TLS_CERT" && -f "$TLS_KEY" ]] || warn "No certificate in $ETC/tls yet: the API starts on plain HTTP (README step 4)."

say "7. Firewall"
if [[ "$FIREWALL" == "yes" ]]; then
    for src in $API_ALLOW; do
        run ufw allow from "$src" to any port 22 proto tcp
        run ufw allow from "$src" to any port "$API_PORT" proto tcp
    done
    run ufw default deny incoming
    run ufw --force enable
else
    echo "   FIREWALL=no: skipped"
fi

if (( GO )); then
    sleep 1
    check || true
    say "Next steps"
    echo "   1. sudo bash install.sh --keys, and add the lines it prints on each grey server"
    echo "   2. greyctl status            (every server should say ok)"
    echo "   3. greyctl snapshot save zero --note \"clean core\"    (once, when the core is clean)"
    echo "   4. greyctl token add forgerange exercise              (for ForgeRange; store it outside git)"
fi
