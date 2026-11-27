# devices

The real Cisco gear in the classroom range, as built, cleaned up and ready to load again.

`gencfg.py` (one folder up) builds configs for a range of any size. These files are the other half:
the exact configs running on our three boxes today. Use them to rebuild our range, or as a worked example
for your own.

| Folder | Device | Job |
|---|---|---|
| [`core/`](core/) | Catalyst 3750v2-48PS (48-port layer 3 switch) | The middle of the range. Gateway for every shared network, DHCP for the city, the one cable to the outside world. |
| [`edge-1/`](edge-1/) | Cisco 2811 + NM-16ESW (16-port switch module) | Seat firewalls 201-207. |
| [`edge-2/`](edge-2/) | Cisco 2811 + NM-16ESW | Seat firewalls 101-109. |

The classroom switches are **not** here. They belong to the school network, not the range.

## How it fits together

```
                 outside gateway (192.168.33.1)
                          |
                 red cable, Fa1/0/30, VLAN 330
                          |
   GREY, WHITE, RED --- CORE --- Gi1/0/1 trunk --- Proxmox host (grey/white VMs)
   TARGETS, CITY          |
             Fa1/0/47     |     Fa1/0/48
            VLAN 310      |     VLAN 320
                |                   |
             EDGE-1              EDGE-2
          seats 201-207       seats 101-109
```

## Address plan

Every shared network's gateway is `.254` on the core.

| VLAN | Name | Network | Gateway | What lives there |
|---|---|---|---|---|
| 110 | GREY | 172.16.11.0/24 | CORE .254 | The fake internet: DNS .10, NTP .123, MQTT .83 (planned) |
| 120 | WHITECELL | 172.16.12.0/24 | CORE .254 | Scoring .20, syslog .30. Guarded by `WHITE-PROTECT`. |
| 130 | REDCELL | 172.16.13.0/24 | CORE .254 | Attackers |
| 310 | TRANSIT-1 | 192.168.31.0/24 | CORE .254, EDGE-1 .1 | Core to EDGE-1 |
| 320 | TRANSIT-2 | 192.168.32.0/24 | CORE .254, EDGE-2 .1 | Core to EDGE-2 |
| 330 | UPLINK | 192.168.33.0/24 | CORE .254, outside gateway .1 | The one way out |
| 340 | CITY | 192.168.34.0/24 | CORE .254 | Cyber City tiles. DHCP .100-.150. |
| 410 | TARGETS-A | 192.168.200.0/24 | CORE .254 | Physical targets |
| 420 | TARGETS-B | 192.168.210.0/24 | CORE .254 | Target VMs on the Proxmox host (trunk only, no access ports) |
| 999 | PARKED | none | none | Unused ports and the trunk's native VLAN |
| 201-207 | SEAT-201 ... | 192.168.201.0/24 ... 192.168.207.0/24 | EDGE-1 .254 | Seat firewall outside networks |
| 101-109 | SEAT-101 ... | 192.168.101.0/24 ... 192.168.109.0/24 | EDGE-2 .254 | Seat firewall outside networks |

Seat VLANs live only on their edge router. The core learns the seat networks from the edges over OSPF.

## Load a device

1. Copy the config to your computer and rename it, for example `CORE-ready.txt`. Never commit the filled copy.
2. Open it in Notepad. Use Replace to fill in:
   - `<ENABLE_SECRET>`: the enable password.
   - `<ADMIN_SECRET>`: the password for the local `admin` user.
   - `<INSTRUCTOR_IP>`: your computer's address. It is allowed to SSH to the gear.

   At least 8 characters. No spaces, `?` or quotes. Use different passwords from any other network.
3. Connect the console cable. In PuTTY: serial, 9600 baud.
4. Wipe the old config: `write erase`, then `reload`. Say `no` to the setup dialog.
5. On the 2811s only: type the lines in `EDGE-n-vlan-database.txt` first.
6. `enable`, `configure terminal`, then paste the config.
7. Make the SSH key: `crypto key generate rsa modulus 2048`. SSH does not work until you do.
8. Save: `end`, then `copy running-config startup-config`.
9. Delete your filled copy.

## What we fixed (and what to teach from it)

The configs on the real gear had problems. Each one is a good lesson.

| Problem | Where | Why it matters | Fix |
|---|---|---|---|
| A `password 7` login | CORE | Type 7 is not encryption. Free websites turn it back into the password in a second. | `secret` for every login |
| `secret 5` (MD5) hashes | CORE | MD5 hashes crack fast with a GPU. They are safe only if nobody sees them. We shared them in a log. | New passwords, and keep configs private. This IOS can't do stronger hashes; newer IOS can (`algorithm-type scrypt`). |
| No enable password, no logins | both 2811s | Anyone on the console is in charge at once. | `enable secret`, a local user, `login local` |
| `login` on vty with no password | both 2811s | Telnet is refused, so it looks safe. Add one password later and telnet is wide open. | `login local`, `transport input ssh`, and an access list |
| `ip source-route` | both 2811s | Lets a sender choose the path through your network. Old trick to get around filters. | `no ip source-route` |
| `ip http server` | 2811 (EDGE-2) | A web login page, in plain text, nobody needs. | `no ip http server` |
| `vstack` (Smart Install) | CORE | Smart Install lets anyone on the network rewrite the switch's config with no password (CVE-2018-0171). | `no vstack` |
| Wrong port descriptions | EDGE-1, CORE | EDGE-1 said it plugged into Fa1/0/48. It is on Fa1/0/47. Bad labels waste hours in an outage. | Descriptions match the cables |
| Edges did not talk to the core | both 2811s | They had a default route out, but the core had no route back to the seat networks. | OSPF on the transit VLAN |
| No time source | all | Logs from three boxes with three clocks can't be lined up. | `ntp server 172.16.11.123` (the grey NTP Pi) |

**If your own gear's configs were ever shared** (a log, a screenshot, a forum post), change every password on it,
even the hashed ones.

## Modes

The core carries the red-team access lists but does not apply them. To switch modes, use the files that
`gencfg.py` writes to `out/cisco/modes/` with `cisco_core_edge = yes`, or type the same lines:

- **CLOSED**: `interface Fa1/0/30`, `shutdown`. Also pull the red cable.
- **RED TEAM**: `interface Vlan330`, `ip access-group UPLINK-IN-REDTEAM in`, `ip access-group UPLINK-OUT-REDTEAM out`.
- **BUILD** (normal): undo either one.
