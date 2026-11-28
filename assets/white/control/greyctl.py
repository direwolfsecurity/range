#!/usr/bin/env python3
"""greyctl - control the range's fake internet (the grey cell) from one place.

The same commands work by hand (teaching) and from ForgeRange through the API (exercises),
because greyctl-api.py calls the functions in this file.

What it changes:
  * exercise TEAMS: a team takes over one or more seat networks (or a free network) and gets
    its own owner name, AS number, place on the map and domain. GeoIP, whois and DNS then
    all give the same answer for the team's addresses.
  * exercise DOMAINS: extra domains on the registrar (a look-alike phishing domain, say).
  * SNAPSHOTS of the whole fake internet: teams, domains, and every domain on the registrar,
    students' own registrations included. Restore one and the internet is back to that moment.
  * RESET: restore the snapshot called "zero", the clean core you saved once after building it.

registry.csv in git is never changed. Teams live in an overlay (same columns) that each
grey server lays over registry.csv when it rebuilds.

Usage (run as the greyctl user; /usr/local/bin/greyctl does that for you with sudo):
  greyctl status
  greyctl lookup 192.168.103.5
  greyctl team list
  greyctl team add NAME --network 192.168.103.0/24 --org "Kestrel Freight" --domain kestrel.lab
                   [--network ...] [--city Denver] [--a IP | --ns HOST[=GLUE] [--ns ...]] [--exercise TAG]
  greyctl team del NAME
  greyctl domain list
  greyctl domain add NAME (--a IP | --ns HOST[=GLUE] [--ns ...]) [--exercise TAG]
  greyctl domain del NAME
  greyctl exercise clear TAG          remove every team and domain of one exercise
  greyctl apply                       send everything to every grey server again
  greyctl snapshot list
  greyctl snapshot save NAME [--note TEXT] [--replace]
  greyctl snapshot restore NAME
  greyctl snapshot delete NAME
  greyctl reset [--yes]               restore "zero": back to the clean core
  greyctl token add NAME read|exercise|admin      make an API token (shown once)
  greyctl token list | token del NAME

Standard library only. Python 3.10 or newer (Ubuntu 24.04 has 3.12).

License: GPL-3.0, Dire Wolf Security.
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import fcntl
import hashlib
import io
import ipaddress
import json
import os
import re
import secrets
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CONF_FILE = os.environ.get("GREYCTL_CONF", "/etc/greyctl/control.conf")

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")          # team, exercise and snapshot names
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$")
ZERO = "zero"                                                # the clean-core snapshot
SCOPES = ("read", "exercise", "admin")                       # each scope can do what the one before can


class GreyError(Exception):
    """A problem to show the user. status is the HTTP code the API sends back."""

    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

DEFAULTS = {
    "STATE_DIR": "/var/lib/greyctl",
    "REGISTRY_DIR": "/opt/greyctl/registry",
    "TOKENS_FILE": "/var/lib/greyctl/tokens",
    "SSH_KEY": "/var/lib/greyctl/.ssh/id_ed25519",
    "REGISTRAR": "",
    "GEOIP": "",
    "WHOIS": "",
    "DNS": "",
    "TEAM_ASN_FIRST": "65000",
    "TEAM_ASN_LAST": "65499",
}

# Grey servers that rebuild from the overlay, and the one command each one allows.
OVERLAY_TARGETS = {"GEOIP": "geoip-apply", "WHOIS": "whois-apply", "DNS": "dns-apply"}


def read_conf(path=None):
    """Reads KEY="value" lines (the same file install.sh reads with bash)."""
    conf = dict(DEFAULTS)
    path = path or CONF_FILE
    if not os.path.exists(path):
        return conf
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            words = shlex.split(value, comments=True)
            conf[key.strip()] = words[0] if words else ""
    return conf


# ---------------------------------------------------------------------------
# The registry (registry.py is copied next to registry.csv by install.sh)
# ---------------------------------------------------------------------------

def registry_module(conf):
    folder = conf["REGISTRY_DIR"]
    if folder not in sys.path:
        sys.path.insert(0, folder)
    try:
        import registry
    except ImportError:
        raise GreyError("registry.py is missing from %s. Run install.sh --go again." % folder, 500)
    return registry


def base_rows(conf):
    registry = registry_module(conf)
    rows, errors = registry.read(os.path.join(conf["REGISTRY_DIR"], "registry.csv"))
    if errors:
        raise GreyError("registry.csv has problems: " + "; ".join(errors[:3]), 500)
    return rows


# ---------------------------------------------------------------------------
# State: teams and domains, kept in one JSON file
# ---------------------------------------------------------------------------

def empty_state():
    return {"format": "greyctl-state-1", "teams": {}, "domains": {}}


def state_path(conf):
    return os.path.join(conf["STATE_DIR"], "state.json")


def load_state(conf):
    path = state_path(conf)
    if not os.path.exists(path):
        return empty_state()
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save_json(path, data):
    """Writes a file in one step: a crash never leaves half a file."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def save_state(conf, state):
    state["changed_at"] = now()
    save_json(state_path(conf), state)


@contextlib.contextmanager
def locked(conf):
    """One change at a time, whether it comes from the command line or the API."""
    os.makedirs(conf["STATE_DIR"], exist_ok=True)
    with open(os.path.join(conf["STATE_DIR"], "lock"), "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def log(conf, message):
    """Every change goes to the state folder's log, and to syslog (which can forward to syslog.lab)."""
    line = "%s %s %s\n" % (now(), os.environ.get("GREYCTL_CLIENT", "cli"), message)
    try:
        with open(os.path.join(conf["STATE_DIR"], "changes.log"), "a", encoding="utf-8") as f:
            f.write(line)
    except OSError:
        pass
    try:
        import syslog
        syslog.openlog("greyctl")
        syslog.syslog(syslog.LOG_NOTICE, line.strip())
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Talking to the grey servers
# ---------------------------------------------------------------------------

def run_target(conf, key, command, words, stdin_text=None):
    """Runs one allowed request on a grey server. Returns its output.

    The setting (for example GEOIP) says how to reach it:
      ssh:root@172.16.11.50   over SSH with greyctl's key (the key there can run one command only)
      cmd:/path/to/program    run a program on this machine (an all-in-one test box)
      (empty)                 that server is not built yet: skipped
    """
    where = conf.get(key, "")
    if not where:
        return None
    if where.startswith("ssh:"):
        argv = ["ssh", "-i", conf["SSH_KEY"], "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "StrictHostKeyChecking=accept-new", where[4:], " ".join(words)]
    elif where.startswith("cmd:"):
        argv = [where[4:]] + list(words)
    else:
        raise GreyError("%s=%s in control.conf: use ssh:user@host or cmd:/path" % (key, where), 500)
    try:
        done = subprocess.run(argv, input=stdin_text, capture_output=True, text=True, timeout=600)
    except subprocess.TimeoutExpired:
        raise GreyError("%s (%s) took more than 10 minutes" % (key.lower(), command), 502)
    except OSError as e:
        raise GreyError("%s: could not run %s: %s" % (key.lower(), argv[0], e), 502)
    if done.returncode != 0:
        detail = (done.stderr.strip() or done.stdout.strip() or "no output").splitlines()[-3:]
        raise GreyError("%s refused or failed: %s" % (key.lower(), " | ".join(detail)), 502)
    return done.stdout


def registrar(conf, *words, stdin_text=None):
    return run_target(conf, "REGISTRAR", "registrar-remote", words, stdin_text)


def overlay_csv(conf, state):
    """The overlay file every rebuilding server gets: registry columns, one row per team network."""
    registry = registry_module(conf)
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(registry.COLUMNS)
    for name in sorted(state["teams"]):
        for row in team_rows(state["teams"][name]):
            writer.writerow([row[col] for col in registry.COLUMNS])
    return out.getvalue()


def push_overlay(conf, state):
    """Sends the overlay to GeoIP (and whois and DNS once they exist). Returns lines for the user."""
    text = overlay_csv(conf, state)
    report = []
    for key, command in OVERLAY_TARGETS.items():
        if not conf.get(key):
            continue
        try:
            out = run_target(conf, key, command, ["overlay"], text)
        except GreyError as e:
            raise GreyError("%s. The change is saved here; fix that server, then run: greyctl apply" % e, e.status)
        lines = (out or "").strip().splitlines()
        report.append("%s: %s" % (key.lower(), lines[-1] if lines else "ok"))
    return report


# ---------------------------------------------------------------------------
# Teams
# ---------------------------------------------------------------------------

def team_rows(team):
    """A team as registry rows (one per network)."""
    rows = []
    for net in team["networks"]:
        row = dict(team["place"])
        row.update({
            "network": net,
            "org_handle": team["org_handle"],
            "org": team["org"],
            "asn": str(team["asn"]),
            "as_name": team["as_name"],
            "domain": team["domain"],
            "use": "Exercise %s: team %s" % (team["exercise"], team["name"]),
        })
        rows.append(row)
    return rows


PLACE_COLUMNS = ("country", "region", "region_name", "city", "postal", "latitude", "longitude",
                 "accuracy_km", "time_zone")


def find_place(rows, city):
    """A place from any registry row in that city (Denver, Tokyo ...), so no one types coordinates."""
    for row in rows:
        if row.city.lower() == city.lower():
            return {col: row.raw[col] for col in PLACE_COLUMNS}
    cities = sorted({row.city for row in rows})
    raise GreyError("no registry row is in %s. Cities you can use: %s" % (city, ", ".join(cities)))


def parse_ns(values):
    """--ns host or --ns host=glue  ->  [(host, glue), ...] (at most two)."""
    result = []
    for value in values or []:
        host, _, glue = value.partition("=")
        result.append((host.strip().lower().rstrip("."), glue.strip()))
    if len(result) > 2:
        raise GreyError("at most two name servers")
    return result


def dns_words(name, a=None, ns=None):
    """The registrar request for a domain: add-a NAME IP, or add-ns NAME NS1 [GLUE1] [NS2] [GLUE2]."""
    if a and ns:
        raise GreyError("give --a or --ns, not both")
    if a:
        ipaddress.ip_address(a)
        return ["add-a", name, a]
    if ns:
        words = ["add-ns", name]
        for host, glue in parse_ns(ns):
            if not DOMAIN_RE.match(host):
                raise GreyError("name server %s is not a valid name" % host)
            words.append(host)
            if glue:
                ipaddress.ip_address(glue)
                words.append(glue)
        return words
    return None


def check_name(kind, name):
    if not NAME_RE.match(name or ""):
        raise GreyError("%s name '%s': use lower-case letters, digits and -, up to 32" % (kind, name))


def check_overlay(conf, state):
    """The whole overlay must fit registry.csv. registry.py has the rules."""
    registry = registry_module(conf)
    base = base_rows(conf)
    extra = []
    for name in sorted(state["teams"]):
        for i, raw in enumerate(team_rows(state["teams"][name])):
            problems = registry.check_raw(raw)
            if problems:
                raise GreyError("team %s: %s" % (name, "; ".join(problems)))
            extra.append(registry.Row(i + 1, raw, "team %s" % name))
    merged, errors = registry.merge(base, extra)
    if errors:
        raise GreyError("; ".join(errors[:4]), 409)
    return merged


def next_asn(conf, state):
    first, last = int(conf["TEAM_ASN_FIRST"]), int(conf["TEAM_ASN_LAST"])
    used = {t["asn"] for t in state["teams"].values()}
    for asn in range(first, last + 1):
        if asn not in used:
            return asn
    raise GreyError("no free team ASN left in %d-%d" % (first, last), 409)


def team_add(conf, name, networks, org, domain, city=None, a=None, ns=None, exercise="class"):
    check_name("team", name)
    check_name("exercise", exercise)
    domain = (domain or "").lower().rstrip(".")
    if not DOMAIN_RE.match(domain):
        raise GreyError("domain '%s' is not a valid domain name" % domain)
    if not org or len(org) > 64:
        raise GreyError("give the team's made-up owner name with --org (up to 64 characters)")
    if not networks:
        raise GreyError("give at least one --network")
    nets = []
    for net in networks:
        try:
            nets.append(str(ipaddress.ip_network(net, strict=True)))
        except ValueError as e:
            raise GreyError("network %s: %s" % (net, e))
    words = dns_words(domain, a, ns)

    with locked(conf):
        state = load_state(conf)
        if name in state["teams"]:
            raise GreyError("team %s already exists (team del %s first)" % (name, name), 409)
        for other in state["teams"].values():
            if other["domain"] == domain:
                raise GreyError("team %s already uses %s" % (other["name"], domain), 409)
            for net in nets:
                if net in other["networks"]:
                    raise GreyError("%s already belongs to team %s" % (net, other["name"]), 409)
        rows = base_rows(conf)
        if city:
            place = find_place(rows, city)
        else:
            seat = next((r for r in rows if str(r.network) == nets[0]), None)
            if seat is None:
                raise GreyError("%s is not a seat network, so say where the team is with --city" % nets[0])
            place = {col: seat.raw[col] for col in PLACE_COLUMNS}
        team = {
            "name": name, "exercise": exercise, "networks": nets, "org": org,
            "org_handle": "T-" + name.upper(), "asn": next_asn(conf, state),
            "as_name": "TEAM-" + name.upper(), "domain": domain, "place": place,
            "dns": words, "created_at": now(),
        }
        state["teams"][name] = team
        check_overlay(conf, state)              # nothing has changed anywhere yet
        if words:
            registrar(conf, *(words + [exercise]))
        save_state(conf, state)
        log(conf, "team add %s %s %s %s" % (name, ",".join(nets), domain, exercise))
        report = push_overlay(conf, state)
    return team, report


def team_del(conf, name):
    with locked(conf):
        state = load_state(conf)
        team = state["teams"].get(name)
        if team is None:
            raise GreyError("no team called %s" % name, 404)
        if team.get("dns") and conf.get("REGISTRAR"):
            try:
                registrar(conf, "del", team["domain"])
            except GreyError as e:
                raise GreyError("could not delete %s on the registrar, team kept: %s" % (team["domain"], e), 502)
        del state["teams"][name]
        save_state(conf, state)
        log(conf, "team del %s" % name)
        report = push_overlay(conf, state)
    return report


# ---------------------------------------------------------------------------
# Extra domains
# ---------------------------------------------------------------------------

def domain_add(conf, name, a=None, ns=None, exercise="class"):
    check_name("exercise", exercise)
    name = (name or "").lower().rstrip(".")
    if not DOMAIN_RE.match(name):
        raise GreyError("'%s' is not a valid domain name" % name)
    words = dns_words(name, a, ns)
    if not words:
        raise GreyError("give --a IP or --ns HOST[=GLUE]")
    if not conf.get("REGISTRAR"):
        raise GreyError("REGISTRAR is not set in control.conf", 500)
    with locked(conf):
        state = load_state(conf)
        if name in state["domains"]:
            raise GreyError("%s already exists" % name, 409)
        registrar(conf, *(words + [exercise]))
        state["domains"][name] = {"name": name, "exercise": exercise, "dns": words, "created_at": now()}
        save_state(conf, state)
        log(conf, "domain add %s %s" % (name, exercise))
    return state["domains"][name]


def domain_del(conf, name):
    name = (name or "").lower().rstrip(".")
    with locked(conf):
        state = load_state(conf)
        if name not in state["domains"]:
            raise GreyError("%s was not added by greyctl (use the registrar's admin page for others)" % name, 404)
        registrar(conf, "del", name)
        del state["domains"][name]
        save_state(conf, state)
        log(conf, "domain del %s" % name)


def exercise_clear(conf, tag):
    """Removes every team and domain of one exercise."""
    check_name("exercise", tag)
    with locked(conf):
        state = load_state(conf)
        gone = []
        for kind in ("teams", "domains"):
            for key, item in list(state[kind].items()):
                if item["exercise"] != tag:
                    continue
                domain = item["domain"] if kind == "teams" else item["name"]
                if item.get("dns") and conf.get("REGISTRAR"):
                    registrar(conf, "del", domain)
                del state[kind][key]
                save_state(conf, state)        # saved after each one, so a failure loses nothing
                gone.append(key)
        log(conf, "exercise clear %s: %s" % (tag, " ".join(gone) or "nothing"))
        report = push_overlay(conf, state)
    return gone, report


def apply_all(conf):
    with locked(conf):
        state = load_state(conf)
        check_overlay(conf, state)
        report = []
        if conf.get("REGISTRAR"):
            registrar(conf, "apply")
            report.append("registrar: published")
        report += push_overlay(conf, state)
        log(conf, "apply")
    return report


# ---------------------------------------------------------------------------
# Snapshots and reset
# ---------------------------------------------------------------------------

def snapshot_dir(conf):
    path = os.path.join(conf["STATE_DIR"], "snapshots")
    os.makedirs(path, exist_ok=True)
    return path


def snapshot_path(conf, name):
    check_name("snapshot", name)
    return os.path.join(snapshot_dir(conf), name + ".json")


def snapshot_list(conf):
    result = []
    for file in sorted(os.listdir(snapshot_dir(conf))):
        if not file.endswith(".json"):
            continue
        with open(os.path.join(snapshot_dir(conf), file), encoding="utf-8") as f:
            snap = json.load(f)
        domains = len((snap.get("registrar") or {}).get("domains", []))
        result.append({"name": snap["name"], "saved_at": snap["saved_at"], "note": snap.get("note", ""),
                       "teams": len(snap["state"]["teams"]), "registrar_domains": domains})
    return result


def snapshot_save(conf, name, note="", replace=False):
    path = snapshot_path(conf, name)
    with locked(conf):
        if os.path.exists(path) and not replace:
            raise GreyError("snapshot %s already exists (add --replace to overwrite it)" % name, 409)
        exported = None
        if conf.get("REGISTRAR"):
            exported = json.loads(registrar(conf, "export"))
        snap = {"format": "greyctl-snapshot-1", "name": name, "saved_at": now(), "note": note,
                "state": load_state(conf), "registrar": exported}
        save_json(path, snap)
        os.chmod(path, 0o600)
        log(conf, "snapshot save %s" % name)
    return snap


def snapshot_restore(conf, name):
    """Puts the whole fake internet back the way it was when the snapshot was saved."""
    path = snapshot_path(conf, name)
    if not os.path.exists(path):
        if name == ZERO:
            raise GreyError("there is no 'zero' snapshot yet. Build the core, check it, then: greyctl snapshot save zero", 404)
        raise GreyError("no snapshot called %s" % name, 404)
    with open(path, encoding="utf-8") as f:
        snap = json.load(f)
    with locked(conf):
        state = snap["state"]
        check_overlay(conf, state)                 # registry.csv may have changed since
        report = []
        if conf.get("REGISTRAR") and snap.get("registrar") is not None:
            registrar(conf, "import", stdin_text=json.dumps(snap["registrar"]))
            report.append("registrar: %d domains restored" % len(snap["registrar"].get("domains", [])))
        save_state(conf, state)
        report += push_overlay(conf, state)
        log(conf, "snapshot restore %s" % name)
    return report


def snapshot_delete(conf, name, force=False):
    path = snapshot_path(conf, name)
    if name == ZERO and not force:
        raise GreyError("'zero' is the clean core; it can only be replaced (snapshot save zero --replace)", 403)
    if not os.path.exists(path):
        raise GreyError("no snapshot called %s" % name, 404)
    os.remove(path)
    log(conf, "snapshot delete %s" % name)


# ---------------------------------------------------------------------------
# Lookups and status
# ---------------------------------------------------------------------------

def lookup(conf, address):
    try:
        ipaddress.ip_address(address)
    except ValueError:
        raise GreyError("%s is not an IP address" % address)
    registry = registry_module(conf)
    merged = check_overlay(conf, load_state(conf))
    row = registry.lookup(merged, address)
    if row is None:
        raise GreyError("%s is not in the registry" % address, 404)
    answer = {col: row.raw[col] for col in registry.COLUMNS}
    answer["source"] = row.source
    return answer


def status(conf):
    state = load_state(conf)
    targets = {}
    for key, command in [("REGISTRAR", "registrar-remote")] + list(OVERLAY_TARGETS.items()):
        where = conf.get(key, "")
        if not where:
            targets[key.lower()] = "not set (not built yet)"
            continue
        try:
            if key == "REGISTRAR":
                out = json.loads(registrar(conf, "list"))
                targets[key.lower()] = "ok, %d domains (%s)" % (len(out["domains"]), where)
            else:
                out = run_target(conf, key, command, ["status"]) or ""
                targets[key.lower()] = "ok, %s (%s)" % (out.strip().splitlines()[0] if out.strip() else "", where)
        except GreyError as e:
            targets[key.lower()] = "PROBLEM: %s" % e
    return {
        "teams": sorted(state["teams"]),
        "domains": sorted(state["domains"]),
        "changed_at": state.get("changed_at", "never"),
        "targets": targets,
        "snapshots": [s["name"] for s in snapshot_list(conf)],
        "zero_saved": os.path.exists(snapshot_path(conf, ZERO)),
    }


# ---------------------------------------------------------------------------
# API tokens (only their SHA-256 is kept)
# ---------------------------------------------------------------------------

def read_tokens(conf):
    tokens = []
    path = conf["TOKENS_FILE"]
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) == 3 and not line.startswith("#"):
                    tokens.append({"name": parts[0], "scope": parts[1], "sha256": parts[2]})
    return tokens


def write_tokens(conf, tokens):
    path = conf["TOKENS_FILE"]
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# name scope sha256-of-token   (made by: greyctl token add)\n")
        for t in tokens:
            f.write("%s %s %s\n" % (t["name"], t["scope"], t["sha256"]))
    os.chmod(tmp, 0o640)
    os.replace(tmp, path)


def token_add(conf, name, scope):
    check_name("token", name)
    if scope not in SCOPES:
        raise GreyError("scope must be one of: %s" % ", ".join(SCOPES))
    tokens = [t for t in read_tokens(conf) if t["name"] != name]
    token = "grey_" + secrets.token_urlsafe(32)
    tokens.append({"name": name, "scope": scope, "sha256": hashlib.sha256(token.encode()).hexdigest()})
    write_tokens(conf, tokens)
    log(conf, "token add %s %s" % (name, scope))
    return token


def token_check(conf, token):
    """Returns (name, scope) for a good token, or None."""
    digest = hashlib.sha256((token or "").encode()).hexdigest()
    for t in read_tokens(conf):
        if secrets.compare_digest(t["sha256"], digest):
            return t["name"], t["scope"]
    return None


def scope_allows(have, need):
    return SCOPES.index(have) >= SCOPES.index(need)


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

def print_report(lines):
    for line in lines or []:
        print("  " + line)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="greyctl", description="Control the range's fake internet.",
                                     epilog="See the top of greyctl.py or the README for examples.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    p = sub.add_parser("lookup")
    p.add_argument("ip")

    team = sub.add_parser("team").add_subparsers(dest="action", required=True)
    team.add_parser("list")
    p = team.add_parser("add")
    p.add_argument("name")
    p.add_argument("--network", action="append", required=True)
    p.add_argument("--org", required=True)
    p.add_argument("--domain", required=True)
    p.add_argument("--city")
    p.add_argument("--a")
    p.add_argument("--ns", action="append")
    p.add_argument("--exercise", default="class")
    p = team.add_parser("del")
    p.add_argument("name")

    domain = sub.add_parser("domain").add_subparsers(dest="action", required=True)
    domain.add_parser("list")
    p = domain.add_parser("add")
    p.add_argument("name")
    p.add_argument("--a")
    p.add_argument("--ns", action="append")
    p.add_argument("--exercise", default="class")
    p = domain.add_parser("del")
    p.add_argument("name")

    ex = sub.add_parser("exercise").add_subparsers(dest="action", required=True)
    p = ex.add_parser("clear")
    p.add_argument("tag")

    sub.add_parser("apply")

    snap = sub.add_parser("snapshot").add_subparsers(dest="action", required=True)
    snap.add_parser("list")
    p = snap.add_parser("save")
    p.add_argument("name")
    p.add_argument("--note", default="")
    p.add_argument("--replace", action="store_true")
    p = snap.add_parser("restore")
    p.add_argument("name")
    p = snap.add_parser("delete")
    p.add_argument("name")
    p.add_argument("--force", action="store_true")

    p = sub.add_parser("reset")
    p.add_argument("--yes", action="store_true")

    tok = sub.add_parser("token").add_subparsers(dest="action", required=True)
    tok.add_parser("list")
    p = tok.add_parser("add")
    p.add_argument("name")
    p.add_argument("scope", choices=SCOPES)
    p = tok.add_parser("del")
    p.add_argument("name")

    args = parser.parse_args(argv)
    conf = read_conf()
    try:
        return run_command(conf, args)
    except GreyError as e:
        print("greyctl: %s" % e, file=sys.stderr)
        return 1


def run_command(conf, args):
    if args.cmd == "status":
        s = status(conf)
        print("Teams:     %s" % (", ".join(s["teams"]) or "none"))
        print("Domains:   %s" % (", ".join(s["domains"]) or "none"))
        print("Changed:   %s" % s["changed_at"])
        print("Snapshots: %s" % (", ".join(s["snapshots"]) or "none"))
        if not s["zero_saved"]:
            print("           (no 'zero' yet: save one when the core is clean, so reset works)")
        print("Servers:")
        for key, value in s["targets"].items():
            print("  %-9s %s" % (key, value))
    elif args.cmd == "lookup":
        a = lookup(conf, args.ip)
        print("%s is in %s (%s)" % (args.ip, a["network"], a["source"]))
        print("  %s, AS%s %s, %s, %s  domain %s" % (a["org"], a["asn"], a["as_name"], a["city"], a["country"], a["domain"]))
    elif args.cmd == "team":
        if args.action == "list":
            teams = load_state(conf)["teams"]
            if not teams:
                print("No teams. The range is the plain base world from registry.csv.")
            for t in sorted(teams.values(), key=lambda t: t["name"]):
                print("%-12s %-10s AS%s %-24s %-18s %s" % (t["name"], t["exercise"], t["asn"], t["org"],
                                                           t["domain"], " ".join(t["networks"])))
        elif args.action == "add":
            t, report = team_add(conf, args.name, args.network, args.org, args.domain, args.city,
                                 args.a, args.ns, args.exercise)
            print("added team %s: %s, AS%d, %s, %s" % (t["name"], t["org"], t["asn"], t["domain"], t["place"]["city"]))
            print_report(report)
        else:
            print_report(team_del(conf, args.name))
            print("deleted team %s" % args.name)
    elif args.cmd == "domain":
        if args.action == "list":
            for d in sorted(load_state(conf)["domains"].values(), key=lambda d: d["name"]):
                print("%-30s %-10s %s" % (d["name"], d["exercise"], " ".join(d["dns"][2:])))
        elif args.action == "add":
            domain_add(conf, args.name, args.a, args.ns, args.exercise)
            print("added %s" % args.name)
        else:
            domain_del(conf, args.name)
            print("deleted %s" % args.name)
    elif args.cmd == "exercise":
        gone, report = exercise_clear(conf, args.tag)
        print("removed: %s" % (", ".join(gone) or "nothing"))
        print_report(report)
    elif args.cmd == "apply":
        print_report(apply_all(conf))
    elif args.cmd == "snapshot":
        if args.action == "list":
            for s in snapshot_list(conf):
                print("%-16s %s  %d team(s), %d registrar domain(s)  %s" % (s["name"], s["saved_at"], s["teams"],
                                                                             s["registrar_domains"], s["note"]))
        elif args.action == "save":
            snapshot_save(conf, args.name, args.note, args.replace)
            print("saved snapshot %s" % args.name)
        elif args.action == "restore":
            print_report(snapshot_restore(conf, args.name))
            print("restored snapshot %s" % args.name)
        else:
            snapshot_delete(conf, args.name, args.force)
            print("deleted snapshot %s" % args.name)
    elif args.cmd == "reset":
        if not args.yes:
            print("This puts the whole fake internet back to the 'zero' snapshot:")
            print("every exercise team, exercise domain and student registration made since is removed.")
            if input("Type reset to go on: ").strip() != "reset":
                print("Nothing changed.")
                return 1
        print_report(snapshot_restore(conf, ZERO))
        print("reset done: the core is back to zero")
    elif args.cmd == "token":
        if args.action == "list":
            for t in read_tokens(conf):
                print("%-16s %s" % (t["name"], t["scope"]))
        elif args.action == "add":
            token = token_add(conf, args.name, args.scope)
            print("Token for %s (%s). It is shown only now; store it outside git:" % (args.name, args.scope))
            print(token)
        else:
            write_tokens(conf, [t for t in read_tokens(conf) if t["name"] != args.name])
            log(conf, "token del %s" % args.name)
            print("deleted token %s" % args.name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
