#!/usr/bin/env python3
"""
gencfg.py -- build every range config from student-list.csv and range.ini.

    python gencfg.py                 # uses range.ini, or range.example.ini if there is none
    python gencfg.py --ini my.ini --students my-class.csv

Python 3.8+, standard library only. Output goes to out/ (git-ignored).
Edit range.ini or the student list and run again. Never hand-edit files in out/.

Dire Wolf Security range | https://github.com/direwolfsecurity/range | GPL-3.0
"""
import argparse, configparser, csv, ipaddress, os, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))


# ----------------------------------------------------------------- input ---
def die(msg):
    sys.exit(f"gencfg: {msg}")


def load_ini(path):
    cp = configparser.ConfigParser(inline_comment_prefixes=(';', '#'))
    cp.optionxform = str                    # keep case in keys (port names)
    if not cp.read(path, encoding='utf-8'):
        die(f"can't read {path}")
    return cp


def load_students(path):
    if not os.path.exists(path):
        die(f"can't find {path}. Copy student-list.example.csv to student-list.csv and edit it.")
    with open(path, newline='', encoding='utf-8-sig') as f:
        rows = [{k.strip().lower(): (v or '').strip() for k, v in r.items() if k}
                for r in csv.DictReader(f)]
    rows = [r for r in rows if r.get('pod') and not r['pod'].startswith('#')]
    if not rows:
        die(f"{path} has no pods")
    seen_pod, seen_id = set(), set()
    for r in rows:
        if not r['pod'].isdigit() or int(r['pod']) < 1:
            die(f"pod must be a whole number from 1 up, got '{r['pod']}'")
        r['n'] = int(r['pod'])
        r['id'] = (r.get('id') or f"pod{r['n']:02d}").lower()
        if not r['id'].replace('-', '').replace('_', '').isalnum():
            die(f"id '{r['id']}' may use only letters, digits, - and _")
        r['status'] = (r.get('status') or 'active').lower()
        if r['status'] not in ('active', 'spare', 'instructor'):
            die(f"pod {r['n']}: status must be active, spare or instructor")
        if r['n'] in seen_pod: die(f"pod {r['n']} is listed twice")
        if r['id'] in seen_id: die(f"id '{r['id']}' is listed twice")
        seen_pod.add(r['n']); seen_id.add(r['id'])
    return sorted(rows, key=lambda r: r['n'])


def opt_list(s):
    return [x.strip() for x in s.split(',') if x.strip()]


# ------------------------------------------------------------- the plan ---
def plan(cfg, pods):
    """Work out every pod's names, tags and addresses once. Everything else reads this."""
    P = cfg['pods']; X = cfg['proxmox']
    width = 3 if max(p['n'] for p in pods) > 99 else 2
    out_third = P.getint('outside_third_octet_base', 100)
    out_vlan = P.getint('outside_vlan_base', 100)
    mode = X.get('zone_mode', 'shared').strip()
    if mode not in ('shared', 'per-pod'):
        die("[proxmox] zone_mode must be shared or per-pod")
    nodes = opt_list(X.get('nodes', 'pve1'))
    nics = opt_list(X.get('pod_nics', 'enp1s0, enp2s0'))
    per_node = {}
    for i, p in enumerate(pods):
        tag = f"P{p['n']:0{width}d}"
        third = out_third + p['n']
        if third > 254:
            die(f"pod {p['n']}: outside_third_octet_base + pod is past 254")
        node = p.get('host') or nodes[i % len(nodes)]
        per_node.setdefault(node, []).append(p)
        p.update({
            'tag': tag, 'lc': tag.lower(), 'node': node,
            'edge_vlan': out_vlan + p['n'],
            'out_net': f"192.168.{third}.0/24", 'out_pfx': f"192.168.{third}",
            'inside': P.get('inside_net', '10.10.10.0/24').strip(),
            'dmz': P.get('dmz_net', '10.9.9.0/24').strip(),
            'pool': f"pod-{p['n']:0{width}d}",
            'user': f"{p['id']}@pve",
            'vmid_base': X.getint('vmid_base', 1000) + p['n'] * 10,
        })
        # SDN: VNet names are max 8 chars, lowercase, unique cluster-wide.
        p['vn'] = {'out': f"{p['lc']}out", 'in': f"{p['lc']}in", 'dmz': f"{p['lc']}dmz"}
        if mode == 'shared':
            p['zone'] = X.get('zone', 'dwrange').strip()
            p['bridge'] = X.get('bridge', 'vmbr1').strip()
            p['vtag'] = {'out': X.getint('outside_tag_base', 1000) + p['n'],
                         'in': X.getint('inside_tag_base', 2000) + p['n'],
                         'dmz': X.getint('dmz_tag_base', 3000) + p['n']}
        else:
            p['zone'] = f"z{p['lc']}"[:8]
            p['bridge'] = p.get('bridge') or f"vmbr{out_vlan + p['n']}"
            p['vtag'] = {'out': 100, 'in': 10, 'dmz': 50}
    # NICs for per-pod bridges: Nth pod on a node gets the Nth NIC in the list unless the row says.
    for node, ps in per_node.items():
        for j, p in enumerate(ps):
            p['nic'] = p.get('nic') or (nics[j] if j < len(nics) else f"<NIC_FOR_{p['tag']}>")
    check(cfg, pods, mode)
    return mode, per_node


def check(cfg, pods, mode):
    """Stop before writing anything that would collide."""
    taken = {}                                       # network -> who owns it
    def claim(net, who):
        net = ipaddress.ip_network(net, strict=False)
        for other, owner in taken.items():
            if net.overlaps(other):
                die(f"{who} ({net}) overlaps {owner} ({other}). Change range.ini.")
        taken[net] = who
    if cfg.has_section('vlans'):
        for name, val in cfg['vlans'].items():
            claim(val.split(',')[1].strip(), f"shared network {name}")
    if cfg.has_section('cisco') and cfg['profiles'].getboolean('cisco_core_edge', False):
        claim(cfg['cisco'].get('uplink_net', '192.168.33.0/24').strip(), 'the uplink network')
    claim(pods[0]['inside'], 'the pod inside network')
    claim(pods[0]['dmz'], 'the pod DMZ network')
    for p in pods:
        claim(p['out_net'], f"pod {p['tag']} outside")
    if mode == 'shared':
        tags = {}
        for p in pods:
            for k, v in p['vtag'].items():
                if not 1 <= v <= 4094: die(f"pod {p['tag']}: VLAN tag {v} is outside 1-4094")
                if v in tags: die(f"VLAN tag {v} is used by both {tags[v]} and pod {p['tag']} {k}")
                tags[v] = f"pod {p['tag']} {k}"
        if cfg.has_section('vlans'):
            for name, val in cfg['vlans'].items():
                v = int(val.split(',')[0])
                if v in tags: die(f"VLAN tag {v} is used by both shared network {name} and {tags[v]}")


# ------------------------------------------------------------ writers ---
OUT = None


def write(rel, text, crlf=False):
    path = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', newline='\r\n' if crlf else '\n', encoding='utf-8') as f:
        f.write(text)


def bang(lines):           # Cisco comment header
    return ''.join(f"! {l}\n" for l in lines) + "!\n"


# ---- pods.csv: the address sheet ----
def gen_sheet(pods):
    cols = ['pod', 'id', 'name', 'status', 'node', 'pool', 'proxmox_user', 'zone', 'bridge',
            'vnet_outside', 'vnet_inside', 'vnet_dmz', 'tag_outside', 'tag_inside', 'tag_dmz',
            'outside_net', 'fw_outside', 'gateway', 'kali', 'dmz_published', 'inside_net', 'dmz_net',
            'fw_mgmt', 'vmid_range']
    rows = []
    for p in pods:
        rows.append([p['tag'], p['id'], p.get('name', ''), p['status'], p['node'], p['pool'], p['user'],
                     p['zone'], p['bridge'], p['vn']['out'], p['vn']['in'], p['vn']['dmz'],
                     p['vtag']['out'], p['vtag']['in'], p['vtag']['dmz'],
                     p['out_net'], f"{p['out_pfx']}.1", f"{p['out_pfx']}.254", f"{p['out_pfx']}.100",
                     f"{p['out_pfx']}.50", p['inside'], p['dmz'], p.get('fw_mgmt', ''),
                     f"{p['vmid_base']}-{p['vmid_base'] + 9}"])
    path = os.path.join(OUT, 'pods.csv')
    os.makedirs(OUT, exist_ok=True)
    with open(path, 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f); w.writerow(cols); w.writerows(rows)


# ---- Proxmox: SDN, users, pools, permissions, clones ----
def gen_proxmox(cfg, pods, mode, per_node):
    X = cfg['proxmox']; T = cfg['templates'] if cfg.has_section('templates') else {}
    role = X.get('student_role', 'DWStudent').strip()
    storages = opt_list(X.get('storages', 'local, local-lvm'))
    s = ["#!/bin/bash",
         "# pods.sh -- run ONCE on any Proxmox node, as root. Safe to run again: existing items are skipped.",
         "# Built by gencfg.py. Placeholders <POD_SECRET:Pnn> are filled by Set-Secrets.ps1 into out/_ready/.",
         f"# Zone mode: {mode}.  Pods: {len(pods)}.",
         "set -u",
         "ok() { \"$@\" 2>/dev/null || echo \"  (skipped: $*)\"; }", "",
         "# ---- Role for students. Check privilege names on your version with: pveum role list",
         f"ok pveum role add {role} -privs \"VM.Allocate VM.Audit VM.Console VM.PowerMgmt VM.Clone "
         "VM.Snapshot VM.Snapshot.Rollback VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk "
         "VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options\"", "",
         "# ---- SDN zones and VNets (one VNet per pod network)"]
    zones = {}
    for p in pods:
        zones.setdefault(p['zone'], p['bridge'])
    for z, br in zones.items():
        s.append(f"ok pvesh create /cluster/sdn/zones --zone {z} --type vlan --bridge {br}")
    for p in pods:
        for k, label in (('out', 'outside'), ('in', 'inside'), ('dmz', 'DMZ')):
            s.append(f"ok pvesh create /cluster/sdn/vnets --vnet {p['vn'][k]} --zone {p['zone']} "
                     f"--tag {p['vtag'][k]} --alias \"{p['tag']} {label}\"")
    s += ["pvesh set /cluster/sdn    # apply SDN changes on every node", "",
          "# ---- One user, one pool, one set of VNets per pod. Students see nothing outside their pool."]
    for p in pods:
        if p['status'] == 'spare':
            s.append(f"# {p['tag']} is a spare: no user created"); continue
        s += [f"# {p['tag']}  {p['id']}  on {p['node']}",
              f"ok pveum user add {p['user']} --comment \"{p['tag']}\" --password '<POD_SECRET:{p['tag']}>'",
              f"ok pveum pool add {p['pool']} --comment \"{p['tag']} on {p['node']}\"",
              f"pveum acl modify /pool/{p['pool']} --users {p['user']} --roles {role}"]
        for k in ('out', 'in', 'dmz'):
            s.append(f"pveum acl modify /sdn/zones/{p['zone']}/{p['vn'][k]} --users {p['user']} --roles PVESDNUser")
        for st in storages:
            s.append(f"pveum acl modify /storage/{st} --users {p['user']} --roles PVEDatastoreUser")
    # Optional: clone templates into each pod
    clones = []
    fw_t = T.get('firewall', '').strip() if T else ''
    kali_t = T.get('kali', '').strip() if T else ''
    full = (T.get('full_clone', 'no').strip().lower() in ('yes', 'true', '1')) if T else False
    for p in pods:
        if p['status'] == 'spare': continue
        if fw_t:
            v = p['vmid_base']
            clones += [f"# {p['tag']} firewall (OPNsense): WAN=net0 outside, LAN=net1 inside, OPT1=net2 DMZ",
                       f"ok qm clone {fw_t} {v} --name {p['lc']}-fw --pool {p['pool']} --target {p['node']}"
                       + (" --full 1" if full else ""),
                       f"qm set {v} --net0 virtio,bridge={p['vn']['out']} --net1 virtio,bridge={p['vn']['in']} "
                       f"--net2 virtio,bridge={p['vn']['dmz']}"]
        if kali_t:
            v = p['vmid_base'] + 1
            clones += [f"ok qm clone {kali_t} {v} --name {p['lc']}-kali --pool {p['pool']} --target {p['node']}"
                       + (" --full 1" if full else ""),
                       f"qm set {v} --net0 virtio,bridge={p['vn']['out']}"]
    if clones:
        s += ["", "# ---- Clone templates into each pod.",
              "# Linked clones need the template on shared storage, or every pod on the template's node.",
              *clones]
    s += ["", "echo 'Done. Passwords are on the sheet Set-Secrets.ps1 made (out/_ready/pod-passwords.csv).'", ""]
    write('proxmox/pods.sh', '\n'.join(s))

    # per-pod mode: each pod needs its own bridge on a physical NIC
    if mode == 'per-pod':
        for node, ps in per_node.items():
            t = [f"# {node} -- APPEND to /etc/network/interfaces, then run: ifreload -a",
                 "# Leave vmbr0 (management) alone. NIC names are from student-list.csv or range.ini [proxmox] pod_nics;",
                 "# check them with `ip -br link` before applying.", ""]
            for p in ps:
                t += [f"auto {p['bridge']}", f"iface {p['bridge']} inet manual",
                      f"    # {p['tag']} -> its firewall's trunk port. No IP on this bridge.",
                      f"    bridge-ports {p['nic']}", "    bridge-stp off", "    bridge-fd 0",
                      "    bridge-vlan-aware yes", f"    bridge-vids {p['vtag']['in']} {p['vtag']['dmz']} {p['vtag']['out']}", ""]
            write(f"proxmox/{node}.interfaces", '\n'.join(t))


# ---- Cisco Firepower / ASA, one per pod (hardware profile) ----
def gen_asa(cfg, pods, edges_for):
    A = cfg['asa']
    mgmt_net = ipaddress.ip_network(A.get('mgmt_net', '192.0.2.0/24').strip(), strict=False)
    dns = A.get('dns', '172.16.11.10').strip(); syslog = A.get('syslog', '172.16.12.30').strip()
    for p in pods:
        if p['status'] == 'spare': continue
        ins = ipaddress.ip_network(p['inside']); dz = ipaddress.ip_network(p['dmz'])
        ip = lambda net, host: str(net.network_address + host)
        o, i, d = p['vtag']['out'], p['vtag']['in'], p['vtag']['dmz']
        mg = p.get('fw_mgmt') or '<MGMT_IP>'
        edge = edges_for.get(p['n'])
        e_desc = f"EDGE-{edge[0]} Fa1/{edge[1]}" if edge else "the range edge"
        t = bang([f"FW-{p['tag']}  --  Firepower 1010 / ASA 9.x  --  pod {p['tag']}",
                  "Dire Wolf Security range  |  built by gencfg.py  |  GPL-3.0",
                  "Placeholders <ENABLE_SECRET> <ADMIN_SECRET> <POD_SECRET:..> are filled by Set-Secrets.ps1.",
                  "<MGMT_IP> means this pod has no fw_mgmt address in student-list.csv yet.",
                  "Load from the CONSOLE after 'clear configure all'."])
        t += f"""hostname FW-{p['tag']}
domain-name pod.lab
enable password <ENABLE_SECRET>
username admin password <ADMIN_SECRET> privilege 15
username student password <POD_SECRET:{p['tag']}> privilege 15
!
interface Ethernet1/1
 description OUTSIDE to {e_desc}
 switchport
 switchport access vlan {o}
 no shutdown
interface Ethernet1/2
 description TRUNK to Proxmox {p['bridge']} on {p['node']} (tags {i} inside, {d} DMZ, {o} outside)
 switchport
 switchport mode trunk
 switchport trunk allowed vlan {i},{d},{o}
 switchport trunk native vlan 999
 no shutdown
"""
        for port in range(3, 7):
            t += f"interface Ethernet1/{port}\n description INSIDE physical\n switchport\n switchport access vlan {i}\n no shutdown\n"
        for port in (7, 8):
            t += f"interface Ethernet1/{port}\n description DMZ physical (PoE)\n switchport\n switchport access vlan {d}\n power inline auto\n no shutdown\n"
        t += f"""interface Management1/1
 description MGMT (management-only: never forwards range traffic)
 management-only
 nameif management
 security-level 100
 ip address {mg} {mgmt_net.netmask}
 no shutdown
!
interface Vlan{o}
 nameif outside
 security-level 0
 ip address {p['out_pfx']}.1 255.255.255.0
interface Vlan{i}
 nameif inside
 security-level 100
 ip address {ip(ins, 254)} {ins.netmask}
interface Vlan{d}
 nameif DMZ
 security-level 50
 ip address {ip(dz, 254)} {dz.netmask}
!
route outside 0.0.0.0 0.0.0.0 {p['out_pfx']}.254 1
dns domain-lookup outside
dns server-group DefaultDNS
 name-server {dns} outside
!
object network INSIDE-NET
 subnet {ins.network_address} {ins.netmask}
 nat (inside,outside) dynamic interface
object network DMZ-NET
 subnet {dz.network_address} {dz.netmask}
 nat (DMZ,outside) dynamic interface
object network DMZ-WWW
 host {ip(dz, 50)}
 nat (DMZ,outside) static {p['out_pfx']}.50
!
access-list OUTSIDE_IN extended permit tcp any object DMZ-WWW eq www
access-list OUTSIDE_IN extended permit tcp any object DMZ-WWW eq https
access-group OUTSIDE_IN in interface outside
!
dhcpd address {ip(ins, 50)}-{ip(ins, 79)} inside
dhcpd dns {ip(ins, 10)} {dns} interface inside
dhcpd domain pod.lab interface inside
dhcpd enable inside
!
aaa authentication ssh console LOCAL
aaa authentication http console LOCAL
aaa authorization exec LOCAL auto-enable
http server enable
http {mgmt_net.network_address} {mgmt_net.netmask} management
http {ins.network_address} {ins.netmask} inside
ssh {mgmt_net.network_address} {mgmt_net.netmask} management
ssh {ins.network_address} {ins.netmask} inside
ssh version 2
ssh key-exchange group dh-group14-sha256
ssh timeout 30
console timeout 15
icmp permit any inside
icmp permit any outside
icmp permit any DMZ
!
logging enable
logging timestamp
logging trap informational
logging host outside {syslog}
!
class-map inspection_default
 match default-inspection-traffic
policy-map type inspect dns preset_dns_map
 parameters
  message-length maximum client auto
  message-length maximum 512
policy-map global_policy
 class inspection_default
  inspect dns preset_dns_map
  inspect ftp
  inspect icmp
  inspect sqlnet
  inspect sunrpc
  inspect tftp
  inspect sip
  inspect netbios
  inspect rsh
  inspect esmtp
service-policy global_policy global
!
"""
        write(f"asa/FW-{p['tag']}.txt", t, crlf=True)


# ---- Cisco core + edge switches/routers (hardware profile) ----
BASE_IOS = """service timestamps debug datetime msec
service timestamps log datetime msec
service password-encryption
!
enable secret <ENABLE_SECRET>
username admin privilege 15 secret <ADMIN_SECRET>
no aaa new-model
!
no ip domain-lookup
ip domain-name range.lab
no ip source-route
no ip http server
no ip http secure-server
ip ssh version 2
ip ssh time-out 60
ip ssh authentication-retries 3
!
banner motd ^
  DIRE WOLF SECURITY range device. Authorized use only.
^
!
"""


def lines(vty):
    return f"""line con 0
 login local
 exec-timeout 15 0
 logging synchronous
line vty {vty}
 access-class MGMT-ONLY in
 login local
 exec-timeout 15 0
 transport input ssh
!
"""


def mgmt_acl(white):
    return f"""ip access-list standard MGMT-ONLY
 remark who may SSH to this device
 permit {white.network_address} {white.hostmask}
 permit host <INSTRUCTOR_IP>
 deny   any log
!
"""


def assign_edges(cfg, pods):
    C = cfg['cisco']
    per = C.getint('ports_per_edge', 15)
    edges = {}
    active = [p for p in pods]
    for i, p in enumerate(active):
        edges[p['n']] = (i // per + 1, i % per + 1)
    return edges


def gen_cisco(cfg, pods, edges_for):
    C = cfg['cisco']; V = cfg['vlans']
    vlans = []
    for name, val in V.items():
        vid, net = [x.strip() for x in val.split(',')]
        vlans.append((int(vid), name.upper(), ipaddress.ip_network(net)))
    white = next((n for v, nm, n in vlans if nm == 'WHITECELL'), ipaddress.ip_network('172.16.12.0/24'))
    syslog = C.get('syslog', '172.16.12.30').strip()
    log = f"logging trap informational\nlogging {syslog}\n!\n"
    n_edges = max(e for e, _ in edges_for.values())
    edge_ports = opt_list(C.get('edge_core_ports', 'Fa1/0/47, Fa1/0/48'))
    if len(edge_ports) < n_edges:
        die(f"[cisco] edge_core_ports lists {len(edge_ports)} ports but {n_edges} edges are needed")
    tbase = C.getint('transit_vlan_base', 300)
    tnet = lambda k: ipaddress.ip_network(C.get('transit_net_pattern', '172.30.{k}.0/24').strip().format(k=k))
    up_port = C.get('uplink_port', 'Fa1/0/30').strip()
    up_vlan = C.getint('uplink_vlan', 330)
    up_net = ipaddress.ip_network(C.get('uplink_net', '192.168.33.0/24').strip())
    up_gw = C.get('uplink_gateway', str(up_net.network_address + 1)).strip()
    vpn = C.get('redteam_vpn_net', '10.250.250.0/24').strip()
    vpn_n = ipaddress.ip_network(vpn)

    # ---- CORE ----
    c = bang([f"CORE  --  {C.get('core_model', 'Catalyst 3750, IOS 12.2(55)SE')}",
              "Dire Wolf Security range  |  built by gencfg.py  |  GPL-3.0",
              "Placeholders <ENABLE_SECRET> <ADMIN_SECRET> <INSTRUCTOR_IP> are filled by Set-Secrets.ps1.",
              "Load from the CONSOLE."])
    c += "hostname CORE\n!\n" + BASE_IOS
    c += "no vstack\nvtp mode transparent\nip routing\nspanning-tree mode rapid-pvst\nspanning-tree extend system-id\n!\n"
    allv = vlans + [(up_vlan, 'UPLINK', up_net)] + [(tbase + k, f'TRANSIT-{k}', tnet(k)) for k in range(1, n_edges + 1)]
    for vid, nm, _ in sorted(allv):
        c += f"vlan {vid}\n name {nm}\n"
    c += "vlan 999\n name PARKED\n!\n"
    if C.get('dhcp_vlan', '').strip():
        dv = int(C['dhcp_vlan']); lo, hi = [int(x) for x in C.get('dhcp_hosts', '100-150').split('-')]
        dn = next(n for v, _, n in allv if v == dv)
        b = dn.network_address
        c += (f"ip dhcp excluded-address {b + 1} {b + lo - 1}\nip dhcp excluded-address {b + hi + 1} {b + 254}\n"
              f"ip dhcp pool VLAN{dv}\n network {b} {dn.netmask}\n default-router {b + 254}\n"
              f" dns-server {C.get('dns', '172.16.11.10').strip()}\n!\n")
    if cfg.has_section('core_access'):
        for ports, val in cfg['core_access'].items():
            vid, desc = [x.strip() for x in val.split(',', 1)]
            kw = 'interface range' if ('-' in ports or ',' in ports) else 'interface'
            c += f"{kw} {ports}\n description {desc}\n switchport mode access\n switchport access vlan {vid}\n spanning-tree portfast\n"
    c += (f"interface {up_port}\n description UPLINK to the outside gateway -- AIR-GAP CABLE (red)\n"
          f" switchport mode access\n switchport access vlan {up_vlan}\n")
    for k in range(1, n_edges + 1):
        c += f"interface {edge_ports[k - 1]}\n description EDGE-{k} Fa1/0\n switchport mode access\n switchport access vlan {tbase + k}\n"
    if C.get('trunk_port', '').strip():
        c += (f"interface {C['trunk_port'].strip()}\n description trunk to the grey/white Proxmox host\n"
              " switchport trunk encapsulation dot1q\n switchport mode trunk\n switchport trunk native vlan 999\n"
              f" switchport trunk allowed vlan {','.join(str(v) for v, _, _ in sorted(vlans))}\n spanning-tree portfast trunk\n")
    c += "!\ninterface Vlan1\n no ip address\n shutdown\n"
    for vid, nm, net in sorted(allv):
        gw = net.network_address + (1 if nm.startswith('TRANSIT') else 254)
        if nm == 'UPLINK': gw = net.network_address + 254
        c += f"interface Vlan{vid}\n description {nm}\n ip address {gw} {net.netmask}\n no ip redirects\n"
        if nm == 'WHITECELL':
            c += " ip access-group WHITE-PROTECT out\n"
    w = white; score = C.get('scoreboard', str(w.network_address + 20)).strip()
    c += f"""!
ip access-list extended WHITE-PROTECT
 remark replies to sessions started from WHITECELL
 permit tcp any {w.network_address} {w.hostmask} established
 permit udp any eq domain {w.network_address} {w.hostmask}
 permit udp any eq ntp {w.network_address} {w.hostmask}
 permit icmp any {w.network_address} {w.hostmask} echo-reply
 permit icmp any {w.network_address} {w.hostmask} unreachable
 permit icmp any {w.network_address} {w.hostmask} time-exceeded
 remark scoreboard web for everyone, syslog from gear
 permit tcp any host {score} eq www
 permit tcp any host {score} eq 443
 permit udp any host {syslog} eq syslog
 remark instructor
 permit ip host <INSTRUCTOR_IP> {w.network_address} {w.hostmask}
 deny   ip any any log
!
ip access-list extended UPLINK-IN-REDTEAM
 remark from the outside gateway: only the red-team VPN pool and the instructor
 permit ip {vpn_n.network_address} {vpn_n.hostmask} any
 permit ip host <INSTRUCTOR_IP> any
 deny   ip any any log
ip access-list extended UPLINK-OUT-REDTEAM
 permit ip any {vpn_n.network_address} {vpn_n.hostmask}
 permit ip any host <INSTRUCTOR_IP>
 deny   ip any any log
!
ip route 0.0.0.0 0.0.0.0 {up_gw} name OUTSIDE-GW
router ospf 1
 router-id {up_net.network_address + 254}
 log-adjacency-changes
 passive-interface default
"""
    for k in range(1, n_edges + 1):
        c += f" no passive-interface Vlan{tbase + k}\n"
    c += " network 0.0.0.0 255.255.255.255 area 0\n default-information originate\n!\n"
    c += mgmt_acl(white) + log + lines('0 15') + "end\n"
    write('cisco/CORE.txt', c, crlf=True)

    # ---- EDGES ----
    for k in range(1, n_edges + 1):
        mine = [p for p in pods if edges_for[p['n']][0] == k]
        tn = tnet(k); tv = tbase + k
        name = f"EDGE-{k}"
        vd = bang([f"{name} VLAN database. The NM-16ESW keeps VLANs in flash:vlan.dat, not in the config.",
                   "Type these at the EXEC prompt (EDGE#), BEFORE pasting the config."])
        vd += f"vlan database\nvlan {tv} name TRANSIT-{k}\n"
        for p in mine:
            vd += f"vlan {p['edge_vlan']} name POD-{p['tag']}\n"
        vd += "apply\nexit\n"
        write(f"cisco/{name}-vlan-database.txt", vd, crlf=True)
        e = bang([f"{name}  --  {C.get('edge_model', 'Cisco 2811 + NM-16ESW')}",
                  "Dire Wolf Security range  |  built by gencfg.py  |  GPL-3.0",
                  "Load the VLAN database first, then this, from the CONSOLE."])
        e += f"hostname {name}\n!\n" + BASE_IOS + "ip cef\n!\n"
        e += f"interface FastEthernet1/0\n description UPLINK to CORE {edge_ports[k - 1]}\n switchport mode access\n switchport access vlan {tv}\n!\n"
        for p in mine:
            port = edges_for[p['n']][1]
            e += (f"interface FastEthernet1/{port}\n description POD {p['tag']} firewall outside ({p['status']})\n"
                  f" switchport mode access\n switchport access vlan {p['edge_vlan']}\n spanning-tree portfast\n")
            if p['status'] == 'spare':
                e += " shutdown\n"
        e += "!\ninterface Vlan1\n no ip address\n shutdown\n"
        e += f"interface Vlan{tv}\n description TRANSIT-{k} to CORE\n ip address {tn.network_address + 2} {tn.netmask}\n no ip redirects\n"
        for p in mine:
            e += (f"interface Vlan{p['edge_vlan']}\n description POD {p['tag']} outside\n"
                  f" ip address {p['out_pfx']}.254 255.255.255.0\n no ip redirects\n")
        e += (f"!\nrouter ospf 1\n router-id {tn.network_address + 2}\n log-adjacency-changes\n passive-interface default\n"
              f" no passive-interface Vlan{tv}\n network 0.0.0.0 255.255.255.255 area 0\n!\n")
        e += mgmt_acl(white) + log + lines('0 4') + "end\n"
        write(f"cisco/{name}.txt", e, crlf=True)

    # ---- MODES ----
    modes = {
        'CLOSED-on.txt': f"! CLOSED: nothing leaves the room. Also pull the red cable at CORE {up_port}.\nconfigure terminal\ninterface {up_port}\n shutdown\nend\n",
        'CLOSED-off.txt': f"! Back to BUILD: plug the red cable back in.\nconfigure terminal\ninterface {up_port}\n no shutdown\nend\n",
        'REDTEAM-on.txt': f"! RED TEAM: uplink up, only the VPN pool ({vpn}) and the instructor cross it.\nconfigure terminal\ninterface Vlan{up_vlan}\n ip access-group UPLINK-IN-REDTEAM in\n ip access-group UPLINK-OUT-REDTEAM out\nend\n",
        'REDTEAM-off.txt': f"! Back to BUILD.\nconfigure terminal\ninterface Vlan{up_vlan}\n no ip access-group UPLINK-IN-REDTEAM in\n no ip access-group UPLINK-OUT-REDTEAM out\nend\n",
    }
    for k, t in modes.items():
        write(f"cisco/modes/{k}", t, crlf=True)
    # core route summary for whoever runs the outside gateway
    write('cisco/gateway-routes.txt',
          f"Static routes to add on the outside gateway (next hop = CORE {up_net.network_address + 254}):\n"
          + ''.join(f"  {v[2]}  ({v[1]})\n" for v in sorted(allv) if v[1] != 'UPLINK')
          + ''.join(f"  {p['out_net']}  (pod {p['tag']})\n" for p in pods))


# ---------------------------------------------------------------- main ---
def main():
    global OUT
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--ini', help='settings file (default: range.ini, else range.example.ini)')
    ap.add_argument('--students', help='student list (default: from range.ini, else student-list.csv)')
    ap.add_argument('--out', help='output folder (default: out)')
    a = ap.parse_args()
    ini = a.ini or next((os.path.join(HERE, f) for f in ('range.ini', 'range.example.ini')
                         if os.path.exists(os.path.join(HERE, f))), None)
    if not ini: die("no range.ini found. Copy range.example.ini to range.ini.")
    cfg = load_ini(ini)
    for sec in ('pods', 'proxmox', 'profiles'):
        if not cfg.has_section(sec): die(f"{ini} is missing [{sec}]")
    stu = a.students or os.path.join(HERE, cfg['pods'].get('student_list', 'student-list.csv').strip())
    pods = load_students(stu)
    OUT = a.out or os.path.join(HERE, 'out')
    if os.path.isdir(OUT):                         # keep _ready (filled secrets) out of the way, rebuild the rest
        for f in os.listdir(OUT):
            if f != '_ready':
                p = os.path.join(OUT, f)
                shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
    mode, per_node = plan(cfg, pods)
    prof = cfg['profiles']
    fw = prof.get('firewall', 'opnsense').strip()
    if fw not in ('opnsense', 'asa', 'none'): die("[profiles] firewall must be opnsense, asa or none")
    hw = prof.getboolean('cisco_core_edge', False)
    edges_for = assign_edges(cfg, pods) if hw else {}
    gen_sheet(pods)
    gen_proxmox(cfg, pods, mode, per_node)
    if fw == 'asa':
        if not cfg.has_section('asa'): die("firewall = asa needs an [asa] section")
        gen_asa(cfg, pods, edges_for)
    if hw:
        for sec in ('cisco', 'vlans'):
            if not cfg.has_section(sec): die(f"cisco_core_edge = yes needs a [{sec}] section")
        gen_cisco(cfg, pods, edges_for)
    print(f"gencfg: {len(pods)} pods, zone mode {mode}, firewall {fw}, cisco core/edge {'on' if hw else 'off'}")
    print(f"gencfg: wrote {OUT}")
    print("gencfg: next, fill the secrets:  powershell -ExecutionPolicy Bypass -File .\\Set-Secrets.ps1")


if __name__ == '__main__':
    main()
