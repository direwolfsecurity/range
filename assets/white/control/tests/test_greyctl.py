"""Tests for greyctl, with fake grey servers (no SSH, no BIND, no nginx needed).

Run from the control folder, with network/registry cloned beside it (the normal two-folder clone):
    python3 -m unittest discover -s tests -v

License: GPL-3.0, Dire Wolf Security.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CONTROL = os.path.dirname(HERE)
REGISTRY = os.path.normpath(os.path.join(CONTROL, "..", "..", "..", "network", "registry"))
sys.path.insert(0, CONTROL)
import greyctl  # noqa: E402

# A fake registrar: keeps its domains in a JSON file, answers the same requests registrar-remote does.
FAKE_REGISTRAR = r'''#!/usr/bin/env python3
import json, sys
db = sys.argv[1]; words = sys.argv[2:]
data = json.load(open(db))
verb = words[0]
if verb in ("list", "export"):
    print(json.dumps(data)); sys.exit(0)
if verb == "import":
    data = json.loads(sys.stdin.read())
elif verb in ("add-a", "add-ns"):
    if any(d["label"] + "." + d["tld"] == words[1] for d in data["domains"]):
        print("error: already registered", file=sys.stderr); sys.exit(1)
    label, tld = words[1].split(".", 1)
    data["domains"].append({"label": label, "tld": tld, "registrant": "greyctl:" + words[-1]})
elif verb == "del":
    data["domains"] = [d for d in data["domains"] if d["label"] + "." + d["tld"] != words[1]]
elif verb != "apply":
    sys.exit(64)
json.dump(data, open(db, "w")); print("published")
'''

# A fake GeoIP server: checks the overlay with registry.py (like geoip-apply does), keeps it.
FAKE_GEOIP = r'''#!/bin/bash
set -e
out="$1"; registry="$2"; shift 2
case "$*" in
  overlay) cat > "$out.new"
           python3 "$registry/registry.py" "$registry/registry.csv" --overlay "$out.new" >/dev/null
           mv "$out.new" "$out"; echo "geoip-apply: ok";;
  status)  echo "overlay";;
  *) exit 64;;
esac
'''


class GreyctlTest(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        reg = os.path.join(self.dir, "registry")
        shutil.copytree(REGISTRY, reg)
        self.registrar_db = os.path.join(self.dir, "registrar.json")
        with open(self.registrar_db, "w") as f:
            json.dump({"format": "registrar-snapshot-1", "tlds": ["lab"],
                       "domains": [{"label": "ca", "tld": "lab", "registrant": "Range Admin"}]}, f)
        self.overlay = os.path.join(self.dir, "overlay.csv")
        for name, text in (("registrar", FAKE_REGISTRAR), ("geoip", FAKE_GEOIP)):
            path = os.path.join(self.dir, "fake-" + name)
            with open(path, "w") as f:
                f.write(text)
            os.chmod(path, 0o755)
        # Each fake gets its data file as its first word(s); greyctl adds the request words after them.
        wrap_r = os.path.join(self.dir, "registrar")
        wrap_g = os.path.join(self.dir, "geoip")
        with open(wrap_r, "w") as f:
            f.write('#!/bin/sh\nexec "%s" "%s" "$@"\n' % (os.path.join(self.dir, "fake-registrar"), self.registrar_db))
        with open(wrap_g, "w") as f:
            f.write('#!/bin/sh\nexec "%s" "%s" "%s" "$@"\n' % (os.path.join(self.dir, "fake-geoip"), self.overlay, reg))
        os.chmod(wrap_r, 0o755)
        os.chmod(wrap_g, 0o755)
        self.conf = dict(greyctl.DEFAULTS)
        self.conf.update({
            "STATE_DIR": os.path.join(self.dir, "state"),
            "REGISTRY_DIR": reg,
            "TOKENS_FILE": os.path.join(self.dir, "tokens"),
            "REGISTRAR": "cmd:" + wrap_r,
            "GEOIP": "cmd:" + wrap_g,
        })

    def tearDown(self):
        shutil.rmtree(self.dir)

    def registrar_names(self):
        with open(self.registrar_db) as f:
            return sorted(d["label"] + "." + d["tld"] for d in json.load(f)["domains"])

    def add_blue1(self, **extra):
        return greyctl.team_add(self.conf, "blue1", ["192.168.103.0/24"], "Kestrel Freight", "kestrel.lab",
                                a="192.168.103.1", exercise="ex1", **extra)

    def test_team_takes_over_a_seat(self):
        team, report = self.add_blue1()
        self.assertEqual(team["asn"], 65000)
        self.assertEqual(team["place"]["city"], "Austin")           # the seat's own place
        self.assertIn("kestrel.lab", self.registrar_names())
        self.assertEqual(greyctl.lookup(self.conf, "192.168.103.77")["org"], "Kestrel Freight")
        with open(self.overlay) as f:
            self.assertIn("192.168.103.0/24", f.read())

    def test_city_moves_a_team(self):
        team, _ = greyctl.team_add(self.conf, "blue2", ["192.168.104.0/24", "192.168.105.0/24"], "Osprey Clinics",
                                   "osprey.lab", city="Tokyo", ns=["ns1.osprey.lab=192.168.104.10"])
        self.assertEqual(greyctl.lookup(self.conf, "192.168.105.1")["city"], "Tokyo")

    def test_fixed_networks_cannot_be_taken(self):
        with self.assertRaises(greyctl.GreyError):
            greyctl.team_add(self.conf, "bad", ["172.16.11.0/24"], "X", "x.lab", city="Austin")
        with self.assertRaises(greyctl.GreyError):
            greyctl.team_add(self.conf, "bad", ["192.168.103.128/25"], "X", "x.lab", city="Austin")
        self.assertEqual(greyctl.load_state(self.conf)["teams"], {})
        self.assertEqual(self.registrar_names(), ["ca.lab"])         # nothing reached the registrar

    def test_same_network_twice_is_refused(self):
        self.add_blue1()
        with self.assertRaises(greyctl.GreyError):
            greyctl.team_add(self.conf, "blue9", ["192.168.103.0/24"], "Y", "y.lab")

    def test_delete_team(self):
        self.add_blue1()
        greyctl.team_del(self.conf, "blue1")
        self.assertEqual(self.registrar_names(), ["ca.lab"])
        self.assertEqual(greyctl.lookup(self.conf, "192.168.103.77")["org"], "Bluestem Broadband")

    def test_snapshot_and_reset_to_zero(self):
        greyctl.snapshot_save(self.conf, "zero", "clean core")
        self.add_blue1()
        greyctl.domain_add(self.conf, "kestre1.lab", a="172.16.13.50", exercise="ex1")
        greyctl.snapshot_save(self.conf, "midclass")
        greyctl.snapshot_restore(self.conf, "zero")
        self.assertEqual(self.registrar_names(), ["ca.lab"])
        self.assertEqual(greyctl.load_state(self.conf)["teams"], {})
        greyctl.snapshot_restore(self.conf, "midclass")
        self.assertEqual(self.registrar_names(), ["ca.lab", "kestre1.lab", "kestrel.lab"])
        self.assertIn("blue1", greyctl.load_state(self.conf)["teams"])

    def test_zero_is_protected(self):
        greyctl.snapshot_save(self.conf, "zero")
        with self.assertRaises(greyctl.GreyError):
            greyctl.snapshot_save(self.conf, "zero")
        with self.assertRaises(greyctl.GreyError):
            greyctl.snapshot_delete(self.conf, "zero")

    def test_reset_without_zero_explains(self):
        with self.assertRaises(greyctl.GreyError) as e:
            greyctl.snapshot_restore(self.conf, "zero")
        self.assertIn("snapshot save zero", str(e.exception))

    def test_exercise_clear(self):
        self.add_blue1()
        greyctl.team_add(self.conf, "other", ["192.168.201.0/24"], "Lantern", "lantern.lab", exercise="ex2")
        gone, _ = greyctl.exercise_clear(self.conf, "ex1")
        self.assertEqual(gone, ["blue1"])
        self.assertEqual(sorted(greyctl.load_state(self.conf)["teams"]), ["other"])

    def test_tokens(self):
        token = greyctl.token_add(self.conf, "forgerange", "exercise")
        self.assertEqual(greyctl.token_check(self.conf, token), ("forgerange", "exercise"))
        self.assertIsNone(greyctl.token_check(self.conf, token + "x"))
        with open(self.conf["TOKENS_FILE"]) as f:
            self.assertNotIn(token, f.read())                         # only the hash is kept
        self.assertTrue(greyctl.scope_allows("admin", "exercise"))
        self.assertFalse(greyctl.scope_allows("exercise", "admin"))


if __name__ == "__main__":
    unittest.main()
