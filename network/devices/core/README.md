# CORE: Catalyst 3750v2-48PS

The layer 3 switch in the middle of the range. Config: [`CORE.txt`](CORE.txt).
How to load it: [../README.md](../README.md#load-a-device).

It does five jobs:

1. **Gateway** (`.254`) for every shared network: grey, white, red, city, targets.
2. **DHCP** for the city VLAN (`.100` to `.150`). DNS points at the grey DNS server, 172.16.11.10.
3. **OSPF** with the two edge routers, so it learns the seat networks. It also hands them the default route.
4. **The uplink**: one red cable to the outside gateway. Pull it, or shut Fa1/0/30, and the range is air-gapped.
5. **Guards the white cell** with `WHITE-PROTECT`: from outside, only replies, scoring web, syslog and the instructor get in.

## Ports

| Port | VLAN | Used for |
|---|---|---|
| Fa1/0/1 - 8 | 110 GREY | Physical grey assets (NTP Pi, and so on) |
| Fa1/0/9 - 12 | 120 WHITECELL | White cell machines |
| Fa1/0/13 - 20 | 130 REDCELL | Red team machines |
| Fa1/0/21 - 28 | 410 TARGETS-A | Physical targets |
| Fa1/0/29 | 999 | unused, shut |
| Fa1/0/30 | 330 UPLINK | **The red cable** to the outside gateway |
| Fa1/0/31 - 35 | 999 | unused, shut |
| Fa1/0/36 | 340 CITY | City wireless access point |
| Fa1/0/37 - 40 | 340 CITY | City wired tiles |
| Fa1/0/41 - 46 | 999 | unused, shut |
| Fa1/0/47 | 310 TRANSIT-1 | EDGE-1 Fa1/0 |
| Fa1/0/48 | 320 TRANSIT-2 | EDGE-2 Fa1/0 |
| Gi1/0/1 | trunk: 110, 120, 130, 340, 410, 420 (native 999) | Proxmox host, 2nd NIC |
| Gi1/0/2 | 999 | reserved for a 2nd link to the Proxmox host, shut |
| Gi1/0/3 - 4 | 999 | unused, shut |

## Addresses on the core

| Interface | Address |
|---|---|
| Vlan110 GREY | 172.16.11.254/24 |
| Vlan120 WHITECELL | 172.16.12.254/24 |
| Vlan130 REDCELL | 172.16.13.254/24 |
| Vlan310 TRANSIT-1 | 192.168.31.254/24 |
| Vlan320 TRANSIT-2 | 192.168.32.254/24 |
| Vlan330 UPLINK | 192.168.33.254/24. Default route to 192.168.33.1. |
| Vlan340 CITY | 192.168.34.254/24 |
| Vlan410 TARGETS-A | 192.168.200.254/24 |
| Vlan420 TARGETS-B | 192.168.210.254/24 |

## The outside gateway

Whatever is on the other end of the red cable needs:

- an address of 192.168.33.1/24 on that port, and
- static routes back to the range through 192.168.33.254: 172.16.11.0/24, 172.16.12.0/24, 172.16.13.0/24,
  192.168.34.0/24, 192.168.200.0/24, 192.168.210.0/24, and the seat networks 192.168.101-109 and 192.168.201-207.

If the outside gateway can hand out VPN addresses to a red team, use 10.250.250.0/24. That is the pool the
red-team access lists allow.

## Placeholders

| Placeholder | Fill with |
|---|---|
| `<ENABLE_SECRET>` | The enable password |
| `<ADMIN_SECRET>` | Password for the local `admin` user |
| `<INSTRUCTOR_IP>` | Your computer's address. Used in `MGMT-ONLY`, `WHITE-PROTECT` and the red-team lists. |
| `<MGMT_NET>`, `<MGMT_MASK>` | Optional, commented out. Your own management network, if it needs its own route. |

## Check it

```
show vlan brief
show ip interface brief
show ip ospf neighbor          ! EDGE-1 and EDGE-2, both FULL
show ip route ospf             ! the seat networks
show ip dhcp binding           ! city tiles that got an address
show access-lists WHITE-PROTECT
```
