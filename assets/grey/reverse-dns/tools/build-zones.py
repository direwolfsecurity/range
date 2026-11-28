#!/usr/bin/env python3
"""build-zones.py - make the range's reverse DNS zones (and the ISP zones) from the registry.

Reads registry.csv (through registry.py, which sits next to it), an optional exercise
overlay, and names.conf. Writes BIND zone files and the zone list for named.conf:

    db.arpa            the "arpa" zone (the root delegates arpa to this server)
    db.in-addr.arpa    every PTR record: who an IPv4 address belongs to
    db.<domain>        one forward zone per ISP domain (ISP_DOMAINS in dns.conf), with a
                       name for every address, so reverse and forward lookups agree
    named.conf.rdns    the zone statements

Usage (install.sh runs it; you can run it by hand to look at the zones):
    python3 build-zones.py --registry ../../../network/registry/registry.csv \\
        --names ../names.conf --server-ip 172.16.11.13 --out /tmp/zones

How each address gets its name (first match wins):
    1. names.conf               172.16.11.20  ca.lab
    2. a single-address row     172.16.11.60/32 in the registry -> its domain (maps.lab)
    3. the generic name         192.168.103.5 -> 192-168-103-5.austin.bluestem.lab
                                (address with dashes, then the city, then the owner's domain,
                                the way real ISPs name their customers' addresses)

Standard library only. Python 3.8 or newer.

License: GPL-3.0, Dire Wolf Security.
"""

import argparse
import hashlib
import ipaddress
import json
import os
import re
import sys
import time

HOST_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$")


# ---------------------------------------------------------------------------
# Reading the inputs
# ---------------------------------------------------------------------------

def load_registry(path, overlay):
    """Imports registry.py from the registry folder, then reads the file (and the overlay)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(path)))
    try:
        import registry
    except ImportError:
        sys.exit("registry.py was not found next to %s. Clone network/registry too (see README)." % path)
    if overlay and os.path.exists(overlay) and os.path.getsize(overlay) > 0:
        rows, errors = registry.read_with_overlay(path, overlay)
    else:
        rows, errors = registry.read(path)
    if errors:
        for e in errors:
            print("ERROR " + e, file=sys.stderr)
        sys.exit("The registry (or the exercise overlay) has problems. Nothing was built.")
    return registry, [r for r in rows if r.network.version == 4]


def read_names(path):
    """names.conf: "<IPv4 address> <name>" per line. Returns {address: name}."""
    names = {}
    if not path:
        return names
    with open(path, encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 2:
                sys.exit("%s line %d: write  <address> <name>" % (path, number))
            try:
                address = ipaddress.IPv4Address(parts[0])
            except ValueError:
                sys.exit("%s line %d: %s is not an IPv4 address" % (path, number, parts[0]))
            name = parts[1].lower().rstrip(".")
            if not HOST_RE.match(name):
                sys.exit("%s line %d: %s is not a valid name" % (path, number, parts[1]))
            if address in names:
                sys.exit("%s line %d: %s is listed twice" % (path, number, address))
            names[address] = name
    return names


# ---------------------------------------------------------------------------
# Names for addresses
# ---------------------------------------------------------------------------

def slug(text):
    """ "Sao Paulo" -> "sao-paulo": a city name as a DNS label."""
    text = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return text[:63] or "x"


def generic_name(address, row):
    """192.168.103.5 in Austin, bluestem.lab -> 192-168-103-5.austin.bluestem.lab"""
    return "%s.%s.%s" % (str(address).replace(".", "-"), slug(row.city), row.domain)


def blocks_of(rows):
    """Every /24 that holds part of a registry network, in order."""
    blocks = set()
    for row in rows:
        net = row.network
        if net.prefixlen >= 24:
            blocks.add(net.supernet(new_prefix=24))
        elif net.prefixlen >= 16:
            blocks.update(net.subnets(new_prefix=24))
        else:
            print("warning: %s is bigger than a /16; reverse names are made only for its first /16" % net,
                  file=sys.stderr)
            blocks.update(next(net.subnets(new_prefix=16)).subnets(new_prefix=24))
    return sorted(blocks)


def is_host(address, row):
    """False for the network and broadcast address of a normal network."""
    net = row.network
    if net.prefixlen >= 31:
        return True
    return address not in (net.network_address, net.broadcast_address)


def plan_block(registry, rows, block, names):
    """For one /24: a list of (last octet, row, name or None). None = use the generic name."""
    plan = []
    for octet in range(256):
        address = block.network_address + octet
        row = registry.lookup(rows, str(address))
        if row is None:
            continue
        if address in names:
            plan.append((octet, row, names[address]))
        elif row.network.prefixlen == 32:
            plan.append((octet, row, row.domain))
        elif is_host(address, row):
            plan.append((octet, row, None))
    return plan


def runs(plan):
    """Groups generic entries that follow each other and share a row: [(first, last, row)]."""
    out = []
    for octet, row, name in plan:
        if name is not None:
            continue
        if out and out[-1][2] is row and out[-1][1] == octet - 1:
            out[-1] = (out[-1][0], octet, row)
        else:
            out.append((octet, octet, row))
    return out


# ---------------------------------------------------------------------------
# Zone files
# ---------------------------------------------------------------------------

def reverse_body(registry, rows, names):
    """The records of the in-addr.arpa zone (no SOA), and how many names they make."""
    lines = []
    count = 0
    for block in blocks_of(rows):
        a, b, c, _ = str(block.network_address).split(".")
        plan = plan_block(registry, rows, block, names)
        if not plan:
            continue
        owners = sorted({"%s %s (AS%d)" % (row.network, row.org, row.asn) for _, row, _ in plan})
        lines.append("")
        lines.append("; ---- %s.%s.%s.0/24: %s" % (a, b, c, "; ".join(owners)))
        for first, last, row in runs(plan):
            # $GENERATE writes one PTR per number: 5.103.168.192 PTR 192-168-103-5.austin.bluestem.lab.
            lines.append("$GENERATE %d-%d $.%s.%s.%s PTR %s-%s-%s-$.%s.%s."
                         % (first, last, c, b, a, a, b, c, slug(row.city), row.domain))
        for octet, row, name in plan:
            if name is not None:
                lines.append("%-24s PTR %s." % ("%d.%s.%s.%s" % (octet, c, b, a), name))
        count += len(plan)
    return lines, count


def forward_body(registry, rows, names, domain, server_ip):
    """The records of one ISP zone: ns1, plus a name for every address it owns."""
    lines = ["ns1 IN A %s" % server_ip]
    count = 0
    for block in blocks_of(rows):
        a, b, c, _ = str(block.network_address).split(".")
        plan = [p for p in plan_block(registry, rows, block, {}) if p[1].domain == domain]
        for first, last, row in runs(plan):
            lines.append("$GENERATE %d-%d %s-%s-%s-$.%s A %s.%s.%s.$" % (first, last, a, b, c, slug(row.city), a, b, c))
            count += last - first + 1
    return lines, count


def next_serial(old):
    today = int(time.strftime("%Y%m%d")) * 100 + 1
    return max((old or 0) + 1, today)


def zone_text(state, key, origin, ns_name, hostmaster, body_lines, comment):
    """SOA + NS + body. The serial only goes up when the body changes."""
    body = "\n".join(body_lines) + "\n"
    digest = hashlib.sha256((ns_name + body).encode()).hexdigest()
    old = state.get(key, {})
    serial = old.get("serial", 0)
    if old.get("hash") != digest or not serial:
        serial = next_serial(serial)
    state[key] = {"hash": digest, "serial": serial}
    head = [
        "; %s - made by build-zones.py from the range registry. DO NOT EDIT: edit the registry," % origin,
        "; names.conf or dns.conf, then: sudo bash install.sh --go",
        "; %s" % comment,
        "$TTL 3600",
        "$ORIGIN %s." % origin,
        "@ IN SOA %s. %s. ( %d 3600 600 604800 300 )" % (ns_name, hostmaster, serial),
        "@ IN NS %s." % ns_name,
    ]
    return "\n".join(head) + "\n" + body


def build(args):
    registry, rows = load_registry(args.registry, args.overlay)
    names = read_names(args.names)
    server_ip = ipaddress.IPv4Address(args.server_ip)
    ns_name = args.ns_name.lower().rstrip(".")
    hostmaster = args.hostmaster.lower().rstrip(".")
    if not ns_name.endswith(".arpa"):
        sys.exit("--ns-name must be under arpa (for example a.in-addr-servers.arpa)")
    # This server's own address gets its own name, unless names.conf says otherwise.
    names.setdefault(server_ip, ns_name)
    for address in names:
        if registry.lookup(rows, str(address)) is None:
            print("warning: names.conf: %s is not in the registry, so it gets no PTR" % address, file=sys.stderr)

    state = {}
    if args.state and os.path.exists(args.state):
        with open(args.state, encoding="utf-8") as f:
            state = json.load(f)

    files = {}
    # arpa: the zone the root hands us. It only says where in-addr.arpa lives (here too).
    arpa = [
        "%s. IN A %s" % (ns_name, server_ip),
        "in-addr.arpa. IN NS %s." % ns_name,
    ]
    files["db.arpa"] = zone_text(state, "arpa", "arpa", ns_name, hostmaster, arpa,
                                 "The real arpa zone is run by the root servers' operators. Here this server runs it.")
    reverse, ptrs = reverse_body(registry, rows, names)
    files["db.in-addr.arpa"] = zone_text(state, "in-addr.arpa", "in-addr.arpa", ns_name, hostmaster, reverse,
                                         "Reverse names (PTR) for every registry network.")

    zones = [("arpa", "db.arpa"), ("in-addr.arpa", "db.in-addr.arpa")]
    domains_in_use = {row.domain for row in rows}
    report = ["in-addr.arpa: %d names" % ptrs]
    for domain in args.isp:
        domain = domain.lower().rstrip(".")
        if domain not in domains_in_use:
            print("warning: ISP domain %s is not in the registry; skipped" % domain, file=sys.stderr)
            continue
        body, count = forward_body(registry, rows, names, domain, server_ip)
        files["db." + domain] = zone_text(state, domain, domain, "ns1." + domain, hostmaster, body,
                                          "Forward names for %s's addresses (%d), so PTR and A agree." % (domain, count))
        zones.append((domain, "db." + domain))
        report.append("%s: %d names" % (domain, count))

    conf = ["// Made by build-zones.py. Edit dns.conf or names.conf and run install.sh --go instead."]
    for zone, filename in zones:
        conf.append('zone "%s" { type primary; file "%s/%s"; };' % (zone, args.zone_dir, filename))
    files["named.conf.rdns"] = "\n".join(conf) + "\n"

    os.makedirs(args.out, exist_ok=True)
    for filename, text in files.items():
        with open(os.path.join(args.out, filename), "w", encoding="utf-8") as f:
            f.write(text)
    with open(os.path.join(args.out, "zones.txt"), "w", encoding="utf-8") as f:
        f.write("".join("%s %s\n" % z for z in zones))
    with open(os.path.join(args.out, "state.json"), "w", encoding="utf-8") as f:
        json.dump(state, f, indent=1)
    print("built %d zones: %s" % (len(zones), ", ".join(report)))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Build reverse DNS (and ISP) zones from registry.csv")
    parser.add_argument("--registry", required=True, help="path to registry.csv")
    parser.add_argument("--overlay", default="", help="exercise overlay (same columns); missing or empty = none")
    parser.add_argument("--names", default="", help="names.conf: fixed names for some addresses")
    parser.add_argument("--server-ip", required=True, help="this server's address (glue and ns1 records)")
    parser.add_argument("--ns-name", default="a.in-addr-servers.arpa", help="this server's name under arpa")
    parser.add_argument("--hostmaster", default="hostmaster.nic.lab", help="SOA contact, @ written as a dot")
    parser.add_argument("--isp", nargs="*", default=[], help="domains that get forward zones here")
    parser.add_argument("--zone-dir", default="/etc/bind/zones/rdns", help="where BIND will read the zone files")
    parser.add_argument("--state", default="", help="state.json from the last build (keeps serials steady)")
    parser.add_argument("--out", required=True, help="folder to write the files to")
    return build(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
