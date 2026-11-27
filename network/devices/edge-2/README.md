# EDGE-2: Cisco 2811 + NM-16ESW

Edge router for seat firewalls 101 - 109.
Configs: [`EDGE-2-vlan-database.txt`](EDGE-2-vlan-database.txt) (type first), then [`EDGE-2.txt`](EDGE-2.txt).
How to load them: [../README.md](../README.md#load-a-device).

Each seat has its own hardware firewall. The firewall's outside port plugs into one port on this router's
switch module. That port is the seat's own VLAN and network, with this router as the gateway (`.254`).
The router tells the core about every seat network over OSPF.

## Why a VLAN database file

The NM-16ESW switch module is older than the `vlan` command in config mode. It keeps VLANs in
`flash:vlan.dat`, outside the config. Type the VLAN database lines at the `EDGE-2#` prompt first. If you skip it,
`switchport access vlan` fails and the `Vlan` interfaces stay down.

## Ports

| Port | VLAN | Used for |
|---|---|---|
| Fa1/0 | 320 TRANSIT-2 | Uplink to CORE Fa1/0/48 |
| Fa1/1 | 101 SEAT-101 | Seat 101 firewall, outside port |
| Fa1/2 | 102 SEAT-102 | Seat 102 firewall, outside port |
| Fa1/3 | 103 SEAT-103 | Seat 103 firewall, outside port |
| Fa1/4 | 104 SEAT-104 | Seat 104 firewall, outside port |
| Fa1/5 | 105 SEAT-105 | Seat 105 firewall, outside port |
| Fa1/6 | 106 SEAT-106 | Seat 106 firewall, outside port |
| Fa1/7 | 107 SEAT-107 | Seat 107 firewall, outside port |
| Fa1/8 | 108 SEAT-108 | Seat 108 firewall, outside port |
| Fa1/9 | 109 SEAT-109 | Seat 109 firewall, outside port |
| Fa1/10 - 15 | none | unused, shut |
| Fa0/0, Fa0/1 | routed | spare, shut |

## Addresses

| Network | VLAN | This router | Seat firewall outside |
|---|---|---|---|
| 192.168.32.0/24 TRANSIT-2 | 320 | 192.168.32.1 (the core is 192.168.32.254) | |
| 192.168.101.0/24 | 101 | 192.168.101.254 | pick one, for example 192.168.101.1 |
| 192.168.102.0/24 | 102 | 192.168.102.254 | pick one, for example 192.168.102.1 |
| 192.168.103.0/24 | 103 | 192.168.103.254 | pick one, for example 192.168.103.1 |
| 192.168.104.0/24 | 104 | 192.168.104.254 | pick one, for example 192.168.104.1 |
| 192.168.105.0/24 | 105 | 192.168.105.254 | pick one, for example 192.168.105.1 |
| 192.168.106.0/24 | 106 | 192.168.106.254 | pick one, for example 192.168.106.1 |
| 192.168.107.0/24 | 107 | 192.168.107.254 | pick one, for example 192.168.107.1 |
| 192.168.108.0/24 | 108 | 192.168.108.254 | pick one, for example 192.168.108.1 |
| 192.168.109.0/24 | 109 | 192.168.109.254 | pick one, for example 192.168.109.1 |

Default route: 192.168.32.254 (the core). The core also hands one out over OSPF.

## Placeholders

`<ENABLE_SECRET>`, `<ADMIN_SECRET>`, `<INSTRUCTOR_IP>`: same as the core. See [../README.md](../README.md#load-a-device).

## Check it

```
show vlan-switch brief         ! the NM-16ESW's own VLAN list
show ip interface brief
show ip ospf neighbor          ! the core, FULL
show ip route                  ! O*E2 0.0.0.0/0 or S* 0.0.0.0/0 to the core
```
