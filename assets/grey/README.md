# Grey cell assets

Grey assets are the fake internet. Neither team controls them; either team may use them.
They live on VLAN 110 (GREY, 172.16.11.0/24), mostly on pve-r05.

This list was agreed on 2026-11-13. It is in rough build order. Nothing below is built yet except where noted.
No addresses are assigned yet except the planned public resolver (172.16.11.10) and the proposed NTP address (172.16.11.123) and MQTT address (172.16.11.83).

## The rule that ties it together

One registry file is the single source of truth: `network\registry.csv` (not created yet).
One row per network: subnet, owner organization, fake ASN, country, city, latitude, longitude, domain.

Generators read that file and write the DNS zones (forward and reverse), the GeoIP database and the registry (whois) records.
A student who looks up an IP then gets the same answer from all three.

To put one asset on a VM, clone only its folder. See "Get one asset onto a VM" in the top `README.md`.

## Build order

| # | Asset | Folder | What it is | Status |
|---|---|---|---|---|
| 0 | Registry file | `network\registry.csv` | The source of truth above, plus the generator scripts. | Not started |
| 1 | Time server | `time\` | GPS-fed NTP on the 5G Pi, which is also the range's 5G link. Build guide: `time\5g\ntp\`. | Guide written, Pi not set up |
| 2 | Root DNS (two servers) | `root-dns\` | Authoritative only, recursion off. Second server pulls the zone by transfer. Includes root-hint scripts for resolvers. | Scripts written and tested on a test machine, not built on the range yet |
| 3 | TLD servers | `tld-dns\` | `.com`, `.org` and a range-only TLD, so delegation looks real. | Not started |
| 4 | Public resolver | `public-dns\` | The range's "8.8.8.8" at 172.16.11.10. Uses our root hints. | Not started |
| 5 | Certificate authority | `ca\` | Root CA with ACME (step-ca): a fake Let's Encrypt. Without it nothing has working HTTPS. | Not started |
| 6 | Connectivity checks | `connectivity-check\` | Fake the URLs that Windows, Android, Apple and Firefox probe, so machines do not report "No Internet". | Not started |
| 7 | Registry (fake ARIN) | `registry\` | Whois on port 43, RDAP over HTTP and a web lookup page. Reads the registry file. | Not started |
| 8 | GeoIP database | `geoip\` | MaxMind-format (MMDB) City and ASN files built from the registry file, RFC 1918 ranges included. | Not started |
| 9 | Map tile server | `maps\` | TileServer GL with OpenStreetMap vector tiles. Serves vector and PNG tiles. | Not started |
| 10 | Package mirrors | `mirrors\` | Kali/Debian apt, PyPI, container registry, Windows updates. The staging repo at .40 is the start. | Not started |
| 11 | Domain registrar | `root-dns\registrar\` | Web portal where students register a domain and get a delegation. Runs on the two root servers. | Scripts written and tested on a test machine, not built on the range yet |
| 12 | Mail and Git host | `mail\`, `git\` | Internet mail and Gitea, for phishing and code-leak scenarios. | Not started |
| 13 | Update and intel feeds | `feeds\` | Suricata rules, ClamAV signatures, GeoIP update endpoint, IP reputation blocklist. | Not started |
| 14 | Offline reference | `reference\` | Kiwix, so students have documentation in CLOSED mode. | Not started |
| 15 | MQTT broker | `mqtt\` | Mosquitto for Cyber City tiles, at `mqtt.lab`. Open mode for attack labs, secure mode (logins, per-tile rights, optional TLS) for defend labs. | Script written and tested on a test machine, not built on the range yet |

Two jobs are part of other builds, not assets of their own:

- **Well-known names.** Point `pool.ntp.org`, `time.windows.com` and similar at our own servers. Done in the DNS zones (items 2 to 4).
- **Query logging.** Roots and the public resolver log queries to WHITECELL syslog (172.16.12.30) for scoring and forensics.

## Things to remember when building

**Root DNS**
- Every recursive resolver built after this needs our root hints. BIND and Unbound take a hints file.
  Pod domain controllers use `Remove-DnsServerRootHint` and `Add-DnsServerRootHint`. Put this in the templates once.
- BIND and Unbound validate DNSSEC by default and will fail against an unsigned fake root.
  Either turn validation off or sign our root and ship our own trust anchor.
- BIND and Unbound answer RFC 1918 reverse lookups locally with "no such name" by default.
  Switch that off on each resolver or PTR queries never reach our servers.
- Put the second root on a Pi so DNS survives a pve-r05 reboot.

**GeoIP**
- The MMDB writers (Go `mmdbwriter`, Perl `MaxMind::DB::Writer`) skip reserved ranges by default. Both have a switch to include them.
- Set the database type to `GeoLite2-City` and `GeoLite2-ASN` so standard readers accept the files.
- Some tools skip private addresses before they open the database. Test each tool that will use it. Not checked yet.

**Maps**
- The full planet is on the order of 100 GB. A low-zoom world plus full detail for one state or region is far smaller.
- Fonts and icon sprites must be hosted locally too. This is the usual air-gap failure.
- Map data is not republished. A script fetches it from the source, with OpenStreetMap credit.

**Registry**
- Use a made-up registry name, not ARIN's, because this is published.
- We own the root, so the stock `whois` client can find our server with no flags.

## Open decisions (Tim)

1. DNSSEC: sign our root, or turn validation off on resolvers? (The root DNS scripts turn it off for now.)
2. Name of the range-only TLD.
3. Name of the fake registry.
4. Map coverage: how much of the world at full detail?
5. Addresses for each asset on 172.16.11.0/24, including confirming NTP at .123.
6. Check the Library for the old root DNS VM and the old registry code before building (skipped on 2026-11-13 to save time).
