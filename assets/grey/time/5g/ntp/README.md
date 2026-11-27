# Range time server: GPS-fed NTP on a Raspberry Pi

This turns a Raspberry Pi with a Waveshare 5G HAT into an NTP server.
It gets time from GPS satellites, so it keeps working when the range has no internet. It needs no SIM card.
It also runs a web page that shows the satellites and the time-server status.

License: CC BY-SA 4.0 for this guide, GPL-3.0 for the scripts. Dire Wolf Security.

## What you need

| Item | Notes |
|---|---|
| Raspberry Pi 4 or 5 | Raspberry Pi OS (Bookworm or later). |
| Waveshare 5G HAT | Sold with either a SIMCom SIM8200EA-M2 (https://www.waveshare.com/wiki/SIM8200EA-M2_5G_HAT) or a Quectel RM520N-GL (https://www.waveshare.com/wiki/RM520N-GL_5G_HAT) module. The scripts work with both. Connect the HAT's USB cable to the Pi. |
| GNSS antenna | On the module's GNSS connector (ANT5 on the SIM8200EA-M2), printed side down, with a view of the sky. A window sill is usually enough. |
| Internet, for the first setup | Packages, the map library, and tuning the offset. Not needed afterwards. |

## How it fits together

```
5G modem (SIMCom SIM8200EA-M2 or Quectel RM520N-GL)
  /dev/ttyUSB2  AT commands    <- gnss_on.py turns the GNSS engine on (boot, then every 5 minutes)
  /dev/ttyUSB1  NMEA sentences -> gpsd -> chrony -> NTP (UDP 123) to the range
                                       -> gps_snapshot_daemon.py -> gps.json, satellites.json -> web page
```

Only one program may read `/dev/ttyUSB1`. gpsd reads it and shares the data with chrony and with the web page.

To see which module you have: `sudo python3 /opt/gpsdash/at.py /dev/ttyUSB2 'ATI'` after installing.
`gnss_on.py` reads this itself and sends `AT+CGPS=1` (SIMCom) or `AT+QGPS=1` (Quectel).

## Quick start

On the Pi:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/direwolfsecurity/range.git
cd range
git sparse-checkout set assets/grey/time/5g/ntp
cd assets/grey/time/5g/ntp
sudo bash install.sh          # test mode: lists what it will do, changes nothing
sudo bash install.sh --go     # does it, then prints a status check
```

A cold start can take 1 to 15 minutes to get a fix. Check progress at any time:

```bash
sudo bash install.sh --check
```

Then open `http://<Pi address>/` in a browser.

The script is safe to run again. Before it replaces a file, it copies the old one to `/var/backups/direwolf-ntp/<date>/`.

## Tune the offset (once, with internet)

GPS time reaches the Pi over USB a fraction of a second late. chrony can measure how late, but only while it can also see internet time servers.

1. Leave the Pi running with internet for 30 minutes after it gets a fix.
2. Run `chronyc sourcestats`. Read the `Offset` column on the `GPS` line. Example: `-180ms`.
3. Flip the sign and give it in seconds: `sudo bash install.sh --offset 0.180 --go`
4. Wait 10 minutes. The `GPS` offset in `chronyc sourcestats` should now be within about 20 ms of zero.

The script keeps this offset when you run it again, unless you give a new `--offset`.

In `chronyc sources`, `*` marks the source in use. With internet, chrony usually prefers an internet server and marks GPS `+` or `-`. That is normal.
Without internet, GPS is the only source and gets the `*`.

## Move it onto the range

1. Take the Pi off the internet.
2. Give it its range address. Dire Wolf uses 172.16.11.123 on the GREY network (VLAN 110), gateway 172.16.11.254.
3. Run `sudo bash install.sh --check`. The `GPS` line should get the `*` within a few minutes.

## Point clients at it

| Device | Command |
|---|---|
| Cisco IOS (3750, 2811) | `ntp server <Pi address>` |
| Cisco ASA / Firepower | `ntp server <Pi address> source outside` |
| Proxmox, Linux with chrony | `server <Pi address> iburst` in `/etc/chrony/chrony.conf` |
| Windows domain controller | `w32tm /config /manualpeerlist:<Pi address> /syncfromflags:manual /reliable:yes /update` |

Test from another machine:

| From | Command |
|---|---|
| Linux | `chronyd -Q "server <Pi address> iburst"` |
| Windows | `w32tm /stripchart /computer:<Pi address> /samples:3` |
| On the Pi | `sudo chronyc clients` lists who has asked |

chrony answers anyone in 10.0.0.0/8, 172.16.0.0/12 and 192.168.0.0/16. Change the `allow` lines in `etc/chrony/conf.d/direwolf-gps.conf` for a different network.

## How accurate is it?

About 10 to 50 ms after tuning. USB carries no pulse-per-second signal, so this is not a microsecond clock.
It is far better than a range needs: Kerberos allows 5 minutes, and matching logs needs about 1 second.

## What the script installs

| File in this folder | Goes on the Pi at |
|---|---|
| `etc/default/gpsd` | `/etc/default/gpsd` |
| `etc/chrony/conf.d/direwolf-gps.conf` | `/etc/chrony/conf.d/direwolf-gps.conf` |
| `opt/gpsdash/gnss_on.py` | `/opt/gpsdash/gnss_on.py` |
| `opt/gpsdash/at.py` | `/opt/gpsdash/at.py` (sends AT commands and prints replies; use it instead of minicom) |
| `opt/gpsdash/gps_snapshot_daemon.py` | `/opt/gpsdash/gps_snapshot_daemon.py` |
| `systemd/gnss-on.service`, `gnss-on.timer` | `/etc/systemd/system/` |
| `systemd/gps-snapshot.service` | `/etc/systemd/system/` |
| `html/index.html` | `/var/www/html/index.html` |

It also installs the packages `gpsd gpsd-clients chrony python3-serial apache2 minicom wget`
and downloads Leaflet 1.9.4 (https://leafletjs.com, BSD 2-Clause) into `/var/www/html/vendor/leaflet/`. Leaflet is not stored in this repo.
The map background needs internet. Without it the map is grey, but the rest of the page works.
To use the range's own tile server instead, change `TILE_URL` at the top of the script in `html/index.html`.

Settings at the top of `install.sh`:

| Setting | Default | Change it when |
|---|---|---|
| `NMEA_PORT` | `/dev/ttyUSB1` | Your modem lists its ports in a different order (`dmesg \| grep ttyUSB`). |
| `AT_PORT` | `/dev/ttyUSB2` | Same. |
| `DISABLE_MODEMMANAGER` | `yes` | You put a SIM in and want 5G data. ModemManager needs the AT port for that. |

## If something is wrong

| Symptom | Check |
|---|---|
| Web page status `no_gpsd` | `systemctl status gpsd`. Is something else holding the port? `sudo fuser /dev/ttyUSB1` |
| Status `no_nmea` | GNSS is off. `sudo python3 /opt/gpsdash/gnss_on.py`, then `journalctl -u gnss-on` |
| Status `no_fix` for more than 15 minutes | Antenna on the wrong connector, or no view of the sky. |
| `GPS` line in `chronyc sources` has Reach 0 | gpsd has no fix yet, or is not running with `-n`. |
| `cat /dev/ttyUSB1` shows `$G...` sentences but gpsd reports nothing | gpsd is probing the modem, which makes the SIMCom go quiet. `GPSD_OPTIONS` in `/etc/default/gpsd` must include `-b` (read-only). Test by hand: `sudo systemctl stop gpsd.socket gpsd; sudo timeout 20 gpsd -N -n -b -D 3 /dev/ttyUSB1 2>&1 \| tail; sudo systemctl start gpsd.socket gpsd` |
| `GPS` marked `x` in `chronyc sources` | Offset not tuned yet. See "Tune the offset". |
| `gnss_on.py` gets no answer or garbled answers | ModemManager or minicom is using the AT port. |
| Need to talk to the modem by hand | `sudo python3 /opt/gpsdash/at.py /dev/ttyUSB2 'ATI' 'AT+CGPS?'` (use `AT+QGPS?` on a Quectel). It turns on detailed errors first. If you use minicom instead, exit with Ctrl-A then X; killing it leaves the port locked. |
