#!/usr/bin/env python3
"""greyctl-api - the HTTPS API ForgeRange (and scripts) use to control the fake internet.

Every call does exactly what the same greyctl command does (it calls the same functions),
so teaching by hand and running an exercise from ForgeRange change the range the same way.

Each request needs a token:  Authorization: Bearer grey_...   (make one: greyctl token add NAME SCOPE)
Scopes: read (look only), exercise (teams, domains, snapshots), admin (also reset and the "zero" snapshot).

  GET    /v1/info                         read      status of every grey server, teams, snapshots
  GET    /v1/lookup?ip=192.168.103.5      read      who owns an address (what GeoIP and whois say)
  GET    /v1/teams                        read
  POST   /v1/teams                        exercise  {"name","networks":[...],"org","domain","city"?,"a"?,"ns"?,"exercise"?}
  DELETE /v1/teams/NAME                   exercise
  GET    /v1/domains                      read
  POST   /v1/domains                      exercise  {"name","a"? | "ns"?: ["host" or "host=glue"],"exercise"?}
  DELETE /v1/domains/NAME                 exercise
  POST   /v1/exercises/TAG/clear          exercise  remove every team and domain of one exercise
  POST   /v1/apply                        exercise  send everything to every grey server again
  GET    /v1/snapshots                    read
  POST   /v1/snapshots                    exercise  {"name","note"?,"replace"?}   ("zero" needs admin)
  POST   /v1/snapshots/NAME/restore       exercise  ("zero" needs admin)
  DELETE /v1/snapshots/NAME               admin
  POST   /v1/reset                        admin     restore "zero": back to the clean core

Answers are JSON. Errors are {"error": "..."} with a 4xx or 5xx code. Changes wait for the
grey servers to finish (a GeoIP rebuild takes a few seconds), then answer.

Standard library only. Run by systemd as the greyctl user (see install.sh).

License: GPL-3.0, Dire Wolf Security.
"""

from __future__ import annotations

import json
import os
import re
import ssl
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import greyctl  # noqa: E402  (same folder)

MAX_BODY = 65536


def route(method, path):
    """Which action a request is, and the scope it needs. Returns (action, scope, word) or None."""
    parts = [p for p in path.split("/") if p]
    if len(parts) < 2 or parts[0] != "v1":
        return None
    p = parts[1:]
    simple = {
        ("GET", "info"): ("info", "read"),
        ("GET", "lookup"): ("lookup", "read"),
        ("GET", "teams"): ("team_list", "read"),
        ("POST", "teams"): ("team_add", "exercise"),
        ("GET", "domains"): ("domain_list", "read"),
        ("POST", "domains"): ("domain_add", "exercise"),
        ("POST", "apply"): ("apply", "exercise"),
        ("GET", "snapshots"): ("snapshot_list", "read"),
        ("POST", "snapshots"): ("snapshot_save", "exercise"),
        ("POST", "reset"): ("reset", "admin"),
    }
    if len(p) == 1 and (method, p[0]) in simple:
        action, scope = simple[(method, p[0])]
        return action, scope, None
    if len(p) == 2 and method == "DELETE" and p[0] in ("teams", "domains", "snapshots"):
        scope = "admin" if p[0] == "snapshots" else "exercise"
        return p[0][:-1] + "_del", scope, p[1]
    if len(p) == 3 and method == "POST" and p[0] == "snapshots" and p[2] == "restore":
        return "snapshot_restore", "exercise", p[1]
    if len(p) == 3 and method == "POST" and p[0] == "exercises" and p[2] == "clear":
        return "exercise_clear", "exercise", p[1]
    return None


def handle(conf, action, scope, word, query, body):
    """Runs one action. Returns the JSON answer (a dict). Raises GreyError for problems."""
    if action == "info":
        return greyctl.status(conf)
    if action == "lookup":
        return greyctl.lookup(conf, (query.get("ip") or [""])[0])
    if action == "team_list":
        return {"teams": list(greyctl.load_state(conf)["teams"].values())}
    if action == "team_add":
        team, report = greyctl.team_add(
            conf, body.get("name"), body.get("networks") or [], body.get("org"), body.get("domain"),
            body.get("city"), body.get("a"), body.get("ns"), body.get("exercise") or "class")
        return {"team": team, "report": report}
    if action == "team_del":
        return {"deleted": word, "report": greyctl.team_del(conf, word)}
    if action == "domain_list":
        return {"domains": list(greyctl.load_state(conf)["domains"].values())}
    if action == "domain_add":
        return {"domain": greyctl.domain_add(conf, body.get("name"), body.get("a"), body.get("ns"),
                                             body.get("exercise") or "class")}
    if action == "domain_del":
        greyctl.domain_del(conf, word)
        return {"deleted": word}
    if action == "exercise_clear":
        gone, report = greyctl.exercise_clear(conf, word)
        return {"removed": gone, "report": report}
    if action == "apply":
        return {"report": greyctl.apply_all(conf)}
    if action == "snapshot_list":
        return {"snapshots": greyctl.snapshot_list(conf)}
    if action == "snapshot_save":
        snap = greyctl.snapshot_save(conf, body.get("name"), body.get("note", ""), bool(body.get("replace")))
        return {"saved": snap["name"], "saved_at": snap["saved_at"]}
    if action == "snapshot_restore":
        return {"restored": word, "report": greyctl.snapshot_restore(conf, word)}
    if action == "snapshot_del":
        greyctl.snapshot_delete(conf, word)
        return {"deleted": word}
    if action == "reset":
        return {"restored": greyctl.ZERO, "report": greyctl.snapshot_restore(conf, greyctl.ZERO)}
    raise greyctl.GreyError("not found", 404)


class Handler(BaseHTTPRequestHandler):
    server_version = "greyctl-api/1"
    conf = None

    def do_GET(self):
        self.serve("GET")

    def do_POST(self):
        self.serve("POST")

    def do_DELETE(self):
        self.serve("DELETE")

    def send_json(self, code, data):
        raw = (json.dumps(data, indent=2) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def serve(self, method):
        conf = greyctl.read_conf()          # re-read each time: token changes work at once
        url = urllib.parse.urlsplit(self.path)
        found = route(method, url.path)
        if found is None:
            return self.send_json(404, {"error": "no such call: %s %s (see GET /v1/info)" % (method, url.path)})
        action, scope, word = found

        auth = self.headers.get("Authorization", "")
        who = greyctl.token_check(conf, auth[7:] if auth.startswith("Bearer ") else "")
        if who is None:
            return self.send_json(401, {"error": "missing or wrong token"})
        name, have = who
        if word == greyctl.ZERO and action.startswith("snapshot"):
            scope = "admin"
        body = {}
        if method == "POST":
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                return self.send_json(413, {"error": "request too big"})
            if length:
                try:
                    body = json.loads(self.rfile.read(length))
                except ValueError:
                    return self.send_json(400, {"error": "the body is not JSON"})
                if not isinstance(body, dict):
                    return self.send_json(400, {"error": "the body must be a JSON object"})
        if action == "snapshot_save" and body.get("name") == greyctl.ZERO:
            scope = "admin"
        if not greyctl.scope_allows(have, scope):
            return self.send_json(403, {"error": "token %s has scope %s; this needs %s" % (name, have, scope)})

        os.environ["GREYCTL_CLIENT"] = "api:%s" % name      # shows in the change log
        try:
            answer = handle(conf, action, scope, word, urllib.parse.parse_qs(url.query), body)
        except greyctl.GreyError as e:
            return self.send_json(e.status, {"error": str(e)})
        except Exception as e:                               # keep serving; say what broke
            return self.send_json(500, {"error": "%s: %s" % (type(e).__name__, e)})
        self.send_json(200, answer)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def main():
    conf = greyctl.read_conf()
    host = conf.get("API_BIND", "0.0.0.0")
    port = int(conf.get("API_PORT", "8443"))
    server = ThreadingHTTPServer((host, port), Handler)
    cert, key = conf.get("TLS_CERT", ""), conf.get("TLS_KEY", "")
    if cert and key and os.path.exists(cert) and os.path.exists(key):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        print("greyctl-api: https on %s:%d" % (host, port), flush=True)
    else:
        print("greyctl-api: WARNING plain http on %s:%d (no certificate yet; see README, HTTPS)" % (host, port), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
