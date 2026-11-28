# Grey cell assets

Grey assets are the fake internet. Neither team controls them; either team may use them.
They live on VLAN 110 (GREY, 172.16.11.0/24), mostly on pve-r05.

This list was agreed on 2026-11-13. It is in rough build order. The Status column says what is built.
Addresses in use or proposed on GREY: resolver 172.16.11.10, roots 172.16.11.11 and .12, reverse DNS .13 (proposed), CA .20, connectivity check .30, whois .43, GeoIP .50, maps .60, MQTT .83, NTP .123.

## The rule that ties it together

One registry file is the single source of truth: `network\registry\registry.csv`.
One row per network: subnet, owner organization, fake ASN, country, city, latitude, longitude, domain.
See `network\registry\README.md`. Assets that read it clone `network/registry` beside their own folder.

Generators read that file and write the reverse DNS zones (`reverse-dns\`), the GeoIP database (`geoip\`) and the whois records (`whois\`).
A student who looks up an IP then gets the same answer from all three.

Exercise teams do not change that file. They go in an overlay that each generator lays over it (same columns).
The range control server, `assets/white/control/` (`greyctl`, 172.16.12.40 on WHITECELL, planned), is the one place that
changes the grey cell, by hand or from ForgeRange through its API. It also snapshots the whole fake internet and resets it
to zero (the clean core) at the end of an exercise, a semester or a year.

To put one asset on a VM, clone only its folder. See "Get one asset onto a VM" in the top `README.md`.

## Build order

| # | Asset | Folder | What it is | Status |
|---|---|---|---|---|
| 0 | Registry file | `network\registry\` | The source of truth above, and `registry.py`, which reads and checks it for every generator. | Written: 30 networks, 14 made-up owners |
| 1 | Time server | `time\` | GPS-fed NTP on the 5G Pi, which is also the range's 5G link. Build guide: `time\5g\ntp\`. | Pi set up, waiting for a cable move onto the range (Tuesday 2026-12-01) |
| 2 | Root DNS (two servers) | `root-dns\` | Authoritative only, recursion off. Second server pulls the zone by transfer. Includes root-hint scripts for resolvers. | Built on the range (root-a .11, root-b .12) |
| 3 | TLD and reverse DNS | `reverse-dns\` | Reverse DNS: a PTR for every registry address (`192-168-103-5.austin.bluestem.lab`), the made-up ISPs' forward zones, and `arpa` handed over by the root. The TLDs (`.com`, `.org`, `.lab` ...) are hosted on the roots by the registrar (#11); separate TLD servers are open decision 8. | Script written and tested on a test machine, not built on the range yet |
| 4 | Public resolver | `root-dns\` (`set-root-hints-ubuntu.sh`) | The range's "8.8.8.8" at 172.16.11.10. Unbound with our root hints. | Built on the range |
| 5 | Certificate authority | `ca\` | Root CA with ACME (step-ca): a fake Let's Encrypt. Without it nothing has working HTTPS. | Script written and tested on a test machine, not built on the range yet |
| 6 | Connectivity checks | `connectivity-check\` | Fake the URLs that Windows, Android, Apple, Firefox and Linux probe, so machines do not report "No Internet". Also serves the well-known names. | Script written and tested on a test machine, not built on the range yet |
| 7 | Registry (fake ARIN) | `whois\` | `whois.lab`: whois on port 43, RDAP over HTTP and a web lookup page. Reads the registry file; domain questions go to the registrar. Plain `whois` works once check.lab answers `whois.arin.net` and friends. | Script written and tested on a test machine, not built on the range yet |
| 8 | GeoIP database | `geoip\` | `geoip.lab`: MaxMind-format City, Country and ASN files built from the registry file, RFC 1918 ranges included. Download and update service, and a client that makes web servers geo-aware (Apache `mod_maxminddb`, nginx, PHP). | Script written and tested on a test machine (not the Apache module), not built on the range yet |
| 9 | Map tile server | `maps\` | TileServer GL with OpenStreetMap vector tiles. Serves vector and PNG tiles. Plan for embeddable map services (JS libraries, HTTPS, geocoding, tracking): `maps\docs\web-map-services.md`. | Built (Monaco test data), not yet at its GREY address |
| 10 | Package mirrors | `mirrors\` | Kali/Debian apt, PyPI, container registry, Windows updates. The staging repo at .40 is the start. | Not started |
| 11 | Domain registrar | `root-dns\registrar\` | Web portal where students register a domain and get a delegation. Runs on the two root servers. | Built on the range |
| 12 | Mail and Git host | `mail\`, `git\` | Internet mail and Gitea, for phishing and code-leak scenarios. | Not started |
| 13 | Update and intel feeds | `feeds\` | Suricata rules, ClamAV signatures, GeoIP update endpoint, IP reputation blocklist. | Not started |
| 14 | Offline reference | `reference\` | Kiwix, so students have documentation in CLOSED mode. | Not started |
| 15 | MQTT broker | `mqtt\` | Mosquitto for Cyber City tiles, at `mqtt.lab`. Open mode for attack labs, secure mode (logins, per-tile rights, optional TLS) for defend labs. | Script written and tested on a test machine, not built on the range yet |
| 16 | Range control (white cell) | `..\white\control\` | `greyctl` and its API: exercise teams and domains, snapshots, reset to zero. The way ForgeRange changes the grey cell. Lives on WHITECELL because grey is in scope during exercises. | Script written and tested on a test machine, not built on the range yet |

Two jobs are part of other builds, not assets of their own:

- **Well-known names.** Point `pool.ntp.org`, `time.windows.com` and similar at our own servers. Built into item 6: `connectivity-check\names.conf` lists every real-world name the range answers, and the registrar hands those domains to the check server.
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
- We write the MMDB files ourselves (`geoip\tools\build-mmdb.py`, standard library only), so private ranges are included.
- The database types are `GeoLite2-City`, `GeoLite2-Country` and `GeoLite2-ASN`, so standard readers accept the files.
- Some tools skip private addresses before they open the database. Checked and fine: mmdblookup, nginx geoip2, PHP and Python readers.
  Still to check on the range: Apache `mod_maxminddb`, Wireshark, Suricata, Zeek.

**Maps**
- The full planet is on the order of 100 GB. A low-zoom world plus full detail for one state or region is far smaller.
- Fonts and icon sprites must be hosted locally too. This is the usual air-gap failure.
- Map data is not republished. A script fetches it from the source, with OpenStreetMap credit.

**Registry (whois) and reverse DNS**
- Use a made-up registry name, not ARIN's, because this is published.
- We own DNS, so the stock `whois` client finds our server with no flags: check.lab answers `whois.arin.net`,
  `whois.ripe.net`, `whois.verisign-grs.com` and the rest with whois.lab's address (in `connectivity-check\names.conf`).
- Resolvers must not answer private reverse lookups themselves (see Root DNS above). `set-root-hints-ubuntu.sh` handles it.

## Open decisions (Tim)

1. DNSSEC: sign our root, or turn validation off on resolvers? (The root DNS scripts turn it off for now.)
2. Name of the range-only TLD. The registry file uses `.lab` for now (already used for `ca.lab`, `nic.lab` ...).
3. Name of the fake registry. Working name: Grey Internet Registry (GIR).
4. Map coverage: how much of the world at full detail?
5. Addresses for each asset on 172.16.11.0/24, including confirming NTP at .123 and reverse DNS at .13 (GeoIP .50 and whois .43 confirmed 2026-11-28).
6. Check the Library for the old root DNS VM and the old registry code before building (skipped on 2026-11-13 to save time).
7. Where Cyber City sits on the map (its registry row has a placeholder point).
8. Separate TLD servers. Today the roots also host the TLDs (the registrar puts them there), so `dig +trace` shows the root
   answering for `.com`. Real TLD servers mean changing the roots and the registrar (a hidden primary), not just adding a server.
