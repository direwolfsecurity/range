# Range connectivity checks: stop "No Internet"

Windows, Android, Apple devices, Firefox and Linux each test whether they are online by fetching one small, known page from the internet.
On the range that test fails, so machines show "No Internet", "Limited connection" or a sign-in pop-up, and some programs give up.

This server answers those tests the way the real servers do. It also answers for the **well-known names**: real internet names
the range serves itself, such as `time.windows.com` and `pool.ntp.org` pointing at the range time server.

License: CC BY-SA 4.0 for this guide, GPL-3.0 for the scripts. Dire Wolf Security.

## Get the files

On the check server, clone only this folder:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/direwolfsecurity/range.git
cd range
git sparse-checkout set assets/grey/connectivity-check
cd assets/grey/connectivity-check
```

## How it works

The test pages live on real domains (`msftconnecttest.com`, `gstatic.com`, `apple.com` ...). On the range, DNS comes from our own roots (`../root-dns/`).
So the trick is in DNS:

1. On the root primary, the registrar hands each of those domains to this server, the way a real registrar hands `example.com` to its owner's name server.
2. This server runs a small DNS server (BIND) that answers for those domains, and a web server (nginx) that answers the tests.

Any range machine that uses the range resolver then finds `www.msftconnecttest.com` on this server, gets exactly the text Windows expects, and shows it is online.
The list of names lives in one file, `names.conf`. Later builds (package mirrors, mail) add their real-world names there too.

This server answers for the **whole** domain. `www.google.com` on the range is this server, and any name in those domains not listed
in `names.conf` gets "no such name". That is how the range's pretend internet works: only what we build exists.

| Who | What it fetches | What it must get |
|---|---|---|
| Windows 10 and 11 | `http://www.msftconnecttest.com/connecttest.txt`, and a DNS lookup of `dns.msftncsi.com` | The text `Microsoft Connect Test`, and the address `131.107.255.255` |
| Older Windows | `http://www.msftncsi.com/ncsi.txt` | `Microsoft NCSI` |
| Android | `http://connectivitycheck.gstatic.com/generate_204` (and `www.google.com/gen_204`), plus an HTTPS check | An empty reply with code 204 |
| Chrome, ChromeOS | `http://clients3.google.com/generate_204` | Code 204 |
| iPhone, iPad, Mac | `http://captive.apple.com/hotspot-detect.html` | A page that says `Success` |
| Firefox | `http://detectportal.firefox.com/success.txt` | `success` |
| Ubuntu | `http://connectivity-check.ubuntu.com/` | Code 204 |
| GNOME, Kali (when turned on) | `http://nmcheck.gnome.org/check_network_status.txt` | `NetworkManager is online` |
| Debian, Fedora | `network-test.debian.org/nm`, `fedoraproject.org/static/hotspot.txt` | `NetworkManager is online`, `OK` |

## What you need

| Item | Notes |
|---|---|
| Ubuntu 24.04 | A VM or a Proxmox container (see below). 1 CPU, 512 MB RAM, 8 GB disk is plenty. |
| Address | **172.16.11.30** on GREY (VLAN 110). Not final until `network\registry.csv` exists. |
| DNS name | **`check.lab`**, registered on the grey registrar (step 3). |
| The root DNS servers and registrar | `../root-dns/`, with the registrar selling `com` and `org` (the default). |
| Package access while installing | BIND and nginx (and certbot for HTTPS). A local mirror works. |

## Proxmox containers (LXC) instead of VMs

- **Address and gateway:** set them in Proxmox (container > Network > eth0: `172.16.11.30/24`, gateway `172.16.11.254`). Do not use netplan.
- **DNS server:** set it in Proxmox (container > DNS): a working server while installing, then `172.16.11.10`.
- **The template is small.** As root, first: `apt update && apt install -y git sudo`.
- **Port 53:** Ubuntu's `systemd-resolved` holds 127.0.0.53. BIND here listens only on the container's real address and 127.0.0.1, so they do not clash.
  If you change the container's address, run `--go` again.
- **AppArmor:** BIND's profile may not load inside an unprivileged container. That is fine.
- Start it on boot (Options > Start at boot).

## 1. Install

```bash
sudo bash install.sh          # test mode: lists what it will do, changes nothing
sudo bash install.sh --go     # does it, then prints a status check
```

It builds one DNS zone for each domain in `names.conf`, the check pages, and an information page for everything else.
Safe to run again. Files it replaces are first copied to `/var/backups/direwolf-check/<date>/`.

The status check at the end will say "resolver: nothing" for every name until step 3 is done. That is expected.

## 2. Settings (`check.conf`)

| Setting | What |
|---|---|
| `SERVER_NAME` | `check.lab`. Also the name server for every zone. |
| `NTP_IP` | Where the time names point: the range time server, `172.16.11.123`. |
| `RESOLVER` | The range resolver, `172.16.11.10`. `--check` asks it, to prove the names reach this server through the roots. |
| `HTTPS` | `no` by default. See step 5. |

## 3. Hand the domains to this server

On the check server, print the commands:

```bash
sudo bash install.sh --registrar
```

Copy what it prints and run it on the **primary root DNS server**. It looks like this:

```bash
sudo -u www-data php /opt/registrar/cli.php add-a check.lab 172.16.11.30
sudo -u www-data php /opt/registrar/cli.php add-ns msftconnecttest.com check.lab
sudo -u www-data php /opt/registrar/cli.php add-ns gstatic.com check.lab
...
sudo registrar-apply
```

If a line says "already registered", someone (maybe a student) already owns that domain on the registrar.
See who with `sudo -u www-data php /opt/registrar/cli.php list`, remove it with `... cli.php del <domain>`, and run that line again.
Registering these domains also stops students from taking `google.com` for themselves.

Then on the check server: `sudo bash install.sh --check`. Every name should say `ok`.

## 4. See it work

| Machine | How to check |
|---|---|
| Windows | The network icon loses its globe within a minute or two. In PowerShell: `Get-NetConnectionProfile` shows `IPv4Connectivity : Internet`. |
| Kali, Ubuntu (NetworkManager) | `nmcli networking connectivity check` says `full`. |
| Android, iPhone | Join the range Wi-Fi: no "sign in to network" pop-up. Android may still say "limited" (see below). |
| Firefox | No "you must log in to this network" bar. |

**Kali.** Like Debian, Kali normally ships NetworkManager with no check turned on (`nmcli networking connectivity check` says `unknown` or `full` whatever happens). So it never says "No Internet", but it also never warns when the range is down.
To turn the check on (for example in the Kali image):

```bash
printf '[connectivity]\nuri=http://nmcheck.gnome.org/check_network_status.txt\ninterval=300\n' | sudo tee /etc/NetworkManager/conf.d/20-range-connectivity.conf
sudo systemctl reload NetworkManager
```

**Android also checks over HTTPS** (`https://www.google.com/generate_204`). Phones trust only their built-in roots for that check, not roots a user adds,
so Android may show "limited connection" or "connected, no internet" even when the HTTP check passes. Browsing still works.
On a lab phone you control, you can point that check at plain HTTP with `adb`:
`adb shell settings put global captive_portal_https_url http://connectivitycheck.gstatic.com/generate_204`. Not tested yet.

## 5. HTTPS (optional)

With the range CA built (`../ca/`), this server can get a certificate for its names over ACME, like any site gets one from Let's Encrypt.
Then `https://www.google.com/generate_204` works on machines that trust the range root.

1. Build the CA and do step 3 above first (the CA checks every name over HTTP).
2. In `check.conf`, set `HTTPS="yes"` and `CA_FINGERPRINT` to the root fingerprint the CA's `--check` shows.
3. `sudo bash install.sh --go`

It downloads and checks the range root, trusts it, runs certbot against `https://ca.lab/acme/acme/directory`
and turns on port 443. certbot's timer renews the certificate by itself (90 days). A new "check" name in `names.conf` grows the certificate on the next `--go`.

A fun detail for class: the range CA just issued a certificate for `www.google.com`. It could, because we control the range's DNS.
That is exactly why real browsers only trust a short list of CAs, and why a planted root certificate is so dangerous.

## 6. Add or change names (`names.conf`)

```
# name                          answer
time.windows.com                ntp
*.pool.ntp.org                  ntp
dns.msftncsi.com                131.107.255.255
archive.ubuntu.com              172.16.11.40     # for example, a package mirror later
```

`check` means this server, `ntp` means `NTP_IP`, or give an address. A name can start with `*.` to cover everything under it.
After a change, run `sudo bash install.sh --go`. If the change adds a **new domain**, run `--registrar` again and do step 3 for the new line.
Range names (`.lab`) do not go here: register them on the registrar with `add-a`.

## Check it

```bash
sudo bash install.sh --check
```

It shows the services and ports, every name as this server answers it and as the range resolver answers it, every check page, and the HTTPS certificate when there is one.

## If something is wrong

| Symptom | Check |
|---|---|
| `--check`: "here" is wrong for a name | Run `--go` again. A broken `names.conf` line stops the script before it changes anything. |
| `--check`: "resolver: nothing" | Step 3 not done, or not for that domain. On the root primary: `cli.php list` should show the domain with `NS check.lab`. |
| `--check`: the resolver gives an old answer | The resolver remembers answers for up to 5 minutes. Wait, or on the resolver: `sudo unbound-control flush_zone <domain>`. |
| Windows still shows "No Internet" | The PC must use the range resolver (`ipconfig /all`). `Resolve-DnsName dns.msftncsi.com` must give `131.107.255.255`. Then wait a minute or turn the network adapter off and on. |
| Windows opens a browser to `msftconnecttest.com/redirect` | It got the wrong text. Run `curl.exe http://www.msftconnecttest.com/connecttest.txt` on it. |
| A phone shows a sign-in pop-up | It can't reach this server, or the range Wi-Fi hands out a resolver that is not the range one. |
| `named` will not start | `sudo journalctl -u named -n 30`. Did the address change? Run `--go` again. |
| HTTPS: certbot fails | Read the CA's troubleshooting table (`../ca/`). Most often step 3 is missing for one name, or this server does not trust the root. |

Logs: nginx in `/var/log/nginx/access.log` (every check from every machine, handy to see who is on the range). BIND logs to the journal.

## Status

Tested 2026-11-27 on Ubuntu 24.04 on a test machine (BIND 9.18, nginx 1.24, certbot 2.9): all 24 names in 14 zones answered directly
and through a test resolver that sent those domains to this server, every check page returning the exact text and code,
re-runs that change nothing, a removed domain cleaned up, bad `names.conf` lines refused, and HTTPS with a certificate for 18 names from the range CA over ACME.
The registrar commands (step 3) were not run in the test; they use the registrar's normal `add-a` and `add-ns`.
Not yet tested: on GREY, through the real roots and resolver, and with real Windows, Android, Apple and Kali machines.

Ideas not built: query logs to WHITECELL syslog, and a fake captive portal for a sign-in page lab.
