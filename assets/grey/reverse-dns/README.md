# Grey cell reverse DNS server (a.in-addr-servers.arpa)

The range's answer to "what is the name of this address?". On the real internet, `dig -x 8.8.8.8` gives
`dns.google`, and an ISP customer's address gives something like `c-73-12-34-56.hsd1.ma.comcast.net`.
This server does the same for every network in the range registry (`network/registry/registry.csv`):

```
dig -x 192.168.103.5      ->  192-168-103-5.austin.bluestem.lab.
dig 192-168-103-5.austin.bluestem.lab   ->  192.168.103.5
dig -x 172.16.11.20       ->  ca.lab.
```

So a student who looks up an address gets the same owner and city from reverse DNS, whois (`../whois/`) and GeoIP
(`../geoip/`). The name even gives away the city, which is a real OSINT trick.

Grey asset #3. Address **172.16.11.13** (confirmed by Tim 2026-11-28, next to the roots at .11 and .12), name `a.in-addr-servers.arpa`
(the real ones are `a` to `f.in-addr-servers.arpa`). Ubuntu 24.04, BIND 9, a small LXC container is plenty. No Docker.

License: CC BY-SA 4.0 for this guide, GPL-3.0 for the scripts. Dire Wolf Security.

## How it fits in

```
resolver 172.16.11.10 ── "who is 192.168.103.5?" ──> root (root-a/root-b): "arpa is at a.in-addr-servers.arpa"
                     └──────────────────────────────> this server: 5.103.168.192.in-addr.arpa PTR 192-168-103-5.austin.bluestem.lab.
```

| Zone | What is in it |
|---|---|
| `arpa` | The root hands it to this server (`add-tld.sh add arpa ...` on root-a). It says where `in-addr.arpa` is. |
| `in-addr.arpa` | One PTR for every address of every registry network (about 6,600). |
| `bluestem.lab`, `meridian.lab`, `granite.lab`, `nightjar.lab`, `tunnelfox.lab` | The made-up ISPs' forward zones: a name for each of their addresses, so the PTR name points back at the same address ("forward-confirmed reverse DNS"). The registrar hands each domain to `ns1.<domain>` = this server. |

How an address gets its name (first match wins):

1. `names.conf`: fixed names for single servers (`172.16.11.11 a.root-servers.net`, `172.16.11.43 whois.lab` ...).
2. A single-address row in the registry (`172.16.11.60/32`, Open Range Maps Foundation) gets that row's domain: `maps.lab`.
3. Everything else gets a generic name: the address with dashes, the city, the owner's domain:
   `192-168-204-77.kyiv.meridian.lab`.

The zones use BIND's `$GENERATE`, so a whole /24 is one readable line. Open `/etc/bind/zones/rdns/db.in-addr.arpa` and
show the class.

**About the TLDs (`.com`, `.org`, `.lab` ...).** The grey cell list once planned separate TLD servers. Decided
2026-11-28: the registrar (`../root-dns/registrar/`) keeps hosting every TLD it sells on the two roots. So `dig +trace`
shows the root answering for `.com` too, a known difference from the real internet.

## Files

| File | What |
|---|---|
| `dns.conf` | Settings: this server's name, registry path, overlay path, which ISP domains it runs, query log |
| `names.conf` | Fixed reverse names for single addresses |
| `install.sh` | Install, rebuild, check, print the registrar commands. Test mode unless given `--go`. |
| `tools/build-zones.py` | Makes the zone files from the registry. Standard library only. Run it by hand to look at the zones. |
| `tools/dns-apply` | What the range control server (greyctl) runs over SSH. Installed to `/usr/local/sbin`. |
| `tests/test_build_zones.py` | `python3 -m unittest discover -s tests` |

## Build it

### 1. Container

On pve5: Ubuntu 24.04 template, unprivileged, 1 core, 512 MB RAM, 4 GB disk. Network: GREY bridge, VLAN 110,
static `172.16.11.13/24`, gateway `172.16.11.254`. DNS `172.16.11.10`. Start at boot. Log in as root:

```
apt update && apt install -y git sudo
```

### 2. Get the two folders

This asset needs its own folder **and** the registry folder:

```
git clone --depth 1 --filter=blob:none --sparse https://github.com/direwolfsecurity/range.git
cd range
git sparse-checkout set assets/grey/reverse-dns network/registry
cd assets/grey/reverse-dns
```

### 3. Install

```
sudo bash install.sh          # test mode: shows the plan, changes nothing
sudo bash install.sh --go
```

Run `--go` the first time while the container can still reach a package mirror (it installs BIND). At the end every
line of the check should say `ok`, except the last part ("Through the range resolver"), which says `WAIT` until steps 4 and 5.

### 4. Hand it arpa and the ISP domains (on root-a)

```
sudo bash install.sh --registrar
```

It prints the commands. Run them on the root primary (`ssh root-a`):

```
cd ~/range/assets/grey/root-dns
sudo bash add-tld.sh add arpa a.in-addr-servers.arpa 172.16.11.13
sudo -u www-data php /opt/registrar/cli.php add-ns bluestem.lab ns1.bluestem.lab 172.16.11.13
...                                   (one line per ISP domain)
sudo registrar-apply
```

root-b copies the change by itself.

### 5. Let the resolver ask (on the resolver, 172.16.11.10)

Unbound and BIND answer private-range reverse lookups (10.x, 172.16-31.x, 192.168.x) themselves, with "no such name",
unless told not to. `set-root-hints-ubuntu.sh` now tells them. Run root-dns step 4 again on the resolver, with the same
options as the first time:

```
cd ~/range && git pull && cd assets/grey/root-dns
sudo bash set-root-hints-ubuntu.sh --root1-ip 172.16.11.11 --root2-ip 172.16.11.12 --serve 172.16.0.0/12,10.0.0.0/8,192.168.0.0/16
```

Windows DNS servers (pod domain controllers) do not do this, so they need nothing.

### 6. Check it

```
sudo bash install.sh --check
```

From the Kali desktop: `dig -x 192.168.103.5`, `nslookup 172.16.11.20`, `dig +trace -x 192.168.204.77`.

## Change the registry or names.conf, then rebuild

1. Edit the file (on your PC, in the repo). For the registry, check it: `python registry.py`.
2. Commit and push.
3. On this server: `cd ~/range && git pull && cd assets/grey/reverse-dns && sudo bash install.sh --go`

A zone's serial only goes up when its records change, so `--go` twice in a row changes nothing.

## Exercise teams (the overlay)

The range control server (`assets/white/control/`) can give a seat network a team's owner, place and domain. It sends
the teams as an overlay file and runs `dns-apply`, which `install.sh --go` installs in `/usr/local/sbin`. `dns-apply`
checks the overlay against `registry.csv`, saves it to `/etc/direwolf-range/overlay.csv` (`OVERLAY_FILE` in `dns.conf`)
and rebuilds. A bad overlay changes nothing; a failed rebuild puts the old overlay back.

With team blue1 (Kestrel Freight, Denver) on seat 103, `dig -x 192.168.103.5` gives `192-168-103-5.denver.kestrel.lab.`,
and `bluestem.lab` no longer has names for 192.168.103.x. The team runs `kestrel.lab` itself (greyctl registers it), so
whether those names point back is up to them: a good blue team task.

The control server reaches this server over SSH with a key that can run only `dns-apply`. Its `install.sh --keys` prints
the line to add to `/root/.ssh/authorized_keys` here. In `control.conf`: `DNS="ssh:root@172.16.11.13"`.

## Where this was tested

On an Ubuntu 24.04 test machine, 2026-11-28 (BIND 9.18, Unbound 1.19), with systemd stubbed: `install.sh --go` twice
(the second run changed nothing), `--check` (every network ok, PTR and back), the five unit tests, a stand-in root with
the exact `arpa` lines `add-tld.sh` writes, and an Unbound resolver with the new step 4 settings: `dig -x` for range
addresses answered through the root. Without the new Unbound settings the same lookup gave "no such name", which is why
step 5 is needed. `dns-apply` with an overlay (team names appeared, Bluestem's went), a bad overlay (refused, nothing
changed) and greyctl (team add, status, reset to zero).

**Not tested yet:** on pve5, with the real root-a/root-b, and a BIND resolver.

## Things to know

- **Only IPv4.** The registry has no IPv6 networks yet.
- **A PTR proves nothing.** Whoever runs the reverse zone picks the name; that is why mail servers check that the name
  points back (forward-confirmed). A team that gets its own reverse zone could name its addresses `mail.google.com`.
- **Query log:** every lookup is in `/var/log/named/query.log` (turn off with `QUERY_LOG="no"`). Who looked up whom is
  good evidence for scoring and forensics.
- **Second server:** there is only one for now. A secondary (like root-b) can be added later with a zone transfer.
