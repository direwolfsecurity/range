# Grey cell GeoIP server (geoip.lab)

The range's own MaxMind. It turns the range registry (`network/registry/registry.csv`) into GeoIP databases in
MaxMind's format, and hands them out the way MaxMind does on the real internet. Range web servers can then be
geo-aware: Apache's `mod_maxminddb` tells every page which city, country and network a visitor comes from.

Grey asset #8. Proposed address **172.16.11.50**, name `geoip.lab`. Ubuntu 24.04, a small LXC container is plenty.

License: CC BY-SA 4.0 for this guide, GPL-3.0 for the scripts. Dire Wolf Security.

## What it makes

| File | What is in it | Same as MaxMind's |
|---|---|---|
| `GeoLite2-City.mmdb` | Country, region, city, postal code, latitude/longitude, accuracy, time zone | GeoLite2 City |
| `GeoLite2-Country.mmdb` | Country and continent | GeoLite2 Country |
| `GeoLite2-ASN.mmdb` | AS number and network owner | GeoLite2 ASN |

The files use MaxMind's names and field layout on purpose, so every normal tool opens them with no change:
Apache `mod_maxminddb`, nginx `geoip2`, PHP, Python, Node and Go readers, `mmdblookup`, Wireshark, Suricata, Zeek,
Graylog and Elastic. Range addresses are private (RFC 1918). Our builder includes them; MaxMind's own writers skip
them unless told not to.

The answers are only as true as the registry. A student who looks up `192.168.204.10` gets Kyiv, Ukraine, AS64602
Meridian Global Telecom, because the registry says so. The whois server (asset #7) will give the same answer.

## What it serves

| URL | What |
|---|---|
| `http://geoip.lab/` | "Where this server thinks you are", plus how to use the rest |
| `http://geoip.lab/whoami` | The visitor's own GeoIP as JSON. Any range page may fetch it (CORS is open). |
| `http://geoip.lab/download/` | The three `.mmdb` files (plain and `.gz`), `SHA256SUMS`, `registry.csv`, the web server client script and its config files, and the `mod_maxminddb` source |
| `/geoip/databases/<edition>/update` | The update service the stock `geoipupdate` tool calls (needs HTTPS, see step 6) |

## Files

| File | What |
|---|---|
| `geoip.conf` | All settings: name, registry path, HTTPS, the pinned `mod_maxminddb` version |
| `install.sh` | Builds, tests and publishes the databases and sets up nginx. Test mode by default, acts with `--go`. |
| `tools/build-mmdb.py` | The database writer. Standard library only, written from MaxMind's open format spec, commented for students. |
| `tools/test-mmdb.py` | Looks up every registry network with MaxMind's own Python reader and compares. |
| `client/range-geoip-client.sh` | Runs on a range **web server**: downloads the databases, keeps them updated, sets up Apache, nginx or PHP |
| `client/apache-maxminddb.conf` | The Apache settings: which `MM_*` variables each request gets, and a geofencing example |
| `client/nginx-geoip2.conf`, `client/geoip-demo.php`, `client/GeoIP.conf.example` | nginx settings, a "Where am I?" PHP page, settings for the stock `geoipupdate` |
| `web/index.html` | This server's home page |

## Build it

### 1. Container

On pve5: Ubuntu 24.04 template, unprivileged, 1 core, 512 MB RAM, 4 GB disk. Network: GREY bridge, VLAN 110,
static `172.16.11.50/24`, gateway `172.16.11.254`. DNS `172.16.11.10`. Start at boot. Log in as root:

```
apt update && apt install -y git sudo
```

### 2. Get the two folders

This asset needs its own folder **and** the registry folder (the registry is the one file several assets share):

```
git clone --depth 1 --filter=blob:none --sparse https://github.com/direwolfsecurity/range.git
cd range
git sparse-checkout set assets/grey/geoip network/registry
cd assets/grey/geoip
```

### 3. Install

```
sudo bash install.sh          # test mode: shows the plan, changes nothing
sudo bash install.sh --go
```

Run `--go` the first time while the container still has internet. It downloads the `mod_maxminddb` source once
(checked against its SHA-256) and keeps it in `/download/`, so web servers on the air-gapped range can build it later.
At the end every line of the check should say `ok`. "geoip.lab does not resolve yet" is expected until step 4.

### 4. Register the name

```
sudo bash install.sh --registrar
```

It prints two commands. Run them on the root primary (`ssh root-a`):

```
sudo -u www-data php /opt/registrar/cli.php add-a geoip.lab 172.16.11.50
sudo registrar-apply
```

### 5. Check it

```
sudo bash install.sh --check
```

From the Kali desktop: open `http://geoip.lab/`. It shows Exercise Control, Washington DC, because WHITECELL
(172.16.12.0/24) belongs to Exercise Control in the registry.

### 6. HTTPS (optional, for the stock `geoipupdate` tool)

`geoipupdate` only talks HTTPS. Once the CA is built: set `HTTPS="yes"` and `CA_FINGERPRINT` in `geoip.conf`, then
`sudo bash install.sh --go` again. Machines that trust the range root can then use `client/GeoIP.conf.example`
as their `/etc/GeoIP.conf` and run `sudo geoipupdate -v`, exactly as on the real internet.

## Change the registry, then rebuild

1. Edit `network/registry/registry.csv` (on your PC, in the repo) and check it: `python registry.py`.
2. Commit and push.
3. On geoip.lab: `cd ~/range && git pull && cd assets/grey/geoip && sudo bash install.sh --go`

Web servers pick up the new databases by themselves within a day (their cron job), or at once with
`sudo range-geoip-update`.

## Make a range web server geo-aware

On the web server (Ubuntu 24.04):

```
curl -O http://geoip.lab/download/range-geoip-client.sh
sudo bash range-geoip-client.sh --apache --php          # test mode
sudo bash range-geoip-client.sh --apache --php --go
```

| Option | What it does |
|---|---|
| (always) | Downloads the three databases to `/var/lib/GeoIP`, checks their SHA-256, installs `range-geoip-update` and a daily cron job |
| `--apache` | Builds MaxMind's `mod_maxminddb` from the source on geoip.lab, turns it on, installs `apache-maxminddb.conf` |
| `--nginx` | Installs Ubuntu's `libnginx-mod-http-geoip2` and `nginx-geoip2.conf` |
| `--php` | Installs `php-maxminddb` and puts `geoip-demo.php` in `/var/www/html` |

With `--apache`, every request gets these variables. PHP reads them from `$_SERVER`, the access log with `%{MM_CITY}e`:

| Variable | Example (a visitor from seat 103) |
|---|---|
| `MM_COUNTRY_CODE`, `MM_COUNTRY_NAME`, `MM_CONTINENT` | `US`, `United States`, `NA` |
| `MM_REGION_CODE`, `MM_REGION_NAME`, `MM_CITY`, `MM_POSTAL` | `TX`, `Texas`, `Austin`, `78701` |
| `MM_LATITUDE`, `MM_LONGITUDE`, `MM_ACCURACY_KM`, `MM_TIME_ZONE` | `30.2672`, `-97.7431`, `10`, `America/Chicago` |
| `MM_ASN`, `MM_AS_ORG`, `MM_NETWORK` | `64601`, `Bluestem Broadband`, `192.168.103.0/24` |

A geofencing example (only visitors from the US and Canada) is at the bottom of `apache-maxminddb.conf`.

Ubuntu has no package for `mod_maxminddb`, which is why the client builds it. (Ubuntu's `libapache2-mod-geoip`
is MaxMind's older module for the retired `.dat` format. It can't read `.mmdb` files.)

## Where this was tested

On an Ubuntu 24.04 test machine, 2026-11-28: the builder's files were read correctly by `mmdblookup`,
MaxMind's Python reader (all three modes) and `geoip2` library, PHP's `MaxMind\Db\Reader`, nginx's geoip2 module
(with a real request from a seat-204 address answering Kyiv) and the stock `geoipupdate` 6.1 (download, then
"up to date"). `install.sh --go` ran twice: the second run changed nothing.

**Not tested yet:** building `mod_maxminddb` and the Apache `MM_*` variables (the test machine was not allowed to
compile it), the geofencing example, HTTPS with the range CA, and anything on the real range. Try Apache first on
a test web server and report what `apachectl -M | grep maxmind` says.

## Things to know

- **Students can change the answer** for their own machine: anything that reads a local `.mmdb` trusts that file.
  That is a lesson, not a bug (GeoIP is a guess, and it is easy to fool).
- **Inside a pod** every machine has the same 10.10.10.x address, so GeoIP sees the pod's outside address
  (192.168.1xx/2xx) only on servers outside the pod. That is how it works on the real internet too (NAT).
- **Proxies hide the visitor.** Behind a reverse proxy, look up the `X-Forwarded-For` address instead
  (`MMDB_ADDR` in Apache, `geoip2 ... source=` in nginx).
- MaxMind's GeoLite2 data is not used or shipped. Every record comes from our registry.
