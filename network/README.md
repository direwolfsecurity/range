# network

Build every pod on the range from one class list.

You write two files: `student-list.csv` (who) and `range.ini` (how). `gencfg.py` writes the Proxmox setup script,
an address sheet, and, if you have the gear, Cisco firewall, core and edge configs. `Set-Secrets.ps1` fills in
the passwords on your computer and makes a password sheet to hand out.

Works for one student on one Proxmox box, or a room of 25 with a hardware firewall at every seat.

## Quick start (all virtual, one Proxmox host)

1. Copy the examples and edit them:
   ```
   copy range.example.ini range.ini
   copy student-list.example.csv student-list.csv
   ```
   In `student-list.csv`, one row per pod. In `range.ini`, set `nodes` to your Proxmox node name.
2. Build: `python gencfg.py` (Python 3.8 or newer, nothing to install).
3. Fill the passwords: `powershell -ExecutionPolicy Bypass -File .\Set-Secrets.ps1`
4. Copy `out\_ready\proxmox\pods.sh` to the Proxmox host and run it once as root: `bash pods.sh`
5. Print `out\_ready\pod-passwords.csv`. Delete `out\_ready\`.

Each student can now log in to Proxmox and see only their own pool and their own three networks.

## The class list

`student-list.csv`. Only `pod` is required.

| Column | What | Example |
|---|---|---|
| `pod` | Pod number, from 1 | `3` |
| `id` | Proxmox login name. Letters, digits, `-`, `_` | `s03` |
| `name` | Optional. Only ever written to the local password sheet | |
| `status` | `active` (default), `spare` (networks built, no login), `instructor` | `active` |
| `host` | Proxmox node for this pod. Blank = spread across `nodes` in order | `pve2` |
| `fw_mgmt` | Hardware firewall management address (`asa` profile) | `192.0.2.13` |
| `bridge`, `nic` | Per-pod mode: override the bridge or NIC for this pod | `vmbr103`, `enp2s0` |

Your real list is git-ignored. Only `student-list.example.csv` is published. Use IDs, not full names, as logins.

## What every pod gets

The inside and DMZ networks are **the same in every pod**, so one lab guide works for every student.

| | Address |
|---|---|
| Outside network | 192.168.(100 + pod).0/24. Pod 3 = 192.168.103.0/24 |
| Firewall outside | .1 |
| Range gateway | .254 |
| Kali | .100 |
| Published DMZ web | .50 |
| Inside | 10.10.10.0/24. Firewall .254, AD/DNS .10, DHCP .50-.79 |
| DMZ | 10.9.9.0/24. Firewall .254, web .50 |
| VM IDs | 1000 + pod x 10, ten per pod. Pod 3 = 1030-1039 |

`out\pods.csv` lists every pod's names, VLAN tags and addresses.

## Two ways to wire the pods (`zone_mode`)

Pods are isolated with Proxmox SDN: each pod has three VNets (outside, inside, DMZ), and each student may use only their own.

- **`shared`** (default): one SDN zone on one VLAN-aware bridge (`vmbr1`). Every pod network gets its own VLAN tag
  (outside 1000 + pod, inside 2000 + pod, DMZ 3000 + pod). Use this when the firewalls are VMs.
- **`per-pod`**: one zone per pod on its own bridge and physical NIC, and the same tags inside every pod
  (outside 100, inside 10, DMZ 50). Use this when every pod has a hardware firewall on its own cable.
  `gencfg.py` writes the bridge lines to add to each node's `/etc/network/interfaces`.

## Profiles

Set in `range.ini` under `[profiles]`.

| Setting | What you get |
|---|---|
| `firewall = opnsense` (default) | Nothing extra yet, or, if `[templates] firewall` names an OPNsense template, a clone per pod with its three NICs on the pod's VNets. Also clones a Kali template if you name one. |
| `firewall = asa` | One Firepower 1010 / ASA config per pod in `out\asa\`. |
| `firewall = none` | Proxmox only. |
| `cisco_core_edge = yes` | Core switch and edge router configs in `out\cisco\`, sized to the class: one edge per 15 pods. Also CLOSED and RED TEAM mode switches, and the static routes your outside gateway needs. |

`gencfg.py` refuses to write anything if two networks overlap or two VLAN tags collide.

## Not here yet

- **The range router for `shared` mode.** Something has to be `.254` on each pod's outside network. With
  `cisco_core_edge` the edge routers do it. For an all-virtual range it will be a router VM on the grey cell.
- **The OPNsense template build guide**, including the API key that [ForgeRange](https://github.com/direwolfsecurity/forgerange)
  uses to change firewall rules during a lab.

## Rules

- No passwords in any file that gets committed. Everything secret is a placeholder until `Set-Secrets.ps1`.
- `out\` and `student-list.csv` are git-ignored. Never commit `out\_ready\`.
- Edit `range.ini` or the class list and run `gencfg.py` again. Never hand-edit files in `out\`.
