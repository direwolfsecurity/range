# Range MQTT broker: the message board for Cyber City

This builds an MQTT broker (Mosquitto) on an Ubuntu Server 24.04 VM. No Docker.
Cyber City tiles (Arduino Nano RP2040 Connect, ESP32) publish what they are doing to it, and listen to it for commands.
Students, dashboards and the scoring engine can watch it too.

It has two modes, switched with one command:

| Mode | Who can connect | Use it for |
|---|---|---|
| `open` | Anyone. No login, no rules. Anyone can read and write every topic. | Attack labs: listen to the whole city, send fake commands. |
| `secure` | Only logins listed in `users.conf`. Each tile may only use its own topics. Optional TLS. | Defend labs: lock the city down, then see what is still weak. |

License: CC BY-SA 4.0 for this guide, GPL-3.0 for the scripts. Dire Wolf Security.

## What you need

| Item | Notes |
|---|---|
| Ubuntu Server 24.04 VM | 1 CPU, 1 GB RAM, 10 GB disk is plenty. A static address. |
| Address | Proposed: **172.16.11.83** on GREY (VLAN 110). "83" to match port 1883. Not final until `network\registry.csv` exists. |
| DNS name | **`mqtt.lab`**, registered on the grey registrar (step 3). Tiles use the name, never the address. |
| Internet, for the first setup | To install the Mosquitto package. Not needed afterwards. |

The tiles must be able to reach GREY, and the city Wi-Fi must hand out a range DNS resolver, or `mqtt.lab` will not resolve on the tiles.

## The topic standard

Every tile uses the same topic layout. `<tile>` is the tile type, `<id>` is its number.

| Topic | Who writes | What |
|---|---|---|
| `cybercity/<tile>/<id>/state` | the tile | Its current state as JSON. Retained, so a new listener sees it at once. |
| `cybercity/<tile>/<id>/cmd` | others | Commands as plain text, for example `allred` or `preempt ns`. |
| `cybercity/<tile>/<id>/online` | the tile | Retained `online`. The broker sends `offline` when the tile drops (its "last will"). |
| `cybercity/<tile>/<id>/event` | the tile | One line per notable thing: a command taken, a command refused. Not retained. |
| `cybercity/city/alert` | the teacher | City-wide announcements. Every tile listens. |

For example, the first intersection is `cybercity/intersection/1/state`, and its login in secure mode is `intersection-1`.
The full standard, with each tile's JSON and commands, is written up with the tiles in the Cyber City project.

## 1. Get the files

On the VM:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/direwolfsecurity/range.git
cd range
git sparse-checkout set assets/grey/mqtt
cd assets/grey/mqtt
```

## 2. Install

```bash
sudo bash install.sh          # test mode: lists what it will do, changes nothing
sudo bash install.sh --go     # does it, then prints a status check
```

It starts in **open** mode (set in `mqtt.conf`). It also makes a password for every name in `users.conf`
and prints them **once**, even in open mode, so they are ready when you switch to secure. Write them down.
Only the password hashes are kept on the server (`/etc/mosquitto/passwd`). No password is ever stored in plain text or in this repo.

The script is safe to run again. Before it replaces a file, it copies the old one to `/var/backups/direwolf-mqtt/<date>/`.

## 3. Give it its DNS name

On the **primary root DNS server** (see `../root-dns/`, registrar installed):

```bash
sudo -u www-data php /opt/registrar/cli.php add-a mqtt.lab 172.16.11.83
sudo registrar-apply
```

Use the broker's real address. Then check from any range machine: `dig mqtt.lab` should answer with that address.
(The registrar also adds `www.mqtt.lab`. That does no harm.)

## 4. Switch modes

```bash
sudo bash install.sh --mode secure --go     # logins and rules on
sudo bash install.sh --mode open --go       # everything open again
```

The mode you set is remembered (in `/etc/mosquitto/direwolf-settings`), so a later `--go` keeps it.
`--forget` goes back to what `mqtt.conf` says. Switching restarts the broker; tiles reconnect by themselves within a few seconds.
Logins are kept while the broker is open, so you do not need to hand out new passwords when you switch back.

A halfway step for labs: `--mode secure --anonymous-read yes`. Anyone may still **watch** the city (`cybercity/#`),
but nobody without a login can **control** it.

## 5. Logins and rights (`users.conf`)

Each line is one login. The file says what each kind may do:

```
teacher          teacher                                   # everything
monitor          monitor                                   # read everything, write nothing (scoring, blue team)
intersection-1   tile                                      # cybercity/intersection/1/#, plus read cybercity/city/alert
firestation-1    tile      write cybercity/intersection/+/cmd   # extra right: preempt any intersection
```

After you change it, run `sudo bash install.sh --go`.

- A new name gets a password, shown once.
- A name you delete loses its login.
- Lost a password: `sudo bash install.sh --new-password intersection-1 --go` makes a new one. Put it in that tile's `arduino_secrets.h`.

The rules the broker actually uses are written to `/etc/mosquitto/acl`. Read it to see exactly who may do what. Edit `users.conf`, not that file.

## 6. Test it from a laptop

Install a client: `sudo apt install mosquitto-clients` on Linux, or MQTT Explorer (https://mqtt-explorer.com) on Windows.

Open mode:

```bash
mosquitto_sub -h mqtt.lab -t 'cybercity/#' -v                 # watch the whole city
mosquitto_pub -h mqtt.lab -t cybercity/intersection/1/cmd -m allred
```

Secure mode:

```bash
mosquitto_sub -h mqtt.lab -u monitor -P '<password>' -t 'cybercity/#' -v
mosquitto_pub -h mqtt.lab -u teacher -P '<password>' -t cybercity/city/alert -m "drill at 10:00"
```

In secure mode, a tile that writes to a topic it may not use is **not** told. The broker just drops the message.
That is how MQTT works. Watch the log (step 8) to see who connects and who subscribes to what.

## 7. Encryption (TLS, optional)

```bash
sudo bash install.sh --tls yes --go      # adds port 8883; port 1883 stays on
sudo bash install.sh --cert              # prints the certificate, to paste into code or save as mqtt-lab.crt
```

The script makes a self-signed certificate for `mqtt.lab` and the server's address, valid for 10 years.
Clients trust that one file. No certificate authority key is made or kept.
When the range certificate authority (`../ca/`, not built yet) exists, put its `server.crt` and `server.key` in `/etc/mosquitto/certs/` and re-run; the script keeps certificates it finds there.

```bash
mosquitto_sub -h mqtt.lab -p 8883 --cafile mqtt-lab.crt -u monitor -P '<password>' -t 'cybercity/#' -v
```

Which boards can use it:

| Board | TLS to `mqtt.lab` |
|---|---|
| ESP32 | Yes. `WiFiClientSecure` with `setCACert()` and the certificate text from `--cert`. |
| Nano RP2040 Connect | Not in practice. Its Wi-Fi chip only trusts certificates loaded with the firmware updater, which fetches them from real internet sites. Keep these tiles on port 1883 with a login. |
| Laptops, scoring, dashboards | Yes. |

That is why port 1883 stays on. It is also a lab: logins on 1883 cross the network as readable text. Capture one with Wireshark.

## 8. Logs

The broker logs every connection, disconnection, subscription and login failure to `/var/log/mosquitto/mosquitto.log`.

```bash
sudo tail -f /var/log/mosquitto/mosquitto.log
```

A line like `... 0 #` means someone subscribed to everything. That is the first thing an attacker does.

To also send the log to the range syslog server (`syslog.lab`, in `../../white/syslog/`):

```bash
sudo bash install.sh --syslog syslog.lab --go      # --syslog none turns it off
```

## Check it

```bash
sudo bash install.sh --check
```

It shows the service, the mode, the ports, the logins, what `mqtt.lab` points to, the last log lines, and a self-test
as a client with no login: "can read AND write" in open mode, "refused" in secure mode.

## If something is wrong

| Symptom | Check |
|---|---|
| Tile says it can't find the broker | `dig mqtt.lab` from a range machine. Step 3 done? Does the city Wi-Fi hand out a range resolver? |
| Laptop gets "Connection refused" | Is it running? `--check`. Is a firewall in the way? The script opens the ports if ufw is on. |
| "not authorised" | Secure mode is on. Use a login, check the password, check the name is in `users.conf` and you re-ran `--go`. |
| Tile connects but nothing shows up | It is writing to a topic it may not use. Compare its topics with `/etc/mosquitto/acl`. |
| `mosquitto` will not start | `sudo journalctl -u mosquitto -n 30` and the log file. A broken `users.conf` stops the script before it changes anything. |
| TLS: "certificate verify failed" | Connect by name (`mqtt.lab`), not by address, unless the address is in the certificate (`--cert` shows it). |
| Changed the server's address | Re-do step 3. With TLS, delete `/etc/mosquitto/certs/server.*` and re-run to make a new certificate. |
| `Warning: Address family not supported` in the log | The VM has IPv6 turned off. Harmless. |

## Status

Tested 2026-11-27 on Ubuntu 24.04 (Mosquitto 2.0.18) on a test machine: open mode, secure mode with every
`users.conf` rule (own topics allowed, other tiles' topics dropped, fire station preempt allowed, monitor read-only),
anonymous read, TLS on 8883, new passwords, removed users, the syslog forward file, and re-runs that change nothing.
Not yet tested: on the range VM on GREY, the DNS name through the registrar, and real tiles.

Ideas not built: WebSockets (port 9001) for a browser dashboard, and per-tile rate limits.
