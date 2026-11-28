# Grey cell whois server (whois.lab)

The range's own internet registry: a made-up ARIN. It answers "who owns this address, this AS number, this
domain?" on the range, the way ARIN, RIPE and Verisign do on the real internet:

| Port | What | Try |
|---|---|---|
| 43 | whois | `whois -h whois.lab 192.168.103.5` |
| 80 | RDAP (whois as JSON, what new tools use) | `http://whois.lab/rdap/ip/192.168.103.5` |
| 80 | Lookup page, with "your address" | `http://whois.lab/` |

Addresses, networks, AS numbers and organizations come from the range registry (`network/registry/registry.csv`),
so whois, reverse DNS (`../reverse-dns/`) and GeoIP (`../geoip/`) always agree. Domains come from the registrar on
root-a: whois.lab asks its whois page and passes the answer on, the way a "thin" registry sends you to the registrar.

Grey asset #7. Address **172.16.11.43** (confirmed by Tim 2026-11-28), name `whois.lab`. Ubuntu 24.04, Python 3
standard library only, a small LXC container is plenty. No Docker.

License: CC BY-SA 4.0 for this guide, GPL-3.0 for the scripts. Dire Wolf Security.

## What it answers

| Ask for | Example | Answer |
|---|---|---|
| An address | `192.168.204.77` | The network (NetRange, CIDR, NetName, NetHandle, Parent, OriginAS, location), its owner, abuse and NOC contacts |
| A network | `192.168.204.0/24`, `NET-192-168-204-0-1` | The same |
| An AS number | `AS64602`, `64602` | The AS, its owner and every network it announces |
| An organization | `MGT`, `Meridian` | The owner, its AS numbers and networks |
| A domain | `shop.com`, `kestrel.lab` | What the registrar knows: registrant, dates, name servers |
| Help | `help` | The list above |

It understands what the stock clients send: ARIN style (`n + 192.168.103.5`, `a 64601`, `o BSBB`), RIPE flags
(`-V Md5.5.22 as64601`), and Verisign style (`domain shop.com`).

Everything is made up and every answer says so. The `use` column of the registry ("Seat 103 ...", "REDCELL: red team
servers") is never shown: it is for the instructor, not for students.

## Plain "whois 192.168.103.5", with no -h

The stock Linux `whois` command picks its server by itself: `whois.arin.net` for addresses, `whois.ripe.net` for
AS numbers, `whois.verisign-grs.com` for `.com` and `.net`, `whois.pir.org` for `.org`, and so on. The range owns DNS,
so the connectivity-check server (`../connectivity-check/names.conf`, the "well-known names") points those names at
whois.lab. After that, `whois 192.168.103.5` and `whois shop.com` work with no options, just like at home.

`.lab` is not in the stock client's list, so for `.lab` domains use `-h whois.lab`, or add this line to
`/etc/whois.conf` on a Linux machine: `\.lab$ whois.lab`

## Files

| File | What |
|---|---|
| `whois.conf` | Settings: name, registry name, registry and overlay paths, registrar address, ports |
| `whoisd.py` | The server: whois, RDAP and the web page in one small program. Standard library only. |
| `install.sh` | Install, update, check, print the registrar commands. Test mode unless given `--go`. |
| `tools/whois-apply` | What the range control server (greyctl) runs over SSH. Installed to `/usr/local/sbin`. |
| `tests/test_whoisd.py` | `python3 -m unittest discover -s tests` |

Try it on any PC with Python, no install: `python whoisd.py --query 192.168.204.77` (Windows: `py`).

## Build it

### 1. Container

On pve5: Ubuntu 24.04 template, unprivileged, 1 core, 256 MB RAM, 4 GB disk. Network: GREY bridge, VLAN 110,
static `172.16.11.43/24`, gateway `172.16.11.254`. DNS `172.16.11.10`. Start at boot. Log in as root:

```
apt update && apt install -y git sudo
```

### 2. Get the two folders

```
git clone --depth 1 --filter=blob:none --sparse https://github.com/direwolfsecurity/range.git
cd range
git sparse-checkout set assets/grey/whois network/registry
cd assets/grey/whois
```

### 3. Install

```
sudo bash install.sh          # test mode: shows the plan, changes nothing
sudo bash install.sh --go
```

It makes a `whoisd` user and a `direwolf-whois` service. The service is not root: systemd gives it only the right to
use ports 43 and 80. The program and a copy of the registry go to `/opt/direwolf-whois`, settings to `/etc/direwolf-whois`.
At the end every line of the check should say `ok`. The DNS lines say `WAIT` until steps 4 and 5.

### 4. Register the name (on root-a)

The registrar's own setup pointed `whois.lab` at root-a. Move it here:

```
sudo bash install.sh --registrar          # prints these:
sudo -u www-data php /opt/registrar/cli.php del whois.lab
sudo -u www-data php /opt/registrar/cli.php add-a whois.lab 172.16.11.43
sudo registrar-apply
```

### 5. The real whois names (on check.lab)

So plain `whois` works with no `-h` (see above). On the connectivity-check server:

```
cd ~/range && git pull && cd assets/grey/connectivity-check
sudo bash install.sh --go
sudo bash install.sh --registrar          # run the new add-ns lines it prints on root-a
```

### 6. Check it

```
sudo bash install.sh --check
```

From the Kali desktop: `whois 192.168.204.77`, `whois AS64530`, `whois nic.lab -h whois.lab`, and `http://whois.lab/`.

### 7. Save the clean core again

The registrar changed in step 4 (and 5), so save greyctl's `zero` snapshot again once everything checks out:
`greyctl snapshot save zero --replace --note "whois and reverse DNS added"`.

## Change the registry, then update

1. Edit `network/registry/registry.csv` (on your PC, in the repo) and check it: `python registry.py`.
2. Commit and push.
3. On whois.lab: `cd ~/range && git pull && cd assets/grey/whois && sudo bash install.sh --go`

## Exercise teams (the overlay)

The range control server (`assets/white/control/`) sends exercise teams as an overlay file and runs `whois-apply`.
It checks the overlay against the registry, then saves it to `/etc/direwolf-range/overlay.csv` (`OVERLAY_FILE` in
`whois.conf`). `whoisd` sees the new file within a few seconds by itself: no restart, no lost connections. A bad overlay
changes nothing. With team blue1 on seat 103, `whois 192.168.103.5` shows Kestrel Freight in Denver, registered today.

The control server reaches this server over SSH with a key that can run only `whois-apply`. Its `install.sh --keys` prints
the line to add to `/root/.ssh/authorized_keys` here. In `control.conf`: `WHOIS="ssh:root@172.16.11.43"`.

## Where this was tested

On an Ubuntu 24.04 test machine, 2026-11-28, with systemd stubbed: `install.sh --go` and `--check` (all 30 networks
ok, RDAP, the web page), the service running as `whoisd` on ports 43 and 80 with only `CAP_NET_BIND_SERVICE`, the stock
`whois` 5.5.22 client, domain lookups against the real registrar PHP code, the nine unit tests, `whois-apply`
(overlay picked up without a restart, a bad overlay refused, a bad file on disk ignored with the last good data kept),
and greyctl (team add, status, reset to zero).

**Not tested yet:** on pve5, the real whois names through check.lab, and Windows whois tools (Sysinternals `whois64`
asks its own servers, so it needs `whois64 192.168.103.5 whois.lab`).

## Things to know

- **Whois is a lab target.** It is plain text with no login, like the real thing. The registrar's registrant names and
  emails are whatever students typed when they registered: a good privacy lesson ("what does whois say about you?").
- **The query log** is in the journal: `journalctl -u direwolf-whois`. Every lookup, with who asked.
- **Abuse contacts** (`abuse@bluestem.lab` ...) are made up. When range mail exists (grey #12), they could become real
  mailboxes for an incident-reporting exercise.
