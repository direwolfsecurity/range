# Web map services on the range: plan

Status: **plan, nothing in this file is built yet** (2026-11-28). The map server itself is built (see `../README.md`).

On the real internet, a web designer adds a map to a page with a few lines: a JavaScript library from a CDN,
tiles from a tile server, maybe a search box (geocoding) and the visitor's location (GeoIP or the browser).
This plan gives range web sites the same parts, all served by range machines, so the interactive media and
web design class can follow normal tutorials. It also sets up the parts that geofencing, asset tracking and
GPS streams need later.

| Real internet | Range | Where | State |
|---|---|---|---|
| tile.openstreetmap.org, MapTiler | `maps.lab`: raster and vector tiles, styles, fonts | map server (.60) | built |
| Google Static Maps | `maps.lab/styles/<style>/static/...` | map server | built (TileServer GL) |
| unpkg / cdnjs (Leaflet, MapLibre) | `maps.lab/lib/` | map server | phase A |
| HTTPS on all of the above | certificate from `ca.lab` | map server | phase A |
| MaxMind GeoIP | `geoip.lab`: .mmdb downloads, `/whoami`, Apache/nginx modules | GeoIP server | **built in this change** (`../../geoip/`) |
| Browser geolocation ("Allow location?") | `geoip.lab/geolocate` for Firefox | GeoIP server | phase B |
| Nominatim search ("find an address") | Photon geocoder at `maps.lab/geocode/` | map server | phase C |
| Routing (directions) | GraphHopper or OSRM | separate | later, if wanted |
| Fleet / asset tracking | Traccar at `track.lab`, fed by MQTT and GPS | new container | phase D |

## What the map server already offers

TileServer GL serves these today (paths are on `http://maps.lab/` once the name is registered):

| Path | What | Used by |
|---|---|---|
| `/{z}/{x}/{y}.png` | PNG tiles, default style, same layout as tile.openstreetmap.org | Leaflet, OpenLayers |
| `/styles/<style>/{z}/{x}/{y}.png` (and `@2x`) | PNG tiles for each style: `osm-bright`, `positron`, `dark-matter`, `basic` | Leaflet |
| `/styles/<style>/style.json` | Vector style | MapLibre GL JS |
| `/data/openmaptiles.json`, `/data/openmaptiles/{z}/{x}/{y}.pbf` | TileJSON and vector tiles | MapLibre, QGIS |
| `/styles/<style>/static/<lon>,<lat>,<zoom>/<w>x<h>.png` | One map picture, no JavaScript | `<img>` tags, emails, reports |
| `/styles/<style>/wmts.xml` | WMTS | QGIS, ArcGIS |
| `/fonts/...`, sprites | Label fonts and icons | MapLibre |

Still to check on the built server: that TileServer GL's CORS header (`Access-Control-Allow-Origin`) reaches
browsers through nginx, so pages on other range sites can load vector tiles and styles.

## Phase A: make it embeddable like a real map service (small)

1. **Register `maps.lab`** on the root primary: `add-a maps.lab 172.16.11.60`, then `registrar-apply`.
2. **HTTPS from the range CA.** A page served over HTTPS may not load `http://` tiles (browsers block mixed
   content), and the browser geolocation API only works on HTTPS pages. Add a certbot step, the same way
   `connectivity-check` and `geoip` do it, and listen on 443.
3. **CORS headers** in nginx for tiles, styles, fonts and `/lib/`: `Access-Control-Allow-Origin: *`.
4. **Host the JavaScript libraries** under `/lib/`, with the same paths unpkg uses, so tutorial code needs only a
   host change:
   - `https://maps.lab/lib/leaflet@1.9.4/dist/leaflet.js` and `leaflet.css` (BSD 2-Clause)
   - `https://maps.lab/lib/maplibre-gl@<version>/dist/maplibre-gl.js` and `.css` (BSD 3-Clause)
   - optional: OpenLayers (BSD 2-Clause), Leaflet.draw for drawing geofences
   Fetched at install time from the npm registry at pinned versions, checked against SHA-256, like the rest of
   `maps.conf`. Nothing is copied into this repo.
5. **Example pages** at `/examples/`: a Leaflet map, a MapLibre map, a static-map `<img>`, and "you are here"
   (calls `geoip.lab/whoami` and drops a marker on the visitor's GeoIP location, with an accuracy circle).
   These are the class starter files.

Leaflet in a range page then looks like this:

```html
<link rel="stylesheet" href="https://maps.lab/lib/leaflet@1.9.4/dist/leaflet.css">
<script src="https://maps.lab/lib/leaflet@1.9.4/dist/leaflet.js"></script>
<div id="map" style="height: 400px"></div>
<script>
  const map = L.map("map").setView([39.83, -98.58], 4);
  L.tileLayer("https://maps.lab/{z}/{x}/{y}.png", {
    maxZoom: 20,
    attribution: "&copy; OpenMapTiles &copy; OpenStreetMap contributors"
  }).addTo(map);
  fetch("https://geoip.lab/whoami").then(r => r.json()).then(me => {
    if (me.latitude) L.marker([me.latitude, me.longitude]).addTo(map).bindPopup("You: " + me.city).openPopup();
  });
</script>
```

**Option for Tim (later):** also answer `tile.openstreetmap.org` and `unpkg.com` on the range (add them to
`connectivity-check/names.conf`, point them at the map server, and give it certificates for those names from
`ca.lab`). Copied tutorial code would then work with no change at all. It also makes a good lesson on how a
network that controls DNS and the trusted CA can stand in for any site.

## Phase B: location in the browser (GeoIP server)

`navigator.geolocation` on a desktop asks a web service (Google or Mozilla) where the machine is, which fails
with no internet. Firefox lets you change that service (`geo.provider.network.url` in a policy or `about:config`).
Add `POST /geolocate` to `geoip.lab`, answering in the Mozilla Location Service format
(`{"location": {"lat": ..., "lng": ...}, "accuracy": ...}`) from the GeoIP of the caller. Range Firefox then shows
"Allow location?" and gets the same place the GeoIP database gives. A Firefox policy file in the pod templates sets
it once. Chrome and Edge can't be pointed at another service, so their pages fall back to GeoIP.

## Phase C: geocoding (search for a place, or the address at a point)

| Option | What it needs | Notes |
|---|---|---|
| **Photon** (recommended) | Java (already on the map server), a ready-made search index downloaded once | Search-as-you-type and reverse lookup. Simple JSON API. Index for one country or the planet. Apache 2.0. |
| Nominatim | PostgreSQL + PostGIS and its own import of the planet file | The real OpenStreetMap search. A planet import takes days, a lot of RAM and about 1 TB of disk. One state or country is practical. |
| Range-only places | A small list of range names (Cyber City, the fake companies) | Can sit beside either one, so a search for "Bluestem Broadband" finds its office. |

Sizes for Photon's index and the planet change every year. Check the current download sizes before choosing
the coverage (open decision 4 in `../../README.md`). Served behind nginx at `maps.lab/geocode/`.

## Phase D: live location, asset tracking and geofencing

- **Sources:** the GPS on the 5G time Pi (gpsd is already running there), GPS modules on Cyber City tiles (ESP32),
  phones running a tracker app on the range Wi-Fi, and simulated vehicles (a script that drives a route).
- **Transport:** MQTT on `mqtt.lab`, one topic per tracker, for example `city/track/<id>` with
  `{"lat": ..., "lon": ..., "time": ..., "speed": ...}`. Plain MQTT on purpose for attack labs (spoof a GPS position),
  logins and TLS in defend labs, like the broker's two modes.
- **Traccar** at `track.lab` (new container; Java, Apache 2.0): takes positions over MQTT or 200+ tracker
  protocols, stores them, draws geofences, fires "entered/left zone" events, and has a REST and WebSocket API.
  Its web map uses our tiles (`https://maps.lab/{z}/{x}/{y}.png`).
- **Web pages** draw live tracks with Leaflet and a WebSocket or MQTT-over-WebSocket feed.
- **OpenEMS:** not looked at yet. Next step is to find which OpenEMS bridge can read an MQTT topic, so GPS
  positions (or geofence events) can enter OpenEMS as channels.
- **Server-side geofencing** with GeoIP: Apache `SetEnvIf MM_COUNTRY_CODE` and `Require env` (example in
  `../../geoip/client/apache-maxminddb.conf`), nginx `map` on `$geoip2_country_code`.

## Order

1. Phase A on the map server, tested with the Monaco build first.
2. Phase B on the GeoIP server.
3. Phase C once the planet build is done and the coverage is decided.
4. Phase D with the MQTT broker and the first GPS tile.
