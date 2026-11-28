# Range registry

`registry.csv` is the single source of truth for "who owns this address" on the range.
One row per network: owner, fake AS number, place on the map, and domain.

Everything that answers that question is built from this one file, so a student gets the same answer from all of them:

| Reads it | Asset | State |
|---|---|---|
| GeoIP databases (`.mmdb`, for Apache, nginx, Wireshark ...) | `assets/grey/geoip/` (#8) | built |
| Whois, RDAP and the lookup web page | `assets/grey/registry/` (#7) | not started |
| DNS: forward zones for each domain, reverse (PTR) zones for each network | `assets/grey/tld-dns/` (#3) | not started |

License: CC BY-SA 4.0 for this guide and the data, GPL-3.0 for `registry.py`. Dire Wolf Security.

## Columns

| Column | What | Example |
|---|---|---|
| `network` | The network, CIDR. A smaller network inside a bigger one wins (like a more specific route). | `192.168.103.0/24` |
| `org_handle` | Short ID for the owner. Same handle = same org and domain on every row. | `BSBB` |
| `org` | Owner's name. Made up. | `Bluestem Broadband` |
| `asn` | Fake AS number from the private-use range (64512-65534), so it can't clash with a real one | `64601` |
| `as_name` | Name of the AS, the way BGP tables show it | `BLUESTEM` |
| `country` | ISO country code. Must be in the list at the top of `registry.py`. | `US` |
| `region`, `region_name` | State or province code and name | `TX`, `Texas` |
| `city`, `postal` | City and postal code | `Austin`, `78701` |
| `latitude`, `longitude` | Map point, decimal degrees | `30.2672`, `-97.7431` |
| `accuracy_km` | How sure GeoIP is, in km (shown as a circle on maps) | `10` |
| `time_zone` | IANA time zone | `America/Chicago` |
| `domain` | The owner's domain. Range-only TLD (see below) so no real company is named. | `bluestem.lab` |
| `use` | What the network is on the range. For people, not for tools. | `Seat 103 outside network (EDGE-2)` |

Values with a comma in them need double quotes, as in any CSV file. Places are real cities; owners are made up.

## How the range is laid out in it

| Networks | Owner (made up) | Seen as |
|---|---|---|
| 172.16.11.0/24 GREY, with single addresses for the resolver, CA, maps and NTP | Grey Internet Registry, Quad Ten Public DNS, Range Encrypt, Open Range Maps Foundation, Range Time Institute | Ashburn, San Jose, San Francisco, London, Boulder |
| 172.16.12.0/24 WHITECELL | Exercise Control | Washington DC |
| 172.16.13.0/24 REDCELL, 10.250.250.0/24 red VPN | Nightjar Hosting B.V., Tunnelfox VPN AG | Amsterdam, Zurich |
| 192.168.31-33.0/24 transit and uplink | Granite Backbone Networks | Chicago |
| 192.168.34.0/24 CITY | Cyber City Municipal Network | a placeholder point in the middle of the USA |
| 192.168.200.0/24, 192.168.210.0/24 targets | Larkspur Medical Group, Harborline Logistics | Denver, Seattle |
| 192.168.101-109.0/24 seats on EDGE-2 | Bluestem Broadband (a US ISP) | nine US cities, Boston to Honolulu |
| 192.168.201-207.0/24 seats on EDGE-1 | Meridian Global Telecom (a world ISP) | Mexico City, Sao Paulo, Madrid, Kyiv, Nairobi, Tokyo, Sydney |

So each seat looks like it is in a different city, which gives the web design class something to show, and red team
traffic arrives from "a hosting company in Amsterdam", the way real attacks often do.

The pod inside network (10.10.10.0/24) is the same in every pod and never leaves it, so it is not in the registry.

## Check it

```
python registry.py                          # Windows: py registry.py
python registry.py --lookup 192.168.204.10  # who owns this address?
```

It checks every row (valid network, private ASN, known country, real time zone, lat/long in range, domain format)
and across rows (no duplicates, one name per ASN, one org and domain per handle). Nothing builds from a file with errors.

## Get it onto a server

Assets that read the registry clone this folder as well as their own. For example, on the GeoIP server:

```
git sparse-checkout set assets/grey/geoip network/registry
```

## Open decisions (Tim)

- The fake registry's name. Working name: "Grey Internet Registry" (GIR). It is in this file's first row and in
  `assets/grey/geoip/geoip.conf`.
- The range-only TLD. The file uses `.lab`, which the range already uses for `ca.lab`, `nic.lab` and the rest.
- Where Cyber City sits on the map (latitude and longitude for 192.168.34.0/24). Placeholder: the geographic
  centre of the lower 48 states, in Kansas.
