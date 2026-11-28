#!/usr/bin/env bash
# install-remote.sh - add the range control server's hook to a registrar that is already built.
# Run on the root primary (root-a), from this folder:  sudo bash install-remote.sh
#
# It copies the newer cli.php (with export and import) to /opt/registrar and installs
# /usr/local/sbin/registrar-remote. New builds get both from setup-registrar.sh.
# Then add the control server's key (the control server's install.sh prints that line).
#
# License: GPL-3.0, Dire Wolf Security.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }
[[ -d /opt/registrar ]] || { echo "No /opt/registrar here. Run this on the root primary, after setup-registrar.sh."; exit 1; }

install -m 644 -o root -g root "$HERE/app/cli.php" /opt/registrar/cli.php
install -m 644 -o root -g root "$HERE/app/lib.php" /opt/registrar/lib.php
install -m 755 -o root -g root "$HERE/registrar-remote" /usr/local/sbin/registrar-remote
echo "Installed /opt/registrar/cli.php and /usr/local/sbin/registrar-remote"
echo "Check:  sudo registrar-remote export | head"
