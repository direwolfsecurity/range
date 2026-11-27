# Range Root DNS — quick start

| Script | Run on | Purpose |
|---|---|---|
| `setup-root-dns.sh` | Both root VMs (Ubuntu 24.04) | Installs BIND9, serves `.` as primary/secondary |
| `add-tld.sh` | Root **primary** only | Add/remove TLD delegations, bumps serial, reloads |
| `set-root-hints-ubuntu.sh` | Ubuntu resolvers (BIND9 or Unbound) | Replaces root hints, disables DNSSEC validation |
| `Set-RangeRootHints.ps1` | Windows DNS Servers (e.g., DCs) | Replaces root hints, optionally clears forwarders |

## 1. Root servers
Give each VM its static IP first (netplan), then on **both**:
```bash
sudo bash setup-root-dns.sh --root1-ip 10.0.0.10 --root2-ip 10.0.0.11
```
The script checks which of the two IPs belongs to this VM and sets it up as primary or secondary to match. Do the primary first.

## 2. Delegate TLDs (primary)
```bash
sudo bash add-tld.sh add com  ns1.nic.com 10.0.1.53
sudo bash add-tld.sh add corp dc01.corp   10.20.0.10
sudo bash add-tld.sh list
```

## 3. Downstream resolvers
```bash
sudo bash set-root-hints-ubuntu.sh --root1-ip 10.0.0.10 --root2-ip 10.0.0.11 [--install bind9]
```
```powershell
.\Set-RangeRootHints.ps1 -Root1IP 10.0.0.10 -Root2IP 10.0.0.11 -ClearForwarders
```

## Verify
```bash
dig @10.0.0.10 . SOA +norec          # aa flag, same serial on both roots
dig @10.0.0.11 . SOA +norec
dig @<resolver> www.something.com    # full recursion through the range
```

## 4. Registrar (optional) — Apache + PHP on the roots
The root servers also host the TLDs the registrar sells (`com net org edu gov lab` by default).
Copy the `registrar/` folder to **both** roots and run, primary first:
```bash
cd registrar && sudo bash setup-registrar.sh --root1-ip 10.0.0.10 --root2-ip 10.0.0.11 --admin-pass 'pick-one'
```
- Site: `http://nic.lab/` (or the primary's IP) · Admin: `/admin/`
- Students register `name.tld` → own nameservers (with glue) **or** a simple A record (+ www)
- A management code (shown once) lets them edit or delete their domain later
- New TLDs added on the primary show up on the secondary on their own (BIND catalog zone)
- CLI: `sudo -u www-data php /opt/registrar/cli.php list|add-tld|add-a|add-ns|del|open|close`, then `sudo registrar-apply`
- A TLD can be **either** registrar-hosted **or** delegated with `add-tld.sh`, not both.
- Re-running `setup-root-dns.sh` overwrites the BIND config, so re-run `setup-registrar.sh` afterwards on that VM.
