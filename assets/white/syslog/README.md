# Range syslog server: where the logs go

This builds a syslog collector (rsyslog) on an Ubuntu Server 24.04 VM. No Docker.
Cyber City tiles, the MQTT broker, DNS servers, routers and pods send their logs here, so defenders and the scoring engine
can see what happened in one place.

It is a white cell asset: off-limits to both teams. Attackers can send it fake log lines (that is a lesson),
but they can't log in to it or erase what it has already written.

License: CC BY-SA 4.0 for this guide, GPL-3.0 for the scripts. Dire Wolf Security.

## What you need

| Item | Notes |
|---|---|
| Ubuntu Server 24.04 VM | 1 CPU, 1 GB RAM. Disk: 20 GB is plenty for a class; logs older than 14 days are deleted. A static address. |
| Address | Planned: **172.16.12.30** on WHITECELL (VLAN 120). Every network that sends logs must be able to reach it on port 514. |
| DNS name | **`syslog.lab`**, registered on the grey registrar (step 3). Devices use the name, never the address. |
| Internet, for the first setup | Only if rsyslog is missing. Ubuntu Server already has it. |

## How it stores logs

Everything that arrives on port 514 (UDP, and TCP unless turned off) is written twice:

| File | What |
|---|---|
| `/var/log/range/all.log` | Every message from every device, in order. |
| `/var/log/range/<address>.log` | One file per sending address, for example `172.16.20.41.log`. |

Each line looks like this:

```
2026-11-27T17:20:00.612767+00:00 from=172.16.20.41 host=intersection-1 traffic: preempt ns refused
```

`from=` is the address the message really came from. `host=` is the name the device **says** it has, and anyone can fake that.
If `host=intersection-1` shows up `from=` a student laptop, someone is forging logs.

This server's own logs stay in `/var/log/syslog` as usual and never mix with the range logs.

## 1. Get the files

On the VM:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/direwolfsecurity/range.git
cd range
git sparse-checkout set assets/white/syslog
cd assets/white/syslog
```

## 2. Install

```bash
sudo bash install.sh          # test mode: lists what it will do, changes nothing
sudo bash install.sh --go     # does it, then prints a status check
```

Settings are in `range-syslog.conf`: port, TCP on or off, the log folder and how many days to keep.
The script is safe to run again. Before it replaces a file, it copies the old one to `/var/backups/direwolf-syslog/<date>/`.
It checks the new rsyslog config before restarting, so a mistake does not stop logging.

## 3. Give it its DNS name

On the **primary root DNS server** (see `../../grey/root-dns/`, registrar installed):

```bash
sudo -u www-data php /opt/registrar/cli.php add-a syslog.lab 172.16.12.30
sudo registrar-apply
```

Use the server's real address. Then check from any range machine: `dig syslog.lab`.

## 4. Send logs to it

| Sender | How |
|---|---|
| MQTT broker | On the broker: `sudo bash install.sh --syslog syslog.lab --go` (see `../../grey/mqtt/`). |
| Cyber City tiles | Each tile's code sends UDP syslog to `syslog.lab`, port 514. See the tile's code steps. |
| Any Ubuntu or Debian machine | Add a file `/etc/rsyslog.d/90-range.conf` with the line `*.* @syslog.lab:514` (one `@` = UDP, `@@` = TCP), then `sudo systemctl restart rsyslog`. |
| Cisco IOS | `logging host <server address>` and `logging trap informational` |
| pfSense | Status > System Logs > Settings > Remote Logging Options. |

## 5. Watch it

```bash
sudo tail -f /var/log/range/all.log                       # everything, live
sudo grep 'host=intersection' /var/log/range/all.log      # one tile
sudo grep mosquitto /var/log/range/all.log | grep ' #$'   # who subscribed to the whole MQTT broker
```

## Check it

```bash
sudo bash install.sh --check
```

It shows the service, the listening ports, what `syslog.lab` points to, the log files, the last lines, and a self-test:
it sends itself one UDP message and looks for it in `all.log`. Self-test lines show `from=127.0.0.1`.

Send a test from another machine: `logger -n syslog.lab -P 514 -d "hello from $(hostname)"`

## If something is wrong

| Symptom | Check |
|---|---|
| Nothing arrives from a device | Send a `logger` test from a machine on the same network and watch `all.log`. If that fails too, check routing and firewalls between the networks. |
| Self-test fails | `sudo systemctl status rsyslog` and `sudo rsyslogd -N1` for config errors. Something else on port 514? `sudo ss -lnup \| grep 514`. |
| Device name does not resolve | Step 3 done? Does that device use a range DNS resolver? |
| Lines are cut off | UDP messages are limited in size. Long messages: send over TCP. |
| Disk filling up | Lower `KEEP_DAYS` in `range-syslog.conf` and re-run `--go`. |

## Status

Tested 2026-11-27 on Ubuntu 24.04 (rsyslog 8.2312) on a test machine: UDP and TCP, the per-address files, a faked `host=` name,
the MQTT broker forwarding its log here, and re-runs that change nothing.
Not yet tested: on the range VM on WHITECELL, logs from real tiles, Cisco and pfSense senders, and log rotation over several days.

Not built yet: DNS query logs from the root servers, and a feed of these logs into ForgeRange for scoring.
