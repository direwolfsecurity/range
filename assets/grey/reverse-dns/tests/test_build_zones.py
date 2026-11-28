"""Tests for build-zones.py. Run from the reverse-dns folder:

    python3 -m unittest discover -s tests

They use the real registry.csv (two-folder clone) and need no BIND. If named-checkzone is
installed, every zone is checked with it too.

License: GPL-3.0, Dire Wolf Security.
"""

import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ASSET = os.path.dirname(HERE)
REGISTRY = os.path.normpath(os.path.join(ASSET, "..", "..", "..", "network", "registry", "registry.csv"))

spec = importlib.util.spec_from_file_location("build_zones", os.path.join(ASSET, "tools", "build-zones.py"))
build_zones = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_zones)

TEAM = ("192.168.103.0/24,KSTL,Kestrel Freight,65000,KESTREL,US,CO,Colorado,Denver,80202,"
        "39.7392,-104.9903,10,America/Denver,kestrel.lab,Exercise ev7: team blue1\n")


class BuildZonesTest(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def build(self, *extra):
        out = os.path.join(self.tmp, "out")
        args = ["--registry", REGISTRY, "--names", os.path.join(ASSET, "names.conf"),
                "--server-ip", "172.16.11.13", "--out", out, "--isp", "bluestem.lab", "meridian.lab"]
        self.assertEqual(build_zones.main(args + list(extra)), 0)
        return out

    def read(self, out, name):
        with open(os.path.join(out, name), encoding="utf-8") as f:
            return f.read()

    def test_names(self):
        out = self.build()
        rev = self.read(out, "db.in-addr.arpa")
        self.assertIn("11.11.16.172             PTR a.root-servers.net.", rev)     # names.conf
        self.assertIn("13.11.16.172             PTR a.in-addr-servers.arpa.", rev)  # this server
        self.assertIn("60.11.16.172             PTR maps.lab.", rev)                # a /32 row
        self.assertIn("$GENERATE 1-254 $.103.168.192 PTR 192-168-103-$.austin.bluestem.lab.", rev)
        self.assertIn("sao-paulo.meridian.lab.", rev)
        # 172.16.11.11 has its own name, so the generic run stops before it
        self.assertIn("$GENERATE 1-9 $.11.16.172 PTR", rev)
        self.assertNotIn("$GENERATE 1-254 $.11.16.172", rev)

    def test_forward_matches_reverse(self):
        out = self.build()
        fwd = self.read(out, "db.bluestem.lab")
        self.assertIn("ns1 IN A 172.16.11.13", fwd)
        self.assertIn("$GENERATE 1-254 192-168-103-$.austin A 192.168.103.$", fwd)
        self.assertNotIn("192-168-201", fwd)                  # meridian's networks stay in meridian.lab
        self.assertIn("db.meridian.lab", self.read(out, "zones.txt"))

    def test_overlay_takes_over_a_seat(self):
        overlay = os.path.join(self.tmp, "overlay.csv")
        with open(REGISTRY, encoding="utf-8") as f:
            header = f.readline()
        with open(overlay, "w", encoding="utf-8") as f:
            f.write(header + TEAM)
        out = self.build("--overlay", overlay)
        self.assertIn("192-168-103-$.denver.kestrel.lab.", self.read(out, "db.in-addr.arpa"))
        self.assertNotIn("192-168-103-", self.read(out, "db.bluestem.lab"))

    def test_serial_only_moves_on_change(self):
        out = self.build()
        state = os.path.join(out, "state.json")
        keep = os.path.join(self.tmp, "state.json")
        shutil.copy(state, keep)
        first = self.read(out, "db.in-addr.arpa")
        out = self.build("--state", keep)
        self.assertEqual(first, self.read(out, "db.in-addr.arpa"))

    @unittest.skipUnless(shutil.which("named-checkzone"), "named-checkzone is not installed")
    def test_bind_accepts_every_zone(self):
        out = self.build()
        for line in self.read(out, "zones.txt").splitlines():
            zone, filename = line.split()
            done = subprocess.run(["named-checkzone", "-q", zone, os.path.join(out, filename)])
            self.assertEqual(done.returncode, 0, zone)


if __name__ == "__main__":
    unittest.main()
