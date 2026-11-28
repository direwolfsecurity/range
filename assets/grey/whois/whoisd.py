#!/usr/bin/env python3
"""whoisd.py - the range's internet registry (a made-up ARIN): whois, RDAP and a lookup page.

Answers "who owns this address / AS number / domain?" from the range registry, so a student
gets the same answer here as from GeoIP and reverse DNS.

    port 43    whois    whois -h whois.lab 192.168.103.5      (or plain "whois 192.168.103.5"
                        once the range answers whois.arin.net, see README)
    port 80    RDAP     http://whois.lab/rdap/ip/192.168.103.5
               web      http://whois.lab/?q=192.168.103.5

What it can look up:
    an IPv4 address or network   192.168.103.5   192.168.103.0/24   NET-192-168-103-0-1
    an AS number                 AS64601   64601
    an organization              BSBB   Bluestem
    a domain                     shop.com   kestrel.lab   (asked from the registrar, nic.lab)

Run by hand (no root needed on high ports):
    python3 whoisd.py --conf whois.conf --whois-port 4343 --http-port 8080

When registry.csv or the exercise overlay changes on disk, the next query uses the new data.
No restart is needed: the range control server only writes the overlay (whois-apply).

Standard library only. Python 3.8 or newer.

License: GPL-3.0, Dire Wolf Security.
"""

import argparse
import datetime
import html
import ipaddress
import json
import os
import re
import shlex
import socket
import socketserver
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))

DEFAULTS = {
    "SERVER_NAME": "whois.lab",
    "REGISTRY_NAME": "Grey Internet Registry",
    "REGISTRY_FILE": "../../../network/registry/registry.csv",
    "OVERLAY_FILE": "/etc/direwolf-range/overlay.csv",
    "REGISTRAR_URL": "http://nic.lab",
    "REGISTRAR_NAME": "Range Registrar",
    "REG_DATE": "2026-11-13",
    "LISTEN": "0.0.0.0",
    "WHOIS_PORT": "43",
    "HTTP_PORT": "80",
}

# RIPE-style flags that take a value (the stock whois client sends "-V Md5.5.22" to some servers).
FLAGS_WITH_VALUE = {"-V", "-T", "-i", "-s", "-t", "-v", "-q", "-g"}
# ARIN-style query words: "n 1.2.3.4" (network), "a 64601" (AS), "o BSBB" (org), "d shop.com".
ARIN_TYPES = {"n": "ip", "r": "ip", "a": "asn", "o": "org", "e": "org", "z": "", "d": "domain"}

MAX_QUERY = 256


def read_conf(path):
    """Reads KEY="value" lines (the same file install.sh reads with bash)."""
    conf = dict(DEFAULTS)
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                words = shlex.split(value, comments=True)
                conf[key.strip()] = words[0] if words else ""
    registry_file = conf["REGISTRY_FILE"]
    if not os.path.isabs(registry_file):
        base = os.path.dirname(os.path.abspath(path)) if path else HERE
        registry_file = os.path.normpath(os.path.join(base, registry_file))
    conf["REGISTRY_FILE"] = registry_file
    return conf


def log(message):
    print(message, flush=True)


# ---------------------------------------------------------------------------
# The data: registry.csv + overlay, reloaded when either file changes
# ---------------------------------------------------------------------------

class Data:
    def __init__(self, conf):
        self.conf = conf
        sys.path.insert(0, os.path.dirname(conf["REGISTRY_FILE"]))
        import registry
        self.registry = registry
        self.lock = threading.Lock()
        self.stamp = None
        self.rows = []
        self.updated = {}
        self.checked = 0.0
        self.refresh(force=True)

    def files(self):
        out = [self.conf["REGISTRY_FILE"]]
        overlay = self.conf.get("OVERLAY_FILE", "")
        if overlay and os.path.exists(overlay) and os.path.getsize(overlay) > 0:
            out.append(overlay)
        return out

    def refresh(self, force=False):
        """Reloads if a file changed. A broken file keeps the last good data (and says so)."""
        with self.lock:
            now = time.time()
            if not force and now - self.checked < 2:
                return
            self.checked = now
            files = self.files()
            stamp = [(p, os.stat(p).st_mtime) for p in files]
            if stamp == self.stamp:
                return
            overlay = files[1] if len(files) > 1 else None
            rows, errors = self.registry.read_with_overlay(files[0], overlay)
            if errors:
                log("registry has %d problem(s), keeping the last good data: %s" % (len(errors), errors[0]))
                if not self.rows:
                    raise SystemExit("The registry has problems and nothing was loaded before. Fix it first.")
                self.stamp = stamp
                return
            self.rows = [r for r in rows if r.network.version == 4]
            self.updated = {"registry": day(os.stat(files[0]).st_mtime)}
            self.updated["overlay"] = day(os.stat(overlay).st_mtime) if overlay else self.updated["registry"]
            self.stamp = stamp
            log("loaded %d networks (%s)" % (len(self.rows), " + ".join(files)))

    # ---- lookups ----
    def by_address(self, address):
        return self.registry.lookup(self.rows, address)

    def by_network(self, network):
        for row in self.rows:
            if row.network == network:
                return row
        return self.by_address(str(network.network_address))

    def parent(self, row):
        """The next bigger registry network that holds this one, or None."""
        best = None
        for other in self.rows:
            if other is not row and other.network.prefixlen < row.network.prefixlen \
                    and row.network.subnet_of(other.network):
                if best is None or other.network.prefixlen > best.network.prefixlen:
                    best = other
        return best

    def by_asn(self, asn):
        return [r for r in self.rows if r.asn == asn]

    def org_rows(self, handle):
        return [r for r in self.rows if r.org_handle == handle]

    def find_orgs(self, text):
        """Org handles that match: the exact handle first, else names that contain the text."""
        text = text.lower()
        handles = []
        for row in self.rows:
            if row.org_handle.lower() == text and row.org_handle not in handles:
                handles.append(row.org_handle)
        if handles:
            return handles
        for row in self.rows:
            if (text in row.org.lower() or text == row.domain) and row.org_handle not in handles:
                handles.append(row.org_handle)
        return handles

    def updated_for(self, row):
        return self.updated["overlay" if row.source == "overlay" else "registry"]

    def reg_date(self, row):
        return self.updated["overlay"] if row.source == "overlay" else self.conf["REG_DATE"]


def day(mtime):
    return datetime.datetime.fromtimestamp(mtime, datetime.timezone.utc).strftime("%Y-%m-%d")


def net_handle(network):
    return "NET-%s-1" % str(network.network_address).replace(".", "-")


def net_name(row):
    return "%s-%s" % (row.as_name, str(row.network.network_address).replace(".", "-"))


def place(row):
    parts = [row.city, row.region_name or row.region, row.country_name]
    return ", ".join(p for p in parts if p)


# ---------------------------------------------------------------------------
# Understanding a query
# ---------------------------------------------------------------------------

def parse_query(text):
    """Turns what a whois client sent into (kind, value). kind: ip net asn org domain help bad."""
    words = text.strip().split()
    hint = ""
    clean = []
    skip = False
    for i, word in enumerate(words):
        if skip:
            skip = False
            continue
        if word.startswith("-") and len(word) > 1 and not word[1].isdigit():
            skip = word in FLAGS_WITH_VALUE
            continue
        if word in ("+", "!", "=", "~", "*") or word.lower() == "domain":
            continue
        if i == 0 and word.lower() in ARIN_TYPES and len(words) > 1:
            hint = ARIN_TYPES[word.lower()]
            continue
        clean.append(word.lstrip("!=~").rstrip("."))
    if not clean:
        return "help", ""
    value = " ".join(clean)
    low = value.lower()
    if low in ("help", "?"):
        return "help", ""
    try:
        return "ip", ipaddress.IPv4Address(value)
    except ValueError:
        pass
    if "/" in value:
        try:
            return "net", ipaddress.IPv4Network(value, strict=False)
        except ValueError:
            return "bad", value
    m = re.match(r"^net-(\d+)-(\d+)-(\d+)-(\d+)(-\d+)?$", low)
    if m:
        try:
            return "ip", ipaddress.IPv4Address(".".join(m.groups()[:4]))
        except ValueError:
            return "bad", value
    m = re.match(r"^as(\d+)$", low)
    if m or (value.isdigit() and hint in ("", "asn")):
        return "asn", int(m.group(1) if m else value)
    if hint == "org":
        return "org", value
    if "." in value and " " not in value and re.match(r"^[a-z0-9.-]+$", low):
        return "domain", low
    return "org", value


# ---------------------------------------------------------------------------
# whois text answers
# ---------------------------------------------------------------------------

def header(conf):
    return [
        "#",
        "# %s (%s) - whois for the Dire Wolf training range." % (conf["REGISTRY_NAME"], conf["SERVER_NAME"]),
        "# Made-up data: every owner, AS number and place here is invented for the range.",
        "# Web: http://%s/   RDAP: http://%s/rdap/" % (conf["SERVER_NAME"], conf["SERVER_NAME"]),
        "#",
        "",
    ]


def field(name, value):
    return "%-16s%s" % (name + ":", value)


def org_block(data, handle):
    rows = data.org_rows(handle)
    first = rows[0]
    base = "http://%s/rdap" % data.conf["SERVER_NAME"]
    return [
        field("OrgName", first.org),
        field("OrgId", first.org_handle),
        field("City", first.city),
        field("StateProv", first.region),
        field("PostalCode", first.postal),
        field("Country", first.country),
        field("RegDate", data.reg_date(first)),
        field("Updated", data.updated_for(first)),
        field("Ref", "%s/entity/%s" % (base, first.org_handle)),
        "",
        field("OrgAbuseHandle", "ABUSE-%s" % first.org_handle),
        field("OrgAbuseName", "Abuse Desk"),
        field("OrgAbuseEmail", "abuse@%s" % first.domain),
        field("OrgAbuseRef", "%s/entity/ABUSE-%s" % (base, first.org_handle)),
        "",
        field("OrgTechHandle", "NOC-%s" % first.org_handle),
        field("OrgTechName", "Network Operations"),
        field("OrgTechEmail", "noc@%s" % first.domain),
        field("OrgTechRef", "%s/entity/NOC-%s" % (base, first.org_handle)),
        "",
    ]


def net_block(data, row):
    net = row.network
    parent = data.parent(row)
    lines = [
        field("NetRange", "%s - %s" % (net.network_address, net.broadcast_address)),
        field("CIDR", str(net)),
        field("NetName", net_name(row)),
        field("NetHandle", net_handle(net)),
    ]
    if parent:
        lines.append(field("Parent", "%s (%s)" % (net_name(parent), net_handle(parent.network))))
        lines.append(field("NetType", "Reassigned"))
    else:
        lines.append(field("Parent", "()"))
        lines.append(field("NetType", "Direct Allocation"))
    lines += [
        field("OriginAS", "AS%d" % row.asn),
        field("Organization", "%s (%s)" % (row.org, row.org_handle)),
        field("Comment", "Location: %s" % place(row)),
        field("RegDate", data.reg_date(row)),
        field("Updated", data.updated_for(row)),
        field("Ref", "http://%s/rdap/ip/%s" % (data.conf["SERVER_NAME"], net.network_address)),
        "",
    ]
    return lines


def answer_ip(data, row, asked):
    if row is None:
        return ["No match found for n + %s." % asked, "",
                "# Only range networks are in this registry. Real internet addresses do not exist here.", ""]
    return net_block(data, row) + org_block(data, row.org_handle)


def answer_asn(data, asn):
    rows = data.by_asn(asn)
    if not rows:
        return ["No match found for a + AS%d." % asn, ""]
    first = rows[0]
    lines = [
        field("ASNumber", str(asn)),
        field("ASName", first.as_name),
        field("ASHandle", "AS%d" % asn),
        field("Organization", "%s (%s)" % (first.org, first.org_handle)),
        field("RegDate", data.reg_date(first)),
        field("Updated", data.updated_for(first)),
        field("Ref", "http://%s/rdap/autnum/%d" % (data.conf["SERVER_NAME"], asn)),
    ]
    for row in rows:
        lines.append(field("Comment", "Announces %s (%s)" % (row.network, place(row))))
    return lines + [""] + org_block(data, first.org_handle)


def answer_org(data, text):
    handles = data.find_orgs(text)
    if not handles:
        return ["No match found for o + %s." % text, ""]
    lines = []
    for handle in handles:
        lines += org_block(data, handle)
        rows = data.org_rows(handle)
        asns = sorted({r.asn for r in rows})
        lines.append(field("Comment", "AS numbers: %s" % ", ".join("AS%d" % a for a in asns)))
        for row in rows:
            lines.append(field("Comment", "Network %s (%s)" % (row.network, place(row))))
        lines.append("")
    return lines


# ---------------------------------------------------------------------------
# Domains: the registrar (nic.lab) holds them, so we ask it, like a thin registry does
# ---------------------------------------------------------------------------

def registrar_lookup(conf, domain):
    """Returns (found, list of (key, value)) or raises OSError when the registrar can't be reached."""
    url = conf["REGISTRAR_URL"].rstrip("/") + "/whois.php?" + urllib.parse.urlencode({"q": domain})
    with urllib.request.urlopen(url, timeout=4) as reply:
        page = reply.read(200000).decode("utf-8", "replace")
    m = re.search(r'<pre class="whois">(.*?)</pre>', page, re.S)
    if not m:
        return False, []
    pairs = []
    for line in html.unescape(m.group(1)).splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            pairs.append((key.strip(), value.strip()))
    return True, pairs


def answer_domain(data, domain):
    conf = data.conf
    try:
        found, pairs = registrar_lookup(conf, domain)
    except (OSError, ValueError) as e:
        return ["The registrar (%s) did not answer: %s" % (conf["REGISTRAR_URL"], e),
                "Try its web page: %s/whois.php?q=%s" % (conf["REGISTRAR_URL"].rstrip("/"), domain), ""]
    if not found:
        lines = ['No match for "%s".' % domain.upper(), ""]
        handles = data.find_orgs(domain)
        if handles:
            lines.append("# %s is the domain of %s in the address registry. Try: whois %s"
                         % (domain, data.org_rows(handles[0])[0].org, handles[0]))
            lines.append("")
        return lines
    lines = []
    for key, value in pairs:
        lines.append("   %s: %s" % (key, value))
    lines += [
        "   Registrar URL: %s/" % conf["REGISTRAR_URL"].rstrip("/"),
        "",
        ">>> Last update of whois database: %s <<<" % time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "",
    ]
    return lines


def help_text(conf):
    name = conf["SERVER_NAME"]
    return [
        "Ask for one of these:",
        "  an IPv4 address or network   whois -h %s 192.168.103.5      whois -h %s 192.168.103.0/24" % (name, name),
        "  an AS number                 whois -h %s AS64601" % name,
        "  an organization              whois -h %s BSBB               whois -h %s Bluestem" % (name, name),
        "  a domain                     whois -h %s shop.com" % name,
        "Web page: http://%s/   RDAP (JSON): http://%s/rdap/ip/192.168.103.5" % (name, name),
        "",
    ]


def whois_answer(data, text):
    data.refresh()
    kind, value = parse_query(text)
    lines = header(data.conf)
    if kind == "help":
        lines += help_text(data.conf)
    elif kind == "ip":
        lines += answer_ip(data, data.by_address(str(value)), value)
    elif kind == "net":
        lines += answer_ip(data, data.by_network(value), value)
    elif kind == "asn":
        lines += answer_asn(data, value)
    elif kind == "domain":
        lines += answer_domain(data, value)
    elif kind == "org":
        lines += answer_org(data, value)
    else:
        lines += ["Not understood: %s" % value, ""] + help_text(data.conf)
    return kind, "\r\n".join(lines) + "\r\n"


# ---------------------------------------------------------------------------
# RDAP (RFC 9083): the same answers as JSON
# ---------------------------------------------------------------------------

def rdap_base(conf):
    return "http://%s/rdap" % conf["SERVER_NAME"]


def rdap_notices(conf):
    return [{"title": "Training range data",
             "description": ["%s on the Dire Wolf training range. Every owner, AS number and place here is made up."
                             % conf["REGISTRY_NAME"]]}]


def rdap_events(data, row):
    return [{"eventAction": "registration", "eventDate": data.reg_date(row) + "T00:00:00Z"},
            {"eventAction": "last changed", "eventDate": data.updated_for(row) + "T00:00:00Z"}]


def rdap_entity(data, handle, roles=None):
    rows = data.org_rows(handle)
    if not rows:
        return None
    first = rows[0]
    vcard = ["vcard", [
        ["version", {}, "text", "4.0"],
        ["fn", {}, "text", first.org],
        ["kind", {}, "text", "org"],
        ["adr", {"label": place(first)}, "text", ["", "", "", first.city, first.region, first.postal, first.country]],
    ]]
    contacts = []
    for prefix, name, mailbox, role in (("ABUSE", "Abuse Desk", "abuse", "abuse"),
                                        ("NOC", "Network Operations", "noc", "technical")):
        contacts.append({
            "objectClassName": "entity",
            "handle": "%s-%s" % (prefix, handle),
            "roles": [role],
            "vcardArray": ["vcard", [["version", {}, "text", "4.0"], ["fn", {}, "text", name],
                                     ["kind", {}, "text", "group"],
                                     ["email", {}, "text", "%s@%s" % (mailbox, first.domain)]]],
        })
    return {
        "objectClassName": "entity",
        "handle": handle,
        "roles": roles or ["registrant"],
        "vcardArray": vcard,
        "entities": contacts,
        "events": rdap_events(data, first),
        "links": [{"rel": "self", "href": "%s/entity/%s" % (rdap_base(data.conf), handle),
                   "value": "%s/entity/%s" % (rdap_base(data.conf), handle), "type": "application/rdap+json"}],
        "port43": data.conf["SERVER_NAME"],
    }


def rdap_network(data, row):
    net = row.network
    parent = data.parent(row)
    out = {
        "objectClassName": "ip network",
        "handle": net_handle(net),
        "startAddress": str(net.network_address),
        "endAddress": str(net.broadcast_address),
        "ipVersion": "v4",
        "name": net_name(row),
        "type": "REASSIGNED" if parent else "DIRECT ALLOCATION",
        "country": row.country,
        "cidr0_cidrs": [{"v4prefix": str(net.network_address), "length": net.prefixlen}],
        "remarks": [{"title": "Location", "description": [place(row)]},
                    {"title": "Origin AS", "description": ["AS%d" % row.asn]}],
        "entities": [rdap_entity(data, row.org_handle)],
        "events": rdap_events(data, row),
        "links": [{"rel": "self", "href": "%s/ip/%s" % (rdap_base(data.conf), net),
                   "value": "%s/ip/%s" % (rdap_base(data.conf), net), "type": "application/rdap+json"}],
        "port43": data.conf["SERVER_NAME"],
        "status": ["active"],
    }
    if parent:
        out["parentHandle"] = net_handle(parent.network)
    return out


def rdap_autnum(data, asn):
    rows = data.by_asn(asn)
    if not rows:
        return None
    first = rows[0]
    return {
        "objectClassName": "autnum",
        "handle": "AS%d" % asn,
        "startAutnum": asn,
        "endAutnum": asn,
        "name": first.as_name,
        "type": "DIRECT ALLOCATION",
        "country": first.country,
        "remarks": [{"title": "Networks", "description": [str(r.network) for r in rows]}],
        "entities": [rdap_entity(data, first.org_handle)],
        "events": rdap_events(data, first),
        "links": [{"rel": "self", "href": "%s/autnum/%d" % (rdap_base(data.conf), asn),
                   "value": "%s/autnum/%d" % (rdap_base(data.conf), asn), "type": "application/rdap+json"}],
        "port43": data.conf["SERVER_NAME"],
        "status": ["active"],
    }


def rdap_domain(data, domain):
    """Builds a domain object from the registrar's answer. Raises OSError if it can't be reached."""
    found, pairs = registrar_lookup(data.conf, domain)
    if not found:
        return None
    values = {}
    servers = []
    for key, value in pairs:
        if key == "Name Server":
            servers.append(value.split()[0].lower())
        else:
            values[key] = value
    events = []
    for key, action in (("Created", "registration"), ("Updated", "last changed")):
        if values.get(key):
            events.append({"eventAction": action, "eventDate": values[key].replace(" UTC", "").replace(" ", "T") + "Z"})
    registrant = ["vcard", [["version", {}, "text", "4.0"], ["fn", {}, "text", values.get("Registrant", "")]]]
    if values.get("Organization", "-") != "-":
        registrant[1].append(["org", {}, "text", values["Organization"]])
    if values.get("Email", "-") != "-":
        registrant[1].append(["email", {}, "text", values["Email"]])
    return {
        "objectClassName": "domain",
        "ldhName": domain,
        "handle": domain.upper(),
        "status": [values.get("Status", "active")],
        "nameservers": [{"objectClassName": "nameserver", "ldhName": s} for s in servers],
        "entities": [
            {"objectClassName": "entity", "roles": ["registrar"],
             "vcardArray": ["vcard", [["version", {}, "text", "4.0"], ["fn", {}, "text", values.get("Registrar", "")]]]},
            {"objectClassName": "entity", "roles": ["registrant"], "vcardArray": registrant},
        ],
        "events": events,
        "links": [{"rel": "self", "href": "%s/domain/%s" % (rdap_base(data.conf), domain),
                   "value": "%s/domain/%s" % (rdap_base(data.conf), domain), "type": "application/rdap+json"}],
        "port43": data.conf["SERVER_NAME"],
    }


def rdap_answer(data, path):
    """Returns (HTTP status, JSON object) for a path under /rdap/."""
    data.refresh()
    parts = [urllib.parse.unquote(p) for p in path.strip("/").split("/") if p]
    if not parts or parts[0] == "help":
        return 200, {"notices": rdap_notices(data.conf) + [{"title": "Lookups", "description": [
            "/rdap/ip/ADDRESS or /rdap/ip/ADDRESS/LENGTH", "/rdap/autnum/NUMBER",
            "/rdap/entity/HANDLE", "/rdap/domain/NAME"]}]}
    kind, rest = parts[0], "/".join(parts[1:])
    obj = None
    try:
        if kind == "ip" and rest:
            if "/" in rest:
                obj = data.by_network(ipaddress.IPv4Network(rest, strict=False))
            else:
                obj = data.by_address(str(ipaddress.IPv4Address(rest)))
            obj = rdap_network(data, obj) if obj else None
        elif kind == "autnum" and rest.isdigit():
            obj = rdap_autnum(data, int(rest))
        elif kind == "entity" and rest:
            handle = rest.upper()
            for prefix in ("ABUSE-", "NOC-"):
                if handle.startswith(prefix):
                    handle = handle[len(prefix):]
            obj = rdap_entity(data, handle)
        elif kind == "domain" and rest:
            obj = rdap_domain(data, rest.lower().rstrip("."))
        else:
            return 400, {"errorCode": 400, "title": "Bad request", "description": ["Try /rdap/help"]}
    except ValueError:
        return 400, {"errorCode": 400, "title": "Bad request", "description": ["%s is not valid here" % rest]}
    except OSError as e:
        return 502, {"errorCode": 502, "title": "The registrar did not answer", "description": [str(e)]}
    if obj is None:
        return 404, {"errorCode": 404, "title": "Not found", "description": ["Nothing in the registry for %s" % rest]}
    obj["rdapConformance"] = ["rdap_level_0", "cidr0"]
    obj["notices"] = rdap_notices(data.conf)
    return 200, obj


# ---------------------------------------------------------------------------
# Web page
# ---------------------------------------------------------------------------

PAGE = """<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
body{{font-family:system-ui,sans-serif;max-width:52rem;margin:2rem auto;padding:0 1rem;line-height:1.5;background:#fff;color:#111}}
form{{display:flex;gap:.5rem;margin:1rem 0}} input{{flex:1;font-size:1rem;padding:.4rem}} button{{font-size:1rem;padding:.4rem 1rem}}
pre{{background:#f4f4f4;padding:1rem;overflow-x:auto;font-size:.9rem}} code{{background:#f2f2f2;padding:0 .3rem}}
.small{{color:#555;font-size:.9rem}}
</style></head>
<body>
<h1>{title}</h1>
<p>Who owns an address, an AS number or a domain on the range? Everything here is made up for training.</p>
<p>Your address: <a href="/?q={visitor}"><code>{visitor}</code></a></p>
<form method="get" action="/"><input name="q" value="{q}" placeholder="192.168.103.5, AS64601, Bluestem, shop.com" autofocus>
<button>Look up</button></form>
{result}
<p class="small">The same answers from the command line: <code>whois -h {server} 192.168.103.5</code>.
As JSON (RDAP): <a href="/rdap/help"><code>http://{server}/rdap/</code></a>.</p>
</body>
</html>
"""


def page(data, query, visitor):
    result = ""
    if query:
        kind, text = whois_answer(data, query)
        result = "<pre>%s</pre>" % html.escape(text.replace("\r\n", "\n"))
        rdap = {"ip": "ip", "net": "ip", "asn": "autnum", "domain": "domain"}.get(kind)
        if rdap:
            value = query.strip()
            if kind == "asn":
                value = re.sub(r"(?i)^as", "", value)
            result += '<p class="small"><a href="/rdap/%s/%s">This answer as RDAP JSON</a></p>' % (
                rdap, urllib.parse.quote(value, safe="/"))
    return PAGE.format(title=html.escape("%s whois" % data.conf["REGISTRY_NAME"]), visitor=html.escape(visitor),
                       q=html.escape(query), result=result, server=html.escape(data.conf["SERVER_NAME"]))


# ---------------------------------------------------------------------------
# The two servers
# ---------------------------------------------------------------------------

class WhoisHandler(socketserver.StreamRequestHandler):
    timeout = 10

    def handle(self):
        try:
            raw = self.rfile.readline(MAX_QUERY + 1)
        except (socket.timeout, OSError):
            return
        text = raw.decode("utf-8", "replace").strip()
        if len(raw) > MAX_QUERY:
            answer = "Query too long.\r\n"
        else:
            _, answer = whois_answer(self.server.data, text)
        log("whois %s: %s" % (self.client_address[0], text[:100]))
        try:
            self.wfile.write(answer.encode("utf-8"))
        except OSError:
            pass


class WhoisServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


class WebHandler(BaseHTTPRequestHandler):
    server_version = "range-whois"
    sys_version = ""

    def send(self, status, body, content_type):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        data = self.server.data
        if url.path.startswith("/rdap"):
            status, obj = rdap_answer(data, url.path[len("/rdap"):])
            self.send(status, json.dumps(obj, indent=1) + "\n", "application/rdap+json")
        elif url.path in ("/", "/index.html"):
            query = urllib.parse.parse_qs(url.query).get("q", [""])[0][:MAX_QUERY]
            self.send(200, page(data, query, self.client_address[0]), "text/html; charset=utf-8")
        elif url.path == "/whois.txt":
            query = urllib.parse.parse_qs(url.query).get("q", [""])[0][:MAX_QUERY]
            self.send(200, whois_answer(data, query)[1], "text/plain; charset=utf-8")
        else:
            self.send(404, "Not found. Try / or /rdap/help\n", "text/plain; charset=utf-8")

    do_HEAD = do_GET

    def log_message(self, fmt, *args):
        log("web %s: %s" % (self.client_address[0], fmt % args))


class WebServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main(argv=None):
    parser = argparse.ArgumentParser(description="Range whois, RDAP and lookup page")
    parser.add_argument("--conf", default=os.path.join(HERE, "whois.conf"))
    parser.add_argument("--whois-port", type=int, help="overrides WHOIS_PORT")
    parser.add_argument("--http-port", type=int, help="overrides HTTP_PORT (0 = no web server)")
    parser.add_argument("--query", help="answer one whois query on the screen and stop")
    args = parser.parse_args(argv)
    conf = read_conf(args.conf)
    data = Data(conf)
    if args.query is not None:
        print(whois_answer(data, args.query)[1].replace("\r\n", "\n"), end="")
        return 0
    whois_port = args.whois_port if args.whois_port is not None else int(conf["WHOIS_PORT"])
    http_port = args.http_port if args.http_port is not None else int(conf["HTTP_PORT"])
    whois = WhoisServer((conf["LISTEN"], whois_port), WhoisHandler)
    whois.data = data
    threads = [threading.Thread(target=whois.serve_forever, daemon=True)]
    if http_port:
        web = WebServer((conf["LISTEN"], http_port), WebHandler)
        web.data = data
        threads.append(threading.Thread(target=web.serve_forever, daemon=True))
    for t in threads:
        t.start()
    log("whois on port %d, web on port %s, registry %s" % (whois_port, http_port or "off", conf["REGISTRY_FILE"]))
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
