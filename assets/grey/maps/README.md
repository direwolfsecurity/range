# Grey cell map tile server

The range's own world map. It works with the internet unplugged.

It builds vector map tiles for the whole planet from OpenStreetMap, then serves them with TileServer GL.
It lives on GREY (VLAN 110) at **172.16.11.60**, host name `maps`. Grey asset #9 in `GREY-CELL-ASSETS.md`.

| Piece | What it is |
|---|---|
| Planetiler 0.10.2 | Turns the OpenStreetMap planet file into OpenMapTiles vector tiles (one `.mbtiles` file). A Java program. |
| TileServer GL 5.6.0 | Serves the vector tiles, and draws PNG tiles from them on request. Installed from npm, runs on Node.js 22. |
| nginx | Port 80 in front. Caches drawn tiles (40 GB). Adds the short `/{z}/{x}/{y}.png` path. |
| Styles | OSM Bright (default), Positron, Dark Matter, Basic. Sprites and fonts stored locally. |

**No Docker.** Planetiler runs as a plain Java program and TileServer GL is installed from npm. Each runs as a
systemd service (`direwolf-planetiler` for the build, `direwolf-tileserver` for the server), as a locked-down
`dwmaps` user. Every version is pinned in `maps.conf`, and downloads are checked against their SHA-256, so every
build is the same.

**It needs Ubuntu Server 24.04.** TileServer GL's map-drawing library is built for Ubuntu 24.04's system libraries,
so Debian and other Ubuntu releases do not work. `install.sh` checks this first.

## Credit and licensing

- Map data © OpenStreetMap contributors, under the [ODbL](https://www.openstreetmap.org/copyright).
  Every map page must show this credit. The tiles are **not** republished here. `install.sh` fetches the data from source.
- Tile schema and styles © [OpenMapTiles](https://openmaptiles.org/) (CC BY 4.0 design, BSD 3-Clause code). Credit "© OpenMapTiles".
- Fonts: Noto Sans, Metropolis, Open Sans (SIL Open Font License). Fetched from `openmaptiles/fonts`.
- Planetiler: Apache 2.0. TileServer GL: BSD 2-Clause.
- This folder: scripts under GPL-3.0, this guide under CC BY-SA 4.0. Dire Wolf Security.

The attribution text the server sends with every style is set in `maps.conf` (`ATTRIBUTION`).

## Files

| File | What |
|---|---|
| `maps.conf` | All settings: address, disks, versions, area, zoom, styles. Change things here. |
| `install.sh` | Runs inside the VM. Test mode by default, acts with `--go`. Safe to run again at any time. |
| `tools/make-styles.py` | Points the styles at the local tiles, sprites and fonts, then checks nothing points at the internet. |
| `proxmox/create-vm.sh` | Runs on the Proxmox host. Creates the VM, later moves it to GREY and shrinks it. |

## Sizes and time

Numbers from Planetiler's planet guide, 2026 planet file. Your times will differ.

| Thing | Size |
|---|---|
| Planet download (`planet.osm.pbf`) | about 92 GB |
| Scratch space during the build | about 10 times the download: **~1 TB**. Use the 1.2 TB build disk. |
| Finished tiles (`planet.mbtiles`, zoom 0-14) | about 80-100 GB |
| Build time, 24 cores, 50 GB RAM | roughly 3-6 hours after the download |
| Download time | depends on the school link. 92 GB at 200 Mb/s is about 1 hour. |

### How much RAM

`install.sh` picks the Java settings from the VM's RAM (`JAVA_HEAP="auto"`).

| VM RAM | What it does |
|---|---|
| 150 GB or more | Keeps node positions in RAM. Fastest. |
| 46-149 GB | Memory-maps node positions to the build disk, 20 GB Java heap. **The plan: 48 GB on pve18.** |
| 30-45 GB | Same, 12 GB heap. Slow. Needs `--force`. |
| under 30 GB | Stops. Give the VM more RAM for the build. |

After the build the server needs only 8 GB and 4 cores.

### How much detail

Zoom 14 (the default) is the most detailed level of the OpenMapTiles schema. Every road, building, path and
house number in OpenStreetMap is in the zoom-14 tiles. The server draws zoom 15 to 20 from them, so you can zoom in to
street level anywhere in the world.

`MAXZOOM="16"` keeps more shape detail on zoom 15-16 (building corners, coastlines). It needs roughly
1.5 TB of scratch space and 350 GB for the tiles. We have not tried it. Start with 14.

## Build it

The build happens on **pve18 at home**, then the finished VM is carried to school on a USB drive.

Why pve18: 16-core Ryzen 9 9955HX, 92 GiB RAM and a 4 TB Samsung 990 PRO NVMe, plus home internet for the 92 GB download.
The school's pve5 has the cores but only 62.78 GiB RAM and no 1.2 TB of free fast disk.

### 1. Create the VM (on pve18)

Before you start, check free space on pve18's shell:

```
pvesm status       # "local-lvm" must have about 1.6 TB available
lvs                # Data% of the "data" thin pool: keep the real free space above 1.6 TB
```

`local-lvm` is a thin pool. Its disks only take space as they fill, so `pvesm` can look fine while the
pool is nearly full. **If a thin pool fills up, every VM on it stops working.** Make sure the real free space
(pool size × (100 − Data%)) is at least 1.6 TB, counting what the other VMs will grow into.

Free some RAM too: pve18 already uses about 37 GiB. The build VM takes 48 GB with no ballooning.

Edit the top of `proxmox/create-vm.sh`: `VMID` (one not used at home or on pve5), `ISO`, the three storage names
and `BUILD_BRIDGE` (the home LAN bridge).

Upload the Ubuntu Server 24.04 LTS ISO to the host's ISO storage first. (TileServer GL lists Ubuntu 24.04 as supported.)

```
bash create-vm.sh          # test mode: shows free space and the qm command
bash create-vm.sh --go
```

The VM gets 24 cores, 48 GB RAM (no ballooning) and three disks:

| Disk | Size | In the VM | Kept? |
|---|---|---|---|
| scsi0 | 64 GB | Ubuntu | yes |
| scsi1 | 300 GB | `/dev/sdb` -> `/srv/maps` (tiles, styles, fonts, cache) | yes, in backups |
| scsi2 | 1200 GB | `/dev/sdc` -> `/build` (scratch) | no. Deleted after the build. Not in backups. |

The 1.2 TB build disk is only needed for one day.

### 2. Install Ubuntu

1. Start the VM and open its console.
2. Install Ubuntu Server 24.04. Install it on the **64 GB disk only**. Leave the 300 GB and 1.2 TB disks alone.
3. Use DHCP on the home LAN for now.
4. Tick "Install OpenSSH server". Skip all the snaps.
5. Reboot, log in, then: `sudo apt update && sudo apt -y full-upgrade && sudo apt -y install qemu-guest-agent`

### 3. Get this folder onto the VM

On the VM (it needs the internet for this):

```
git clone --depth 1 --filter=blob:none --sparse https://github.com/direwolfsecurity/range.git
cd range
git sparse-checkout set assets/grey/maps
cd assets/grey/maps
```

This downloads only the maps folder (plus the license and README files above it), not the whole range repo.
Keep the folder on the VM: `install.sh` uses it again for re-runs and the status check. To get updates later: `cd ~/range && git pull`.

Already cloned the whole repo? Trim it in place: `cd ~/range && git sparse-checkout set assets/grey/maps`.

No internet on the VM yet? Copy the folder from a PC instead: `scp -r maps <user>@<vm-ip>:~/` and then `cd ~/maps`.

### 4. Test build: a small area (recommended, about 10 minutes)

This proves every step works before you spend hours on the planet. It is one command:

```
sudo bash install.sh --area monaco --go
```

It works through these steps and prints what it is doing as it goes:

| Step | What happens |
|---|---|
| disks | Formats the 300 GB and 1.2 TB disks, but **only if they are completely blank**, labels them `DWMAPS` and `DWBUILD`, and mounts them at `/srv/maps` and `/build`. A disk that is missing or not blank is left alone. |
| packages | Installs Java 21, nginx, Xvfb and the drawing libraries from Ubuntu. |
| programs | Downloads Node.js, TileServer GL (npm) and Planetiler at the pinned versions, and checks them. |
| assets | Fetches the map styles, icons and fonts. |
| tiles | Starts Planetiler as a service and shows its progress. Monaco takes a minute or two. |
| config | Makes the styles work offline and writes the TileServer GL settings. |
| service | Starts TileServer GL and nginx, then runs the checks in step 6. |

When it finishes, every line under "Live tests" should say `ok`.
Open `http://<vm-ip>/` in a browser and zoom to Monaco. You should see streets and labels.
Outside the test area the map is blank. That is expected for the test.

Want to see the plan first? Run it without `--go`: `sudo bash install.sh --area monaco`. Nothing changes in that mode.

To test a bigger area, use any Geofabrik region name (for example `--area rhode-island`) and set the test point
(`TEST_LAT`, `TEST_LON` in `maps.conf`) inside it.

### 5. Build the planet

```
sudo bash install.sh --go
```

That is all. `AREA="planet"` is already set in `maps.conf`. The script sees that the tiles in place are only Monaco and
builds the planet. The pre-flight must show no `FAIL` lines first (RAM, disk space); it stops if it finds one.

- Planetiler runs as a service, so **you can close the SSH window**. The build keeps going.
- To watch it again, or to finish once it is done, run the **same command again**: `sudo bash install.sh --go`.
  It picks up wherever things are. It never starts a second build while one is running.
- A quick status check any time: `sudo bash install.sh --check`. The full log: `sudo tail -f /build/planetiler/planetiler.log`.

When Planetiler finishes, the script moves `planet.mbtiles` to `/srv/maps/data`, keeps the Monaco file as
`planet.mbtiles.previous` (delete it to save space), clears the tile cache and restarts the server.

If Planetiler fails, the script shows the last 30 lines of its log and why. Fix the cause (usually disk space or RAM),
then run `sudo bash install.sh --go` again. Downloaded files stay on `/build`, so a restart does not download the planet again.

### 6. Check it

```
sudo bash install.sh --check
```

Every line should say `ok`. It checks:

- the services (`direwolf-tileserver` and nginx), and whether a Planetiler build is still running;
- that every style uses only local tiles, sprites and fonts, with no `http://` or `https://` left in it;
- that every font a style asks for is on disk;
- live requests through nginx: `/health`, world tiles at zoom 0 and 5, a zoom-14 tile over the test point in `maps.conf`
  (PNG, PNG @2x, and vector), and a font file.

Missing fonts or sprites are the usual reason an offline map shows shapes but no labels or icons.
`--check` catches both.

### 7. Drop the build disk and shrink the VM

```
sudo bash install.sh --drop-build-disk --go     # in the VM: unmounts /build, removes it from fstab
sudo shutdown -h now
```

On pve18:

```
bash create-vm.sh --slim --go     # 4 cores, 8 GB RAM, deletes the 1.2 TB disk and the CD drive
```

### 8. Set the GREY address (still at home)

Start the VM again on pve18, then:

```
sudo bash install.sh --grey       # test mode
sudo bash install.sh --grey --go
sudo shutdown -h now
```

This writes the static address 172.16.11.60/24, gateway 172.16.11.254, DNS 172.16.11.10, NTP 172.16.11.123,
and sets the host name to `maps`. It does not apply the change while you are connected, so you are not cut off.
The old DHCP settings are kept in `/var/backups/direwolf-maps/netplan/`.

From here the VM has no working network at home. That is expected.

### 9. Carry it to school and put it on GREY

The VM now holds about 10 GB of Ubuntu plus about 100 GB of map. Back it up to a USB drive (exFAT or ext4, 256 GB or more).

On pve18, with the USB drive mounted at `/mnt/usb`:

```
vzdump <VMID> --mode stop --compress zstd --dumpdir /mnt/usb
```

The backup is a single `vzdump-qemu-<VMID>-....vma.zst` file of roughly 100 GB.

At school, plug the drive into pve5, mount it at `/mnt/usb`, then:

```
pvesm status                                         # pick a storage with 400 GB free
qmrestore /mnt/usb/vzdump-qemu-<VMID>-*.vma.zst <VMID> --storage <storage>
bash create-vm.sh --to-grey --go                     # NIC to GREY, VLAN 110; start at boot
qm start <VMID>
```

Set `GREY_BRIDGE` at the top of `create-vm.sh` to pve5's bridge first. The VM was built on AMD and now runs on Intel;
that is fine because it uses CPU type `host` and starts from a normal boot.

The 400 GB on pve5 is the open question: pve5's root disk is only 94 GiB. Check `pvesm status` there before the trip.

### 10. Test from GREY

From any machine that can reach GREY:

```
curl -I http://172.16.11.60/health
curl -o test-tile.png http://172.16.11.60/14/8529/5974.png     # Monaco; any tile works
```

Then browse to `http://172.16.11.60/`. Pull the red cable (CLOSED mode) and try again. It must still work.

## Using the map

| What | URL |
|---|---|
| Viewer and list of styles | `http://172.16.11.60/` |
| PNG tiles, default style (Leaflet, OSM-style path) | `http://172.16.11.60/{z}/{x}/{y}.png` |
| PNG tiles, any style | `http://172.16.11.60/styles/<style>/{z}/{x}/{y}.png` (add `@2x` for high-DPI) |
| 512-pixel PNG tiles | `http://172.16.11.60/styles/<style>/512/{z}/{x}/{y}.png` |
| Style for MapLibre GL JS (vector) | `http://172.16.11.60/styles/<style>/style.json` |
| Vector tiles | `http://172.16.11.60/data/openmaptiles/{z}/{x}/{y}.pbf` |
| TileJSON | `http://172.16.11.60/styles/<style>.json` |
| WMTS (QGIS, ArcGIS) | `http://172.16.11.60/styles/<style>/wmts.xml` |
| Static image | `http://172.16.11.60/styles/osm-bright/static/7.4246,43.7384,12/800x600.png` |

Styles: `osm-bright`, `positron`, `dark-matter`, `basic`.

### The GPS dashboard on the NTP Pi

The first user. At the top of the script in `assets/grey/time/5g/ntp/html/index.html`, set:

```js
const TILE_URL = 'http://172.16.11.60/{z}/{x}/{y}.png';
const TILE_ATTRIBUTION = '&copy; <a href="https://openmaptiles.org/">OpenMapTiles</a> &copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap contributors</a>';
```

The links in the credit do not need to work offline. The words must be on the map.

Zoom 0 to 5 shows the whole world for the satellite ground tracks. Zoom 14 and up shows street detail anywhere in the built area.
The first time a tile is drawn it takes up to a second. After that nginx serves it from the cache.

### Later: make it look like the real thing

When the grey DNS and CA are built, point `tile.openstreetmap.org` at 172.16.11.60. The short path is already the same
layout as the real OpenStreetMap tile server, so ordinary Leaflet pages and apps will work with no change.
They use HTTPS, so this needs a certificate from the range CA (grey asset #5) and an HTTPS server block in nginx.

## Updating the map

OpenStreetMap changes every day. Once a year (summer) is plenty.

1. Add a new 1.2 TB build disk (scsi2) in Proxmox, raise the VM to 16 cores and 64 GB RAM.
2. Move it back to the classroom LAN, or give it a second NIC there.
3. In the VM: `sudo bash install.sh --rebuild-tiles --go`. It formats the new blank disk, then builds.
4. Repeat steps 6 to 8.

To move to newer Planetiler, TileServer GL or Node.js versions, change the version and SHA-256 lines in `maps.conf`
and run `sudo bash install.sh --go`. The programs step notices the new version and installs it; then run
`sudo bash install.sh --step service --go` to restart the server on it. Do the small test build first.

## Troubleshooting

| What you see | Why, and the fix |
|---|---|
| `/health` gives 503 | The server is still starting. Opening the 90 GB tile file takes a moment. Wait 30 seconds. |
| Shapes but no labels | A font is missing. `sudo bash install.sh --check` names it. Re-run `--step assets --go` and `--step config --go` while on the internet. |
| No icons | Sprite files missing. Same fix as above. |
| Map is blank outside the test area | The test build is still in place. Do step 5. |
| Grey squares, server log shows timeouts | Too many first-time tiles at once. Raise cores, or wait: the cache fills up. |
| "This needs Ubuntu Server 24.04" | The VM runs Debian or another Ubuntu. Reinstall it with Ubuntu Server 24.04 (step 2). |
| Docker is on the VM from an older version of this guide | Not used and harmless. Starting from a fresh VM is cleanest. |
| TileServer GL log warns about "Host header poisoning" | Safe to ignore on the range. nginx is the only thing that talks to it. |
| Time is wrong after the move | The NTP Pi (172.16.11.123) is not on GREY yet. `timedatectl` shows the state. |

Logs: `journalctl -u direwolf-tileserver`, `/var/log/nginx/`, the running build's log in `/build/planetiler/planetiler.log`,
and a copy of each finished build's log next to the tiles in `/srv/maps/data/planetiler-YYYYMMDD-HHMM.log`.

## Status

Rewritten 2026-11-25 to drop Docker. Scripts pass `bash -n` and `shellcheck`. The full one-command Monaco run
(`--area monaco --go`) was tested on a clean Ubuntu 24.04 machine: packages, Node.js, TileServer GL from npm, Planetiler,
styles and fonts, nginx, and every `--check` line `ok`, with labels and icons drawn. Running it a second time changed
nothing. The planet build has not been run yet.
