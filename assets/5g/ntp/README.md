# Range time server: GPS-fed NTP on the "5g" Pi

This turns the Pi with the Waveshare RM520N-GL 5G HAT into the NTP server for the cyber range.
It gets time from GPS satellites, so it works with the range air-gapped (CLOSED mode) and needs no SIM card.
The satellite dashboard web page keeps working.

Licence: CC BY-SA 4.0, Dire Wolf Security.

## How it fits together

```
RM520N-GL modem
  /dev/ttyUSB2  AT commands   <- gnss_on.py turns the GNSS engine on
  /dev/ttyUSB1  NMEA sentences -> gpsd -> chrony  -> NTP, UDP 123, to the range
                                       -> gps_snapshot_daemon.py -> gps.json, satellites.json -> web page
```

Only one program may read `/dev/ttyUSB1`. Last year the dashboard daemon read it directly.
Now gpsd reads it and shares the data with both chrony and the dashboard.

## What is in this folder

| File here | Goes on the Pi at |
|---|---|
| `etc/default/gpsd` | `/etc/default/gpsd` |
| `etc/chrony/conf.d/direwolf-gps.conf` | `/etc/chrony/conf.d/direwolf-gps.conf` |
| `opt/gpsdash/gnss_on.py` | `/opt/gpsdash/gnss_on.py` |
| `opt/gpsdash/gps_snapshot_daemon.py` | `/opt/gpsdash/gps_snapshot_daemon.py` (replaces version 1) |
| `systemd/gnss-on.service`, `gnss-on.timer` | `/etc/systemd/system/` |
| `systemd/gps-snapshot.service` | `/etc/systemd/system/` (replaces the old one) |
| `html/index.html` | `/var/www/html/index.html` (replaces the old one) |

The files pulled off the Pi before this change are one folder up, in `html\` and `systemd\`. Keep them as the backup.

## Before you start

- The GNSS antenna must be on the HAT's GNSS connector and must see the sky. A window sill is usually enough.
- Copy this folder to the Pi, for example to `~/5g-ntp`. The steps below assume that path.
- The Pi needs internet for step 1 only.

## Steps

### 1. Install the packages

```bash
sudo apt update
sudo apt install -y gpsd gpsd-clients chrony python3-serial minicom
```

Installing chrony removes `systemd-timesyncd`. That is expected.

### 2. Turn on GNSS in the modem

Stop the old daemon first, so nothing holds the ports.

```bash
sudo systemctl stop gps-snapshot.service gpsd.socket gpsd.service
sudo mkdir -p /opt/gpsdash
sudo cp ~/5g-ntp/opt/gpsdash/*.py /opt/gpsdash/
sudo python3 /opt/gpsdash/gnss_on.py
```

It should print `OK`, or `GNSS already on`. Then check that sentences arrive:

```bash
sudo timeout 5 cat /dev/ttyUSB1
```

You should see lines starting with `$GPGGA`, `$GPRMC`, `$GPGSV`. Empty fields (`,,,,`) mean no fix yet, which is fine at this point.

If the script fails, do it by hand: `sudo minicom -D /dev/ttyUSB2`, then type `AT+QGPS?` and `AT+QGPS=1`.
Exit minicom with Ctrl-A, then X. Do not kill it; a killed minicom leaves the port locked.

### 3. Make GNSS turn on by itself

The modem forgets the setting when it loses power. This timer checks at boot and every 5 minutes.

```bash
sudo cp ~/5g-ntp/systemd/gnss-on.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gnss-on.timer
```

### 4. Give the NMEA port to gpsd

```bash
sudo cp ~/5g-ntp/etc/default/gpsd /etc/default/gpsd
sudo systemctl enable gpsd.socket gpsd.service
sudo systemctl restart gpsd.socket gpsd.service
cgps -s
```

`cgps` should show satellites within a few seconds and `Status: 3D FIX` within 1 to 15 minutes from a cold start. Press q to quit.

### 5. Set up chrony

```bash
sudo cp ~/5g-ntp/etc/chrony/conf.d/direwolf-gps.conf /etc/chrony/conf.d/
sudo systemctl restart chrony
chronyc sources -v
```

Look for the line with `GPS`. The `Reach` column should climb to 377 over about 2 minutes.

### 6. Tune the GPS offset (once, with internet)

NMEA sentences arrive a fraction of a second late. Chrony can measure how late while it can also see internet time servers.

1. Leave the Pi running for 30 minutes in BUILD mode.
2. Run `chronyc sourcestats` and read the `Offset` column on the `GPS` line. Example: `-180ms`.
3. Edit `/etc/chrony/conf.d/direwolf-gps.conf` and set `offset` to that number in seconds with the sign flipped. Example: `offset 0.180`.
4. `sudo systemctl restart chrony`, wait 10 minutes, and check that the GPS offset is now within about 20 ms of zero.

In `chronyc sources`, `*` marks the source in use. With internet, chrony will usually pick an internet server and show GPS as `+`, `-` or `x`. That is normal.
With the range air-gapped, GPS is the only source and gets the `*`.

### 7. Put the dashboard back

```bash
sudo cp ~/5g-ntp/systemd/gps-snapshot.service /etc/systemd/system/
sudo cp ~/5g-ntp/html/index.html /var/www/html/index.html
sudo mkdir -p /var/www/html/temp /var/www/html/vendor/leaflet
sudo chown -R www-data:www-data /var/www/html/temp
cd /var/www/html/vendor/leaflet
sudo wget https://unpkg.com/leaflet@1.9.4/dist/leaflet.js https://unpkg.com/leaflet@1.9.4/dist/leaflet.css
sudo systemctl daemon-reload
sudo systemctl restart gps-snapshot.service
```

Open `http://<Pi address>/`. The page now also lists each satellite and shows the NTP state.
Leaflet comes from https://leafletjs.com (BSD 2-Clause) and is downloaded, not stored in this repo.
The map background needs internet. Air-gapped, the map is grey but everything else works.

### 8. Test from another machine

| From | Command |
|---|---|
| Linux | `chronyd -Q "server <Pi address> iburst"` or `ntpdate -q <Pi address>` |
| Windows | `w32tm /stripchart /computer:<Pi address> /samples:3` |
| On the Pi | `sudo chronyc clients` lists who has asked |

### 9. Point the range at it

| Device | Command |
|---|---|
| Cisco 3750, 2811 | `ntp server <Pi address>` |
| Firepower 1010 (ASA) | `ntp server <Pi address> source outside` |
| Proxmox, Linux | `server <Pi address> iburst` in `/etc/chrony/chrony.conf` |
| Windows domain controller | `w32tm /config /manualpeerlist:<Pi address> /syncfromflags:manual /reliable:yes /update` |

Put the address in the config templates and CSVs, then regenerate. Do not hand-edit the generated configs.

## How accurate is it?

About 10 to 50 ms after step 6. USB carries no pulse-per-second signal, so this is not a microsecond clock.
It is far better than what the range needs: Kerberos allows 5 minutes, and log matching needs about 1 second.

## If something is wrong

| Symptom | Check |
|---|---|
| Dashboard status `no_gpsd` | `systemctl status gpsd`. Is something else holding `/dev/ttyUSB1`? `sudo fuser /dev/ttyUSB1` |
| Status `no_nmea` | GNSS is off. `sudo python3 /opt/gpsdash/gnss_on.py`, then `journalctl -u gnss-on` |
| Status `no_fix` for more than 15 minutes | Antenna on the wrong connector, or no view of the sky |
| `GPS` line in `chronyc sources` has Reach 0 | gpsd is not running with `-n`, or has no fix yet |
| GPS marked `x` in `chronyc sources` | Offset not tuned yet. Do step 6 |
| Port numbers changed (`ttyUSB1` is not NMEA) | `dmesg \| grep ttyUSB`. On this modem the order is 0 diagnostics, 1 NMEA, 2 AT, 3 modem |
| `gnss_on.py` gets garbled answers | ModemManager is also using the AT port. `sudo systemctl disable --now ModemManager` until the SIM arrives |
