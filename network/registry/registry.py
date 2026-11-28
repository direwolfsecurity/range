#!/usr/bin/env python3
"""registry.py - read and check the range registry file (registry.csv).

The registry is the single source of truth for "who owns this address" on the range.
The GeoIP builder, the whois server and the DNS generators all read it through this file,
so they always agree.

Run it to check the file:
    python3 registry.py                 checks registry.csv next to this script
    python3 registry.py other.csv       checks another file
    python3 registry.py --lookup 192.168.103.1

Standard library only. Python 3.8 or newer (works on Windows too).

License: GPL-3.0, Dire Wolf Security.
"""

import csv
import ipaddress
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_FILE = os.path.join(HERE, "registry.csv")

COLUMNS = [
    "network", "org_handle", "org", "asn", "as_name", "country", "region", "region_name",
    "city", "postal", "latitude", "longitude", "accuracy_km", "time_zone", "domain", "use",
]

# Countries the registry may use: ISO code -> (English name, continent code).
# Add a line here when you add a row in a new country.
COUNTRIES = {
    "AU": ("Australia", "OC"),
    "BR": ("Brazil", "SA"),
    "CA": ("Canada", "NA"),
    "CH": ("Switzerland", "EU"),
    "DE": ("Germany", "EU"),
    "ES": ("Spain", "EU"),
    "FR": ("France", "EU"),
    "GB": ("United Kingdom", "EU"),
    "IN": ("India", "AS"),
    "JP": ("Japan", "AS"),
    "KE": ("Kenya", "AF"),
    "MX": ("Mexico", "NA"),
    "NL": ("Netherlands", "EU"),
    "UA": ("Ukraine", "EU"),
    "US": ("United States", "NA"),
    "ZA": ("South Africa", "AF"),
}

CONTINENTS = {
    "AF": "Africa",
    "AN": "Antarctica",
    "AS": "Asia",
    "EU": "Europe",
    "NA": "North America",
    "OC": "Oceania",
    "SA": "South America",
}

# Fake ASNs come from the private-use ranges (RFC 6996), so they can never clash with a real one.
PRIVATE_ASN_RANGES = [(64512, 65534), (4200000000, 4294967294)]

DOMAIN_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$")


class Row:
    """One network from the registry, with its values already converted."""

    def __init__(self, line, raw):
        self.line = line
        self.raw = raw
        self.network = ipaddress.ip_network(raw["network"], strict=True)
        self.org_handle = raw["org_handle"]
        self.org = raw["org"]
        self.asn = int(raw["asn"])
        self.as_name = raw["as_name"]
        self.country = raw["country"]
        self.region = raw["region"]
        self.region_name = raw["region_name"]
        self.city = raw["city"]
        self.postal = raw["postal"]
        self.latitude = float(raw["latitude"])
        self.longitude = float(raw["longitude"])
        self.accuracy_km = int(raw["accuracy_km"])
        self.time_zone = raw["time_zone"]
        self.domain = raw["domain"]
        self.use = raw["use"]

    @property
    def country_name(self):
        return COUNTRIES[self.country][0]

    @property
    def continent(self):
        return COUNTRIES[self.country][1]

    @property
    def continent_name(self):
        return CONTINENTS[self.continent]


def read(path=DEFAULT_FILE):
    """Read and check the registry. Returns (rows, errors). Rows with errors are left out."""
    rows = []
    errors = []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != COLUMNS:
            errors.append("line 1: the columns must be exactly: " + ",".join(COLUMNS))
            return rows, errors
        for raw in reader:
            line = reader.line_num
            problems = check_raw(raw)
            if problems:
                errors.extend("line %d: %s" % (line, p) for p in problems)
                continue
            rows.append(Row(line, raw))
    errors.extend(check_together(rows))
    return rows, errors


def check_raw(raw):
    """Checks one row on its own. Returns a list of problems (empty = fine)."""
    problems = []
    for col in COLUMNS:
        value = raw.get(col)
        if value is None:
            problems.append("missing column %s (too few commas?)" % col)
            return problems
        if value != value.strip():
            problems.append("%s has spaces at the start or end" % col)
    if None in raw:
        problems.append("too many commas (a value with a comma in it needs \"quotes\")")
        return problems
    for col in ("network", "org_handle", "org", "asn", "as_name", "country", "city",
                "latitude", "longitude", "accuracy_km", "time_zone", "domain"):
        if raw[col] == "":
            problems.append("%s is empty" % col)
    if problems:
        return problems

    try:
        ipaddress.ip_network(raw["network"], strict=True)
    except ValueError as e:
        problems.append("network %s is not valid: %s" % (raw["network"], e))

    if not raw["asn"].isdigit():
        problems.append("asn must be a number, not %s" % raw["asn"])
    else:
        asn = int(raw["asn"])
        if not any(lo <= asn <= hi for lo, hi in PRIVATE_ASN_RANGES):
            problems.append("asn %d is not a private-use ASN (64512-65534 or 4200000000-4294967294)" % asn)

    if raw["country"] not in COUNTRIES:
        problems.append("country %s is not in the COUNTRIES list in registry.py (add it there)" % raw["country"])

    for col, low, high in (("latitude", -90, 90), ("longitude", -180, 180)):
        try:
            value = float(raw[col])
            if not low <= value <= high:
                problems.append("%s %s is outside %d to %d" % (col, raw[col], low, high))
        except ValueError:
            problems.append("%s must be a number, not %s" % (col, raw[col]))

    if not raw["accuracy_km"].isdigit() or not 1 <= int(raw["accuracy_km"]) <= 1000:
        problems.append("accuracy_km must be a whole number from 1 to 1000")

    if not time_zone_ok(raw["time_zone"]):
        problems.append("time_zone %s is not a known time zone (like America/New_York)" % raw["time_zone"])

    if not DOMAIN_RE.match(raw["domain"]):
        problems.append("domain %s is not a valid lower-case domain name" % raw["domain"])
    return problems


def time_zone_ok(name):
    """True if name is a real time zone. Skips the check where Python has no zone data (some Windows)."""
    try:
        import zoneinfo
    except ImportError:
        return re.match(r"^[A-Za-z_]+(/[A-Za-z_+-]+)+$", name) is not None
    if not zoneinfo.available_timezones():
        return True
    try:
        zoneinfo.ZoneInfo(name)
        return True
    except Exception:
        return False


def check_together(rows):
    """Checks across rows: duplicates, overlaps, and one name per ASN and per org."""
    problems = []
    seen = {}
    for row in rows:
        key = row.network
        if key in seen:
            problems.append("line %d: %s is already on line %d" % (row.line, key, seen[key].line))
        seen[key] = row

    # Overlaps are allowed only when one network sits inside the other.
    # The smaller one wins (like a more specific route): 172.16.11.20/32 inside 172.16.11.0/24.
    # Two networks that partly overlap are impossible with CIDR, so only duplicates can clash.

    asn_names = {}
    org_names = {}
    for row in rows:
        first = asn_names.setdefault(row.asn, row)
        if first.as_name != row.as_name or first.org_handle != row.org_handle:
            problems.append("line %d: AS%d must have the same as_name and org_handle as line %d"
                            % (row.line, row.asn, first.line))
        first = org_names.setdefault(row.org_handle, row)
        if first.org != row.org or first.domain != row.domain:
            problems.append("line %d: org_handle %s must have the same org and domain as line %d"
                            % (row.line, row.org_handle, first.line))
    return problems


def lookup(rows, address):
    """The row that owns an address: the most specific network that holds it, or None."""
    ip = ipaddress.ip_address(address)
    best = None
    for row in rows:
        if row.network.version == ip.version and ip in row.network:
            if best is None or row.network.prefixlen > best.network.prefixlen:
                best = row
    return best


def main(argv):
    path = DEFAULT_FILE
    address = None
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--lookup" and args:
            address = args.pop(0)
        elif arg in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            path = arg

    rows, errors = read(path)
    if errors:
        for e in errors:
            print("ERROR " + e)
        print("%d problem(s) in %s. Nothing else will build until they are fixed." % (len(errors), path))
        return 1

    if address:
        row = lookup(rows, address)
        if row is None:
            print("%s is not in the registry" % address)
            return 1
        print("%s is in %s (line %d)" % (address, row.network, row.line))
        print("  %s (%s), AS%d %s" % (row.org, row.org_handle, row.asn, row.as_name))
        print("  %s, %s, %s  %.4f, %.4f  %s" % (row.city, row.region_name or row.region,
                                                  row.country_name, row.latitude, row.longitude, row.time_zone))
        print("  domain %s  use: %s" % (row.domain, row.use))
        return 0

    orgs = len({r.org_handle for r in rows})
    asns = len({r.asn for r in rows})
    print("ok: %d networks, %d organizations, %d ASNs in %s" % (len(rows), orgs, asns, path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
