#!/usr/bin/env python3
"""build-mmdb.py - make MaxMind-format GeoIP databases from the range registry.

Reads registry.csv (through registry.py, which sits next to it) and writes three files that
standard GeoIP readers open without any change:

    GeoLite2-City.mmdb      country, region, city, postal code, latitude/longitude, time zone
    GeoLite2-Country.mmdb   country and continent only
    GeoLite2-ASN.mmdb       AS number and organization

Readers that work with them: Apache mod_maxminddb, nginx geoip2, PHP/Python/Go/Node "maxminddb"
libraries, mmdblookup, Wireshark, Suricata, Zeek, Graylog, Elastic.

Usage:
    python3 build-mmdb.py --registry ../../../network/registry/registry.csv --out ./out
    python3 build-mmdb.py --registry ... --out ... --date 2026-11-27     (fixed build date)

Standard library only. The MaxMind DB format is open: https://maxmind.github.io/MaxMind-DB/
This file writes it from scratch so students can read how a GeoIP database is put together.
Range networks are private (RFC 1918) addresses. Most writers skip those; this one does not.

License: GPL-3.0, Dire Wolf Security.
"""

import argparse
import datetime
import ipaddress
import os
import struct
import sys

# ---------------------------------------------------------------------------
# Part 1: the data section. Every value is a "control byte" (type + size),
# then the value's bytes. Types are numbered by the MaxMind DB spec.
# ---------------------------------------------------------------------------

TYPE_UTF8 = 2
TYPE_DOUBLE = 3
TYPE_UINT16 = 5
TYPE_UINT32 = 6
TYPE_MAP = 7
TYPE_UINT64 = 9       # "extended" type: types above 7 need a second byte
TYPE_ARRAY = 11
TYPE_BOOLEAN = 14


def control(type_num, size):
    """The control byte(s) that start every value: 3 bits of type, 5 bits of size."""
    if type_num <= 7:
        first = type_num << 5
        extended = b""
    else:
        first = 0
        extended = bytes([type_num - 7])
    if size < 29:
        first |= size
        extra = b""
    elif size < 29 + 256:
        first |= 29
        extra = (size - 29).to_bytes(1, "big")
    elif size < 285 + 65536:
        first |= 30
        extra = (size - 285).to_bytes(2, "big")
    else:
        first |= 31
        extra = (size - 65821).to_bytes(3, "big")
    return bytes([first]) + extended + extra


class UInt16(int):
    """Marks a number that must be stored as uint16 (the spec says which fields are which)."""


class UInt32(int):
    """Marks a number stored as uint32."""


class UInt64(int):
    """Marks a number stored as uint64."""


def encode(value):
    """Turns a Python value into MaxMind DB bytes."""
    if isinstance(value, bool):
        return control(TYPE_BOOLEAN, 1 if value else 0)
    if isinstance(value, str):
        data = value.encode("utf-8")
        return control(TYPE_UTF8, len(data)) + data
    if isinstance(value, float):
        return control(TYPE_DOUBLE, 8) + struct.pack(">d", value)
    if isinstance(value, (UInt16, UInt32, UInt64)):
        type_num = {UInt16: TYPE_UINT16, UInt32: TYPE_UINT32, UInt64: TYPE_UINT64}[type(value)]
        n = int(value)
        data = n.to_bytes((n.bit_length() + 7) // 8, "big")   # shortest form; zero is no bytes at all
        return control(type_num, len(data)) + data
    if isinstance(value, int):
        raise TypeError("say which kind of number %r is: UInt16, UInt32 or UInt64" % value)
    if isinstance(value, dict):
        out = control(TYPE_MAP, len(value))
        for key, item in value.items():
            out += encode(str(key)) + encode(item)
        return out
    if isinstance(value, list):
        out = control(TYPE_ARRAY, len(value))
        for item in value:
            out += encode(item)
        return out
    raise TypeError("cannot store %r in a MaxMind DB" % (value,))


class DataSection:
    """Collects records. Identical records are stored once and shared."""

    def __init__(self):
        self.data = bytearray()
        self.offsets = {}

    def add(self, record):
        blob = encode(record)
        if blob not in self.offsets:
            self.offsets[blob] = len(self.data)
            self.data += blob
        return self.offsets[blob]


# ---------------------------------------------------------------------------
# Part 2: the search tree. A binary tree over the bits of the address.
# Each node has a left (bit 0) and right (bit 1) side. A side is empty,
# another node, or the offset of a record in the data section.
# ---------------------------------------------------------------------------

class Node:
    def __init__(self):
        self.sides = [None, None]


class Record:
    """A leaf: points at one record in the data section."""

    def __init__(self, offset):
        self.offset = offset


def address_bits(network):
    """The network as a 128-bit number and prefix length. IPv4 goes in ::a.b.c.d/96+n, as MaxMind does."""
    if network.version == 4:
        return int(network.network_address), network.prefixlen + 96
    return int(network.network_address), network.prefixlen


def insert(root, network, leaf):
    """Puts a leaf in the tree for this network. Insert big networks before small ones."""
    number, prefix = address_bits(network)
    node = root
    for depth in range(prefix):
        bit = (number >> (127 - depth)) & 1
        if depth == prefix - 1:
            node.sides[bit] = leaf
            return
        child = node.sides[bit]
        if not isinstance(child, Node):
            # Empty, or a bigger network's record: split it so both halves keep the old value.
            new = Node()
            new.sides = [child, child]
            node.sides[bit] = new
            child = new
        node = child


def node_at(root, number, prefix):
    """Walks to the node for number/prefix, making nodes on the way. Used for the IPv4 aliases."""
    node = root
    for depth in range(prefix):
        bit = (number >> (127 - depth)) & 1
        child = node.sides[bit]
        if not isinstance(child, Node):
            new = Node()
            new.sides = [child, child]
            node.sides[bit] = new
            child = new
        node = child
    return node


def add_ipv4_aliases(root):
    """Makes ::ffff:a.b.c.d (IPv4-mapped) and 2002:abcd::/32 (6to4) find the same IPv4 answers.

    MaxMind's own databases do this. A web server that sees IPv4 clients as ::ffff:a.b.c.d
    then still gets an answer.
    """
    ipv4_root = node_at(root, 0, 96)
    for text in ("::ffff:0:0/96", "2002::/16"):
        net = ipaddress.ip_network(text)
        number, prefix = int(net.network_address), net.prefixlen
        parent = node_at(root, number, prefix - 1)
        bit = (number >> (127 - (prefix - 1))) & 1
        parent.sides[bit] = ipv4_root


def number_nodes(root):
    """Gives every node a number, root first (breadth first). Shared nodes get one number."""
    order = []
    numbers = {}
    queue = [root]
    while queue:
        node = queue.pop(0)
        if id(node) in numbers:
            continue
        numbers[id(node)] = len(order)
        order.append(node)
        for side in node.sides:
            if isinstance(side, Node) and id(side) not in numbers:
                queue.append(side)
    return order, numbers


def write_database(path, networks_and_records, database_type, description, build_epoch):
    """Writes one .mmdb file. networks_and_records: list of (ip_network, record dict)."""
    data = DataSection()
    root = Node()
    # Big networks first, so smaller ones inside them are written on top (most specific wins).
    for network, record in sorted(networks_and_records, key=lambda nr: address_bits(nr[0])[1]):
        insert(root, network, Record(data.add(record)))
    add_ipv4_aliases(root)

    order, numbers = number_nodes(root)
    node_count = len(order)

    # Each side is a 32-bit number:
    #   less than node_count  -> another node
    #   equal to node_count   -> no data for this address
    #   more than node_count  -> a record, at (value - node_count - 16) in the data section
    def side_value(side):
        if side is None:
            return node_count
        if isinstance(side, Node):
            return numbers[id(side)]
        return node_count + 16 + side.offset

    tree = bytearray()
    for node in order:
        tree += struct.pack(">II", side_value(node.sides[0]), side_value(node.sides[1]))

    metadata = {
        "binary_format_major_version": UInt16(2),
        "binary_format_minor_version": UInt16(0),
        "build_epoch": UInt64(build_epoch),
        "database_type": database_type,
        "description": {"en": description},
        "ip_version": UInt16(6),
        "languages": ["en"],
        "node_count": UInt32(node_count),
        "record_size": UInt16(32),
    }

    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(tree)
        f.write(b"\x00" * 16)                 # the gap between tree and data
        f.write(data.data)
        f.write(b"\xab\xcd\xefMaxMind.com")   # marks the start of the metadata
        f.write(encode(metadata))
    os.replace(tmp, path)
    return node_count


# ---------------------------------------------------------------------------
# Part 3: registry rows -> GeoLite2-style records (same field names as MaxMind's files)
# ---------------------------------------------------------------------------

def names(text):
    return {"en": text}


def country_part(row):
    return {"iso_code": row.country, "names": names(row.country_name)}


def continent_part(row):
    return {"code": row.continent, "names": names(row.continent_name)}


def city_record(row):
    record = {
        "city": {"names": names(row.city)},
        "continent": continent_part(row),
        "country": country_part(row),
        "location": {
            "accuracy_radius": UInt16(row.accuracy_km),
            "latitude": row.latitude,
            "longitude": row.longitude,
            "time_zone": row.time_zone,
        },
        "registered_country": country_part(row),
    }
    if row.postal:
        record["postal"] = {"code": row.postal}
    if row.region:
        sub = {"iso_code": row.region}
        if row.region_name:
            sub["names"] = names(row.region_name)
        record["subdivisions"] = [sub]
    return record


def country_record(row):
    return {
        "continent": continent_part(row),
        "country": country_part(row),
        "registered_country": country_part(row),
    }


def asn_record(row):
    return {
        "autonomous_system_number": UInt32(row.asn),
        "autonomous_system_organization": row.org,
    }


def load_registry(path):
    """Imports registry.py from the registry folder, then reads and checks the file."""
    folder = os.path.dirname(os.path.abspath(path))
    sys.path.insert(0, folder)
    try:
        import registry
    except ImportError:
        sys.exit("registry.py was not found next to %s. Clone network/registry too (see README)." % path)
    rows, errors = registry.read(path)
    if errors:
        for e in errors:
            print("ERROR " + e, file=sys.stderr)
        sys.exit("The registry has problems. Fix them, then build again.")
    return rows


def main():
    parser = argparse.ArgumentParser(description="Build GeoLite2-format .mmdb files from registry.csv")
    parser.add_argument("--registry", required=True, help="path to registry.csv")
    parser.add_argument("--out", required=True, help="folder for the .mmdb files")
    parser.add_argument("--date", help="build date YYYY-MM-DD (default: now)")
    parser.add_argument("--name", default="Range", help="registry name for the description text")
    args = parser.parse_args()

    if args.date:
        when = datetime.datetime.strptime(args.date, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
    else:
        when = datetime.datetime.now(datetime.timezone.utc)
    epoch = int(when.timestamp())

    rows = load_registry(args.registry)
    os.makedirs(args.out, exist_ok=True)

    builds = [
        ("GeoLite2-City", city_record, "city"),
        ("GeoLite2-Country", country_record, "country"),
        ("GeoLite2-ASN", asn_record, "ASN"),
    ]
    for db_type, make_record, what in builds:
        path = os.path.join(args.out, db_type + ".mmdb")
        pairs = [(row.network, make_record(row)) for row in rows]
        text = "%s GeoIP %s database, built from the range registry (not real-world data)" % (args.name, what)
        nodes = write_database(path, pairs, db_type, text, epoch)
        print("wrote %s: %d networks, %d tree nodes, %d bytes" % (path, len(pairs), nodes, os.path.getsize(path)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
