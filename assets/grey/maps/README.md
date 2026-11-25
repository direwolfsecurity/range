# Grey cell map tile server

The range's own world map. It works with the internet unplugged.

It builds vector map tiles for the whole planet from OpenStreetMap, then serves them with TileServer GL.
It lives on GREY (VLAN 110) at **172.16.11.60**, host name `maps`. Grey asset #9 in `GREY-CELL-ASSETS.md`.

| Piece | What it is |
|---|---|
| Planetiler 0.10.2 | Turns the OpenStreetMap planet file into OpenMapTiles vector tiles (one `.mbtiles` file). |
| TileServer GL 5.6.0 | Serves the vector tiles, and draws PNG tiles from them on request. |
| nginx | Port 80 in front. Caches drawn tiles (40 GB). Adds the short `/{z}/{x}/{y}.png` path. |
| Styles | OSM Bright (default), Positron, Dark Matter, Basic. Sprites and fonts stored locally. |

Both programs run as pinned Docker images, so every build is the same.

## Credit and licensing

- Map data © OpenStreetMap contributors, under the [ODbL](https://www.openstreetmap.org/copyright).
  Every map page must show this credit. The tiles are **not** republished here. `install.sh` fetches the data from source.
- Tile schema and styles © [OpenMapTiles](https://openmaptiles.org/) (CC BY 4.0 design, BSD 3-Clause code). Credit "© OpenMapTiles".
- Fonts: Noto Sans, Metropolis, Open Sans (SIL Open Font License). Fetched from `openmaptiles/fonts`.
- Planetiler: Apache 2.0. TileServer GL: BSD 2-Clause.
- This folder (scripts and guide): CC BY-SA 4.0, Dire Wolf Security.

The attribution text the server sends with every style is set in `maps.conf` (`ATTRIBUTION`).

## Files

| File | What |
|---|---|
| `maps.conf` | All settings: address, disks, versions, area, zoom, styles. Change things here. |
| `install.sh` | Runs inside the VM. Test mode by default, acts with `--go`. |
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

### 3. Copy this folder to the VM

From a PC on the same network, with the VM's DHCP address:

```
scp -r maps <user>@<vm-ip>:~/
```

Then on the VM: `cd ~/maps`

### 4. Format the data disks

```
lsblk                                     # check: sdb = 300G, sdc = 1.2T
sudo bash install.sh --format-disks       # test mode
sudo bash install.sh --format-disks --go
```

It only formats a disk that is completely blank. It labels them `DWMAPS` and `DWBUILD` and adds them to `/etc/fstab`.
The build disk line has `nofail`, so the VM still boots after that disk is gone.

### 5. Test build: a small area (recommended, a few minutes)

This proves every step works before you spend hours on the planet.

1. In `maps.conf`, set `AREA="monaco"`. The test point (`TEST_LAT`, `TEST_LON`) is already in Monaco.
   To test a bigger area, use any Geofabrik region name and move the test point inside it.
2. Run:

   ```
   sudo bash install.sh            # test mode: pre-flight and plan
   sudo bash install.sh --go       # packages, images, assets, then starts Planetiler
   sudo docker logs -f --tail 20 planetiler     # watch; Ctrl-C stops watching only
   sudo bash install.sh --go       # when Planetiler is done: config, service, check
   ```

3. Open `http://<vm-ip>/` in a browser. Zoom to Monaco. You should see streets and labels.
   Outside the test area the map is blank. That is expected for the test.

### 6. Build the planet

1. In `maps.conf`, set `AREA="planet"`.
2. Run:

   ```
   sudo bash install.sh                        # pre-flight must show no FAIL lines
   sudo bash install.sh --rebuild-tiles --go   # starts the planet build in the background
   ```

3. Planetiler runs in a Docker container. Closing SSH does not stop it. Check on it any time:

   ```
   sudo docker logs --tail 20 planetiler
   sudo bash install.sh --check
   ```

4. When it is finished, run `sudo bash install.sh --go` once more. It moves `planet.mbtiles` to `/srv/maps/data`,
   keeps the test file as `planet.mbtiles.previous` (delete it to save space), and restarts the server.

If Planetiler fails, `install.sh --go` shows its last 30 lines. Fix the cause, then
`sudo docker rm planetiler` and run `sudo bash install.sh --rebuild-tiles --go` again.
Downloaded files stay on `/build`, so a restart does not download the planet again.

### 7. Check it

```
sudo bash install.sh --check
```

Every line should say `ok`. It checks:

- the services (Docker, `direwolf-tileserver`, nginx);
- that every style uses only local tiles, sprites and fonts, with no `http://` or `https://` left in it;
- that every font a style asks for is on disk;
- live requests through nginx: `/health`, world tiles at zoom 0 and 5, a zoom-14 tile over the test point in `maps.conf`
  (PNG, PNG @2x, and vector), and a font file.

Missing fonts or sprites are the usual reason an offline map shows shapes but no labels or icons.
`--check` catches both.

### 8. Drop the build disk and shrink the VM

```
sudo bash install.sh --drop-build-disk --go     # in the VM: unmounts /build, removes it from fstab
sudo shutdown -h now
```

On pve18:

```
bash create-vm.sh --slim --go     # 4 cores, 8 GB RAM, deletes the 1.2 TB disk and the CD drive
```

### 9. Set the GREY address (still at home)

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

### 10. Carry it to school and put it on GREY

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

### 11. Test from GREY

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

The first user. At the top of the script in `assets\5g\ntp\html\index.html`, set:

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
3. In the VM: `sudo bash install.sh --format-disks --go`, then `sudo bash install.sh --rebuild-tiles --go`.
4. Repeat steps 6 to 9.

To move to newer Planetiler or TileServer GL versions, change the image tags in `maps.conf` and run
`sudo bash install.sh --step images --go`, then `--step service --go`. Do the small test build first.

## Troubleshooting

| What you see | Why, and the fix |
|---|---|
| `/health` gives 503 | The server is still starting. Opening the 90 GB tile file takes a moment. Wait 30 seconds. |
| Shapes but no labels | A font is missing. `sudo bash install.sh --check` names it. Re-run `--step assets --go` and `--step config --go` while on the internet. |
| No icons | Sprite files missing. Same fix as above. |
| Map is blank outside the test area | The test build is still in place. Do step 6. |
| Grey squares, server log shows timeouts | Too many first-time tiles at once. Raise cores, or wait: the cache fills up. |
| Docker addresses | Docker uses 172.17.0.0/16 inside the VM. No range network uses it. Do not add range networks in 172.17-172.31 without changing Docker's `bip`. |
| Time is wrong after the move | The NTP Pi (172.16.11.123) is not on GREY yet. `timedatectl` shows the state. |

Logs: `journalctl -u direwolf-tileserver`, `/var/log/nginx/`, and the Planetiler log saved next to the tiles in
`/srv/maps/data/planetiler-YYYYMMDD.log`.

## Status

Written 2026-11-24. Scripts pass `bash -n` and `shellcheck`, and test mode was run. `make-styles.py` was tested
against the real pinned styles and the real font list. **Not yet run on the VM.** The small test build (step 5) is the
first real run.
