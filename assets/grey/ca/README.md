# Range certificate authority: a pretend Let's Encrypt

This builds the range's own certificate authority (CA) with [step-ca](https://smallstep.com/docs/step-ca/) on Ubuntu 24.04. No Docker.
It speaks ACME, the same protocol Let's Encrypt uses, so `certbot` and other ACME clients get certificates from it
the way they would on the internet. Trust its root certificate once on a machine, and HTTPS works on every range site that uses it.

Without it, nothing on the range has working HTTPS: no internet CA can see or vouch for range names like `mqtt.lab`.

License: CC BY-SA 4.0 for this guide, GPL-3.0 for the scripts. Dire Wolf Security.

## Get the files

On the CA server, clone only this folder:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/direwolfsecurity/range.git
cd range
git sparse-checkout set assets/grey/ca
cd assets/grey/ca
```

## What you need

| Item | Notes |
|---|---|
| Ubuntu 24.04 | A VM or a Proxmox container (see below). 1 CPU, 1 GB RAM, 8 GB disk is plenty. |
| Address | **172.16.11.20** on GREY (VLAN 110). Not final until `network\registry.csv` exists. |
| DNS name | **`ca.lab`**, registered on the grey registrar (step 3). |
| Range DNS working | The CA checks each ACME request by looking the name up on the range resolver (`RESOLVER` in `ca.conf`, 172.16.11.10). |
| Package access while installing | Smallstep's apt repository needs internet. For a closed range, download `step-cli_*.deb` and `step-ca_*.deb` from the Smallstep releases on GitHub beforehand, put them in a folder and set `STEP_PACKAGES` in `ca.conf` to that folder. |
| The right time | Certificates have start and end dates. A machine with the wrong clock rejects good certificates. Point the CA and clients at the range NTP server. |

## Proxmox containers (LXC) instead of VMs

A CA is light work, so an unprivileged container from the Ubuntu 24.04 template fits well.

- **Address and gateway:** set them in Proxmox (container > Network > eth0: `172.16.11.20/24`, gateway `172.16.11.254`). Do not use netplan.
- **DNS server:** set it in Proxmox (container > DNS). Use a working server while installing, then `172.16.11.10`.
  The CA does not depend on it for ACME checks: the service always asks `RESOLVER` from `ca.conf`.
- **The template is small.** As root, first: `apt update && apt install -y git sudo`.
- **Ports 80 and 443:** the CA runs as the `step` user, not root. Its service is allowed to use port 443 (`CAP_NET_BIND_SERVICE`), which works in unprivileged containers.
- **Back it up.** Turn on Proxmox backups (or take a snapshot) for this container. If the CA is lost, every client must trust a new root.
- Start it on boot (Options > Start at boot).

## 1. Install

```bash
sudo bash install.sh          # test mode: lists what it will do, changes nothing
sudo bash install.sh --go     # does it, then prints a status check
```

The first `--go`:

- installs `step-ca`, `step-cli` and nginx,
- makes a new root certificate (valid 10 years) and an intermediate certificate, which signs everything day to day,
- turns on ACME at `https://ca.lab/acme/acme/directory`,
- sets certificate lifetimes: 90 days by default, like Let's Encrypt, 365 days at most (`ca.conf`),
- starts the CA on port 443 and a plain-HTTP download page on port 80,
- prints the **root fingerprint**. Write it on the board, a poster or the projector. Students check it before they trust the root.

It also prints an **admin provisioner password** once. You only need it to issue certificates with `step ca certificate`.
ACME and `--issue` (step 5) work without it.

The script is safe to run again. It never makes a second CA over the first one.
To change a setting, edit `ca.conf` and run `--go` again.

## 2. What is secret, and where it is

| File (on the CA server only) | What it is |
|---|---|
| `/etc/step-ca/secrets/root_ca_key` | The root's private key. Whoever has it can make any range site look real. |
| `/etc/step-ca/secrets/intermediate_ca_key` | The key that signs every certificate. |
| `/etc/step-ca/secrets/password.txt` | Unlocks both keys, so the CA can start by itself after a reboot. |

All three are readable only by root and the `step` user. They are made on the server and are never in this repo.
Never copy them to another machine, a share or a chat.

Optional, for a defend lab: take the root key offline. Copy `root_ca_key` to a USB stick kept in a drawer, then delete it from the server.
The CA keeps working (it only uses the intermediate). You need the root key again only to make a new intermediate.

## 3. Give it its DNS name

On the **primary root DNS server** (`../root-dns/`, registrar installed):

```bash
sudo -u www-data php /opt/registrar/cli.php add-a ca.lab 172.16.11.20
sudo registrar-apply
```

Check from any range machine: `dig ca.lab` answers `172.16.11.20`, and `http://ca.lab/` shows the download page.

## 4. Trust the root on clients

Every client needs the root certificate once. The download page `http://ca.lab/` has it in every format, plus install scripts.
That page is plain HTTP on purpose: a machine can't check HTTPS before it trusts the root. That is also how real bootstrapping works,
and why the **fingerprint check** matters. Anyone who can tamper with traffic on GREY could hand out their own root instead (a good lab).
The scripts refuse a root whose fingerprint does not match.

| Client | How |
|---|---|
| **Kali, Ubuntu, Debian** | `curl -O http://ca.lab/install-root-linux.sh`, read it, then `sudo bash install-root-linux.sh --fingerprint <fingerprint>`. It adds the root to the system store (curl, wget, apt, git, Python's system certificates), to Firefox through a policy file, and to each user's Chrome/Chromium store when `certutil` (`libnss3-tools`) is installed. `--remove` undoes it. For a Kali image, run it once before you save the image. |
| **Windows 11** | PowerShell as Administrator: `curl.exe -O http://ca.lab/Install-RangeRoot.ps1`, then `powershell -ExecutionPolicy Bypass -File .\Install-RangeRoot.ps1 -Fingerprint <fingerprint>`. It adds the root to "Trusted Root Certification Authorities" (Local Computer), which Edge and Chrome use, and turns on Firefox's `ImportEnterpriseRoots` policy. `-Remove` undoes it. |
| **Windows domain (pods)** | On the domain controller, a Group Policy: Computer Configuration > Policies > Windows Settings > Security Settings > Public Key Policies > Trusted Root Certification Authorities > Import `root_ca.crt`. Every domain PC gets it at the next policy refresh. |
| **Python with pip packages** | `requests` from pip uses its own list (certifi). Point it at the system store: `export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt`. |
| **ESP32 (Arduino)** | Download `http://ca.lab/root_ca.h` into the sketch folder, `#include "root_ca.h"`, then `client.setCACert(RANGE_ROOT_CA);` on the `WiFiClientSecure`. Set the clock first (`configTime(0, 0, "pool.ntp.org")`, which points at the range NTP server once the connectivity-check names are in). |
| **Raspberry Pi Pico W (arduino-pico core)** | Same `root_ca.h`. `BearSSL::X509List roots(RANGE_ROOT_CA);` then `client.setTrustAnchors(&roots);`. It needs the time too (`NTP.begin("pool.ntp.org")`). |
| **Arduino Nano RP2040 Connect** | Not in practice. Its Wi-Fi chip only trusts certificates loaded with the firmware updater, which fetches them from real internet sites. Keep these tiles on plain ports with a login (see `../mqtt/`). |
| **Android phones** | Settings > Security > Encryption & credentials > Install a certificate > CA certificate, and pick `root_ca.der`. Chrome trusts it. Most apps ignore user-added roots by design. |
| **iPhone / iPad** | Open `http://ca.lab/root_ca.crt` in Safari, install the profile (Settings > General > VPN & Device Management), then turn it on in Settings > General > About > Certificate Trust Settings. |

Test a client: `curl -I https://ca.lab/health` must work with no warning.

The microcontroller lines follow each board's documented TLS calls. They have not been tried on real tiles yet.

## 5. Get certificates

**With ACME (servers that can run certbot).** The server must trust the root first (step 4), its name must point to it in range DNS,
and the CA must be able to reach it on port 80.

```bash
sudo apt install -y certbot
sudo certbot certonly --standalone -d myserver.lab --server https://ca.lab/acme/acme/directory \
    --agree-tos --register-unsafely-without-email
```

Use `--webroot -w /var/www/html` instead of `--standalone` when a web server already uses port 80, or `--nginx` / `--apache` with their plugins.
certbot's timer renews the certificate by itself before its 90 days run out. The connectivity-check server (`../connectivity-check/`) does exactly this.

Wildcard certificates (`*.example.com`) need the DNS-01 check, which this CA is not set up for. Ask for each name instead.

**By hand (devices and servers with no ACME client),** on the CA server:

```bash
sudo bash install.sh --issue mqtt.lab --san 172.16.11.83 --go        # 365 days; --days N for shorter
```

It writes `mqtt.lab.crt` (certificate plus intermediate) and `mqtt.lab.key` to `/root/direwolf-ca-issued/mqtt.lab/`.
Copy them to the server that uses them, then delete them from the CA. For the MQTT broker, they go in `/etc/mosquitto/certs/` as
`server.crt` and `server.key` (see `../mqtt/` step 7). Clients then trust the range root instead of a one-off certificate.
A hand-made certificate does not renew itself. Write its end date down.

## Check it

```bash
sudo bash install.sh --check
sudo bash install.sh --root        # prints the root certificate
```

`--check` shows both services, the ports, the root's name, end date and fingerprint, a health and ACME test as a client,
the download page, what `ca.lab` points to, and the clock.

## If something is wrong

| Symptom | Check |
|---|---|
| Install fails at step 1 | No internet for Smallstep's repository. Use the `.deb` files and `STEP_PACKAGES` (see "What you need"). |
| `step-ca` won't start | `sudo journalctl -u step-ca -n 30`. Port 443 already in use? `sudo ss -ltnp \| grep :443`. |
| certbot: "certificate verify failed" talking to the CA | That machine does not trust the root yet. Step 4, then run certbot again. |
| certbot: "Connection refused" or "Timeout during connect" | The CA could not reach the server on port 80 by its name. `dig <name> @172.16.11.10` must give the server's address, and port 80 must be open and free (stop the web server, or use `--webroot`). |
| certbot: "NXDOMAIN" or "no such host" | The name is not in range DNS yet. Register it (step 3 shows how) and wait a minute. |
| Browser says the certificate is not yet valid, or expired | Wrong clock on the browser's machine or on the CA. Check `date` on both. |
| Firefox does not trust range sites | Restart Firefox, then look at `about:policies`. On Linux, run the install script again after installing Firefox. |
| Chromium on Linux does not trust range sites | `sudo apt install libnss3-tools`, open Chromium once, then run the install script again. |
| The fingerprint does not match | Do not install it. Either the CA was rebuilt (check `--check` on the CA), or someone is tampering with the download. |
| You rebuilt the CA | Every client must trust the new root, and every certificate must be issued again. Avoid this: back up the container. |

## Status

Tested 2026-11-27 on Ubuntu 24.04 on a test machine with step-ca 0.30.2 (built from source for the test, since the test machine could not reach Smallstep's repository):
a new CA, re-runs that change nothing, the CA's own health and ACME checks, the download page, `--issue` (chain checked with openssl),
the Linux client script (system store, Firefox policy files, Chromium store, a wrong fingerprint refused, `--remove`),
and certbot 2.9 getting a 90-day certificate for 18 names over ACME for the connectivity-check server.
Not yet tested: Smallstep's apt repository on a range VM, a Proxmox container on GREY, the Windows script, and the phone and board steps.

Ideas not built: query logs to WHITECELL syslog, short-lived certificates for labs, and DNS-01 for wildcards.
