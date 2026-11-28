"""Tests for whoisd.py. Run from the whois folder:

    python3 -m unittest discover -s tests

They use the real registry.csv (two-folder clone). The servers run on free high ports.
Domain lookups use a tiny fake registrar page, so no registrar is needed.

License: GPL-3.0, Dire Wolf Security.
"""

import importlib.util
import ipaddress
import json
import os
import shutil
import socket
import tempfile
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ASSET = os.path.dirname(HERE)
REGISTRY = os.path.normpath(os.path.join(ASSET, "..", "..", "..", "network", "registry", "registry.csv"))

spec = importlib.util.spec_from_file_location("whoisd", os.path.join(ASSET, "whoisd.py"))
whoisd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(whoisd)

TEAM = ("192.168.103.0/24,KSTL,Kestrel Freight,65000,KESTREL,US,CO,Colorado,Denver,80202,"
        "39.7392,-104.9903,10,America/Denver,kestrel.lab,Exercise ev7: team blue1\n")

FAKE_PAGE = """<html><pre class="whois">Domain Name:      SHOP.COM
Registrar:        Range Registrar
Status:           active
Created:          2026-11-28 10:00:00 UTC
Updated:          2026-11-28 10:00:00 UTC
Registrant:       Jo &amp; Sam
Organization:     -
Email:            -
Name Server:      NS1.SHOP.COM  (glue 172.16.13.53)
</pre></html>"""


class FakeRegistrar(BaseHTTPRequestHandler):
    def do_GET(self):
        body = FAKE_PAGE if "q=shop.com" in self.path else "<p>No match</p>"
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *args):
        pass


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class WhoisTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.overlay = os.path.join(cls.tmp, "overlay.csv")
        cls.registrar = HTTPServer(("127.0.0.1", 0), FakeRegistrar)
        threading.Thread(target=cls.registrar.serve_forever, daemon=True).start()
        conf = os.path.join(cls.tmp, "whois.conf")
        with open(conf, "w", encoding="utf-8") as f:
            f.write('REGISTRY_FILE="%s"\nOVERLAY_FILE="%s"\nREGISTRAR_URL="http://127.0.0.1:%d"\nLISTEN="127.0.0.1"\n'
                    % (REGISTRY, cls.overlay, cls.registrar.server_port))
        cls.conf = whoisd.read_conf(conf)
        cls.data = whoisd.Data(cls.conf)

    @classmethod
    def tearDownClass(cls):
        cls.registrar.shutdown()
        shutil.rmtree(cls.tmp)

    def ask(self, query):
        return whoisd.whois_answer(self.data, query)[1]

    def test_parse_what_stock_clients_send(self):
        p = whoisd.parse_query
        self.assertEqual(p("n + 192.168.103.5"), ("ip", ipaddress.IPv4Address("192.168.103.5")))
        self.assertEqual(p("r + = 192.168.1.0/24")[0], "net")
        self.assertEqual(p("-V Md5.5.22 as64601"), ("asn", 64601))
        self.assertEqual(p("domain shop.com"), ("domain", "shop.com"))
        self.assertEqual(p("a 64601"), ("asn", 64601))
        self.assertEqual(p("o BSBB"), ("org", "BSBB"))
        self.assertEqual(p("NET-192-168-103-0-1")[0], "ip")
        self.assertEqual(p(""), ("help", ""))

    def test_address(self):
        text = self.ask("n + 192.168.204.9")
        self.assertIn("CIDR:           192.168.204.0/24", text)
        self.assertIn("Organization:   Meridian Global Telecom (MGT)", text)
        self.assertIn("Location: Kyiv", text)
        self.assertIn("OrgAbuseEmail:  abuse@meridian.lab", text)
        self.assertNotIn("Seat 204", text)            # the "use" column is for people, not students

    def test_single_address_has_a_parent(self):
        text = self.ask("172.16.11.20")
        self.assertIn("Range Encrypt", text)
        self.assertIn("Parent:         GIR-INFRA-172-16-11-0 (NET-172-16-11-0-1)", text)

    def test_not_in_registry(self):
        self.assertIn("No match found for n + 8.8.8.8.", self.ask("8.8.8.8"))

    def test_asn_and_org(self):
        self.assertIn("Announces 192.168.109.0/24 (Honolulu", self.ask("AS64601"))
        self.assertIn("OrgId:          NJH", self.ask("nightjar"))

    def test_domain_from_registrar(self):
        text = self.ask("shop.com")
        self.assertIn("Domain Name: SHOP.COM", text)
        self.assertIn("Registrant: Jo & Sam", text)
        self.assertIn('No match for "NOPE.LAB"', self.ask("nope.lab"))
        status, obj = whoisd.rdap_answer(self.data, "/domain/shop.com")
        self.assertEqual(status, 200)
        self.assertEqual(obj["nameservers"][0]["ldhName"], "ns1.shop.com")

    def test_rdap(self):
        status, obj = whoisd.rdap_answer(self.data, "/ip/192.168.103.5")
        self.assertEqual(status, 200)
        self.assertEqual(obj["handle"], "NET-192-168-103-0-1")
        self.assertEqual(obj["entities"][0]["handle"], "BSBB")
        self.assertEqual(whoisd.rdap_answer(self.data, "/autnum/64530")[1]["name"], "NIGHTJAR-AS")
        self.assertEqual(whoisd.rdap_answer(self.data, "/ip/8.8.8.8")[0], 404)
        self.assertEqual(whoisd.rdap_answer(self.data, "/ip/not-an-ip")[0], 400)

    def test_overlay_is_picked_up_without_restart(self):
        with open(REGISTRY, encoding="utf-8") as f:
            header = f.readline()
        with open(self.overlay, "w", encoding="utf-8") as f:
            f.write(header + TEAM)
        self.data.checked = 0
        self.data.stamp = None
        try:
            self.assertIn("Kestrel Freight (KSTL)", self.ask("192.168.103.5"))
        finally:
            os.remove(self.overlay)
            self.data.checked = 0
        self.assertIn("Bluestem Broadband (BSBB)", self.ask("192.168.103.5"))

    def test_servers(self):
        wport, hport = free_port(), free_port()
        whois = whoisd.WhoisServer(("127.0.0.1", wport), whoisd.WhoisHandler)
        whois.data = self.data
        web = whoisd.WebServer(("127.0.0.1", hport), whoisd.WebHandler)
        web.data = self.data
        for server in (whois, web):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            s = socket.create_connection(("127.0.0.1", wport), timeout=5)
            s.sendall(b"n + 10.250.250.7\r\n")
            text = b""
            while True:
                part = s.recv(65536)
                if not part:
                    break
                text += part
            s.close()
            self.assertIn(b"Tunnelfox VPN AG", text)
            with urllib.request.urlopen("http://127.0.0.1:%d/rdap/autnum/64601" % hport) as r:
                self.assertEqual(r.headers["Content-Type"], "application/rdap+json")
                self.assertEqual(json.load(r)["handle"], "AS64601")
            with urllib.request.urlopen("http://127.0.0.1:%d/?q=%%3Cscript%%3E" % hport) as r:
                page = r.read().decode()
            self.assertNotIn("<script>", page)
        finally:
            for server in (whois, web):
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    unittest.main()
