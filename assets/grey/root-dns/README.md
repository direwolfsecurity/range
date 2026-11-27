# Range root DNS and domain registrar

This builds the range's own DNS root: two servers that answer for `.`, the way the real root servers do on the internet.
With it, every resolver on the range can do real recursion (root, then TLD, then the domain) with no internet.
An optional registrar web site runs on the same two servers. Students register `name.com` (or any TLD you offer)
and it works on the range within seconds.

License: CC BY-SA 4.0 for this guide, GPL-3.0 for the scripts. Dire Wolf Security.

## What you need

| Item | Notes |
|---|---|
| Two Ubuntu Server 24.04 VMs | Small is fine: 1 CPU, 1 GB RAM, 10 GB disk each. One is the primary, one the secondary. Putting the secondary on a Pi or another Proxmox host keeps DNS up when one host reboots. |
| A static IP on each | On GREY (172.16.11.0/24) on our range. Set it with netplan before you start. |
| Package access while installing | BIND, and for the registrar Apache and PHP. A local mirror works. Not needed afterwards. |
| The scripts on each VM | `git clone --depth 1 --filter=blob:none --sparse https://github.com/direwolfsecurity/range.git`, then `cd range`, `git sparse-checkout set assets/grey/root-dns` and `cd assets/grey/root-dns`. This gets only this folder (the registrar is inside it). |

## The scripts

| Script | Run on | What it does |
|---|---|---|
| `setup-root-dns.sh` | Both root VMs | Installs BIND and serves `.`. It sees which of the two IPs belongs to this VM and sets it up as primary or secondary. |
| `add-tld.sh` | Root primary only | Adds or removes a TLD that lives on some other server (for example `.corp` on a team's domain controller). |
| `registrar/setup-registrar.sh` | Both root VMs (optional) | Adds the registrar web site and hosts the TLDs it sells on the two roots. |
| `set-root-hints-ubuntu.sh` | Ubuntu resolvers (BIND or Unbound) | Points the resolver at our roots and turns off DNSSEC checking. |
| `Set-RangeRootHints.ps1` | Windows DNS servers (domain controllers) | Same job on Windows. Can also clear forwarders. |

The examples below use 10.0.0.10 for the primary and 10.0.0.11 for the secondary. Use your own addresses.

## 1. Build the two root servers

On the **primary** first, then on the **secondary**:

```bash
sudo bash setup-root-dns.sh --root1-ip 10.0.0.10 --root2-ip 10.0.0.11
```

The names default to `a.root-servers.net` and `b.root-servers.net`. Change them with `--root1-name` and `--root2-name`.
Running it again is safe, but it rewrites the BIND settings. If the registrar is installed, run step 3 again afterwards on that VM.

## 2. Hand a TLD to another server (optional)

Use this when a TLD lives on a different server, such as a team's own `.corp`. Run it on the primary:

```bash
sudo bash add-tld.sh add corp dc01.corp 10.20.0.10
sudo bash add-tld.sh list
sudo bash add-tld.sh remove corp
```

It bumps the zone serial, checks the zone and reloads. The secondary copies the change by itself.

## 3. Registrar web site (optional)

The two roots also host the TLDs the registrar sells: `com net org edu gov lab` by default. On the **primary** first, then the **secondary**:

```bash
cd registrar
sudo bash setup-registrar.sh --root1-ip 10.0.0.10 --root2-ip 10.0.0.11
```

- The site is `http://nic.lab/` (or the primary's IP). The admin page is `/admin/`, user `admin`.
- With no `--admin-pass`, a random password is made. It is shown once and saved in `/root/registrar-admin.txt` on the primary.
- Students search for a name, then pick either their own name servers (with glue when needed) or a simple IP (an A record plus `www`).
- Each domain gets a management code, shown once. It lets the owner change or delete the domain later. The admin page can reset it.
- New TLDs added on the primary show up on the secondary by themselves (a BIND catalog zone).
- Other options: `--tlds "com net org lab"`, `--registrar-domain nic.lab`, `--title "Range Registrar"`.
- A TLD is either sold by the registrar or handed out with `add-tld.sh`, never both.

The admin page uses plain HTTP and basic login. Anyone who can sniff GREY can read that password, which makes it a fine lab target.
Do not reuse a real password there.

Command line, on the primary:

```bash
sudo -u www-data php /opt/registrar/cli.php list
sudo -u www-data php /opt/registrar/cli.php add-a shop.com 10.0.5.20
sudo -u www-data php /opt/registrar/cli.php add-ns acme.com ns1.acme.com 10.0.5.53
sudo -u www-data php /opt/registrar/cli.php close        # or open
sudo registrar-apply                                      # publish to DNS
```

## 4. Point the resolvers at the roots

Every recursive resolver on the range needs our root hints instead of the internet's. Ubuntu, with BIND or Unbound:

```bash
sudo bash set-root-hints-ubuntu.sh --root1-ip 10.0.0.10 --root2-ip 10.0.0.11
sudo bash set-root-hints-ubuntu.sh --root1-ip 10.0.0.10 --root2-ip 10.0.0.11 --install bind9   # no resolver yet
```

A resolver for the whole range (the range's "8.8.8.8") must also answer other machines. Add `--serve` with the networks it may answer.
Without it, BIND and Unbound only answer the machine they run on.

```bash
sudo bash set-root-hints-ubuntu.sh --root1-ip 10.0.0.10 --root2-ip 10.0.0.11 --install unbound --serve 172.16.0.0/12,10.0.0.0/8,192.168.0.0/16
```

Only list range networks. An open resolver on a network you do not control can be abused.

Windows DNS server, in an Administrator PowerShell:

```powershell
.\Set-RangeRootHints.ps1 -Root1IP 10.0.0.10 -Root2IP 10.0.0.11 -ClearForwarders
```

Both turn off DNSSEC checking. Our root is not signed, so with checking on every lookup would fail.
Client PCs do not use root hints. Point them at a resolver.

## Check it

```bash
dig @10.0.0.10 . SOA +norec          # "aa" in the flags, and the same serial on both roots
dig @10.0.0.11 . SOA +norec
dig @<resolver> www.nic.lab          # full recursion through the range
```

The registrar admin page also shows each zone's serial on both roots, with "in sync" or "check".

## If something is wrong

| Symptom | Check |
|---|---|
| "Neither IP is on this host" | The static IP is not set yet (`ip -br addr`), or you swapped the two IPs. |
| Secondary has no `aa` flag | The primary must be up first. Then on the secondary: `sudo rndc retransfer .` |
| Secondary is missing a registrar TLD | `sudo rndc retransfer catz.invalid` on the secondary. |
| Registrar says "publishing to DNS failed" | Run `sudo registrar-apply` on the primary and read the error. It rolls back bad changes. |
| Registrar stopped working after re-running step 1 | Step 1 rewrites BIND's settings. Run step 3 again on that VM. |
| Resolver answers itself but other machines get REFUSED or time out | Run step 4 again with `--serve` and their networks. |
| Resolver gives SERVFAIL for everything | DNSSEC checking is still on, or forwarders are set. Re-run step 4 (`-ClearForwarders` on Windows). |
| Unbound resolver gets no answers when testing on one machine | Unbound will not ask servers on 127.x by default. Use real addresses. |

Logs: `/var/log/named/named.log` and `query.log` (every query, useful for scoring), Apache in `/var/log/apache2/registrar-*.log`.

## Status

Tested 2026-11-27 on Ubuntu 24.04 (BIND 9.18, PHP 8.3, Unbound 1.19), with both roots and the resolver on one test machine:
primary and secondary roots, `add-tld.sh`, the registrar on both roots (web sign-up, whois, admin page, command line, catalog sync
of a new TLD to the secondary), and an Unbound resolver resolving `www.nic.lab` through the roots. `--serve` (added the same day) tested on Unbound (answers listed networks, refuses others) and checked with `named-checkconf` on BIND.
Not yet tested: on two separate VMs on GREY, a BIND resolver, and the Windows script.

Not built yet (see the grey cell list): query logs to WHITECELL syslog, reverse (PTR) zones,
and resolvers answering private-range reverse lookups through our servers.
