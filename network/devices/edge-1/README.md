# EDGE-1: Cisco 2811 + NM-16ESW

Edge router for seat firewalls 201 - 207.
Configs: [`EDGE-1-vlan-database.txt`](EDGE-1-vlan-database.txt) (type first), then [`EDGE-1.txt`](EDGE-1.txt).
How to load them: [../README.md](../README.md#load-a-device).

Each seat has its own hardware firewall. The firewall's outside port plugs into one port on this router's
switch module. That port is the seat's own VLAN and network, with this router as the gateway (`.254`).
The router tells the core about every seat network over OSPF.

## Why a VLAN database file

The NM-16ESW switch module is older than the `vlan` command in config mode. It keeps VLANs in
`flash:vlan.dat`, outside the config. Type the VLAN database lines at the `EDGE-1#` prompt first. If you skip it,
`switchport access vlan` fails and the `Vlan` interfaces stay down.

## Ports

| Port | VLAN | Used for |
|---|---|---|
| Fa1/0 | 310 TRANSIT-1 | Uplink to CORE Fa1/0/47 |
| Fa1/1 | 201 SEAT-201 | Seat 201 firewall, outside port |
| Fa1/2 | 202 SEAT-202 | Seat 202 firewall, outside port |
| Fa1/3 | 203 SEAT-203 | Seat 203 firewall, outside port |
| Fa1/4 | 204 SEAT-204 | Seat 204 firewall, outside port |
| Fa1/5 | 205 SEAT-205 | Seat 205 firewall, outside port |
| Fa1/6 | 206 SEAT-206 | Seat 206 firewall, outside port |
| Fa1/7 | 207 SEAT-207 | Seat 207 firewall, outside port |
| Fa1/8 - 15 | none | unused, shut |
| Fa0/0, Fa0/1 | routed | spare, shut |

## Addresses

| Network | VLAN | This router | Seat firewall outside |
|---|---|---|---|
| 192.168.31.0/24 TRANSIT-1 | 310 | 192.168.31.1 (the core is 192.168.31.254) | |
| 192.168.201.0/24 | 201 | 192.168.201.254 | pick one, for example 192.168.201.1 |
| 192.168.202.0/24 | 202 | 192.168.202.254 | pick one, for example 192.168.202.1 |
| 192.168.203.0/24 | 203 | 192.168.203.254 | pick one, for example 192.168.203.1 |
| 192.168.204.0/24 | 204 | 192.168.204.254 | pick one, for example 192.168.204.1 |
| 192.168.205.0/24 | 205 | 192.168.205.254 | pick one, for example 192.168.205.1 |
| 192.168.206.0/24 | 206 | 192.168.206.254 | pick one, for example 192.168.206.1 |
| 192.168.207.0/24 | 207 | 192.168.207.254 | pick one, for example 192.168.207.1 |

Default route: 192.168.31.254 (the core). The core also hands one out over OSPF.

## Placeholders

`<ENABLE_SECRET>`, `<ADMIN_SECRET>`, `<INSTRUCTOR_IP>`: same as the core. See [../README.md](../README.md#load-a-device).

## Check it

```
show vlan-switch brief         ! the NM-16ESW's own VLAN list
show ip interface brief
show ip ospf neighbor          ! the core, FULL
show ip route                  ! O*E2 0.0.0.0/0 or S* 0.0.0.0/0 to the core
```
