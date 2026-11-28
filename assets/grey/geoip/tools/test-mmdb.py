#!/usr/bin/env python3
"""test-mmdb.py - check the GeoIP databases against the registry.

For every network in registry.csv, looks up its first and last address in the three .mmdb files
and checks the answer matches the registry row (city, country, ASN). Uses python3-maxminddb, a
reader written by MaxMind, not by us, so it catches mistakes in our writer too.

Usage:
    python3 test-mmdb.py --registry ../../../network/registry/registry.csv --db /var/lib/GeoIP

License: GPL-3.0, Dire Wolf Security.
"""

import argparse
import os
import sys


def main():
    parser = argparse.ArgumentParser(description="Check .mmdb files against registry.csv")
    parser.add_argument("--registry", required=True)
    parser.add_argument("--db", required=True, help="folder with GeoLite2-City/Country/ASN.mmdb")
    args = parser.parse_args()

    try:
        import maxminddb
    except ImportError:
        sys.exit("python3-maxminddb is missing: sudo apt install python3-maxminddb")

    sys.path.insert(0, os.path.dirname(os.path.abspath(args.registry)))
    import registry
    rows, errors = registry.read(args.registry)
    if errors:
        sys.exit("The registry has problems. Run registry.py to see them.")

    city = maxminddb.open_database(os.path.join(args.db, "GeoLite2-City.mmdb"))
    country = maxminddb.open_database(os.path.join(args.db, "GeoLite2-Country.mmdb"))
    asn = maxminddb.open_database(os.path.join(args.db, "GeoLite2-ASN.mmdb"))

    for db, want in ((city, "GeoLite2-City"), (country, "GeoLite2-Country"), (asn, "GeoLite2-ASN")):
        if db.metadata().database_type != want:
            print("   FAIL  database type is %s, want %s" % (db.metadata().database_type, want))
            return 1

    fails = 0
    checked = 0
    for row in rows:
        for ip in (row.network.network_address, row.network.broadcast_address):
            owner = registry.lookup(rows, str(ip))     # the most specific row, as the database should say
            c = city.get(str(ip)) or {}
            k = country.get(str(ip)) or {}
            a = asn.get(str(ip)) or {}
            got = (c.get("city", {}).get("names", {}).get("en"),
                   k.get("country", {}).get("iso_code"),
                   a.get("autonomous_system_number"))
            want = (owner.city, owner.country, owner.asn)
            checked += 1
            if got != want:
                fails += 1
                print("   FAIL  %s: got %s, want %s" % (ip, got, want))

    # An address outside the registry must find nothing.
    if city.get("8.8.8.8") is not None:
        fails += 1
        print("   FAIL  8.8.8.8 is not in the registry but the database answered")

    # IPv4 clients seen as IPv6 (::ffff:a.b.c.d) must get the same answer.
    first = str(rows[0].network.network_address)
    if rows[0].network.version == 4 and city.get("::ffff:" + first) != city.get(first):
        fails += 1
        print("   FAIL  ::ffff:%s does not match %s" % (first, first))

    if fails:
        print("   %d of %d lookups wrong" % (fails, checked))
        return 1
    print("   ok    %d lookups across %d networks match the registry" % (checked, len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
