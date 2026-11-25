#!/usr/bin/env bash
# Dire Wolf Security - grey cell map tile server installer
#
# Builds an offline world map from OpenStreetMap (Planetiler -> OpenMapTiles
# vector tiles) and serves it with TileServer GL behind nginx.
# Target: Ubuntu Server 24.04 LTS VM on Proxmox. Final home: GREY, VLAN 110.
#
# Test mode is the default. Nothing changes without --go.
#
#   sudo bash install.sh                     test mode: settings, pre-flight, plan
#   sudo bash install.sh --format-disks --go format the two blank data disks, mount them
#   sudo bash install.sh --go                run every step that is not done yet
#   sudo bash install.sh --step NAME --go    run one step (packages images assets tiles config service)
#   sudo bash install.sh --check             status and live tests
#   sudo bash install.sh --grey --go         write the GREY static address (takes effect at next boot)
#   sudo bash install.sh --drop-build-disk --go   unmount /build before you delete that disk
#
# Extra: --force   go past the RAM and disk warnings
#        --rebuild-tiles   build the tiles again even though a tile file exists
#
# Settings live in maps.conf next to this script.
# License: CC BY-SA 4.0. Map data: (c) OpenStreetMap contributors, ODbL.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HERE/maps.conf"
STATE_DIR="/var/lib/direwolf-maps"
BACKUP_DIR="/var/backups/direwolf-maps"
SERVICE="direwolf-tileserver"
ALL_STEPS=(packages images assets tiles config service)

GO=0; CHECK=0; FORCE=0; GREY=0; FORMAT=0; DROP_BUILD=0; REBUILD=0; ONLY_STEP=""

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --go) GO=1 ;;
    --check) CHECK=1 ;;
    --force) FORCE=1 ;;
    --grey) GREY=1 ;;
    --format-disks) FORMAT=1 ;;
    --drop-build-disk) DROP_BUILD=1 ;;
    --rebuild-tiles) REBUILD=1 ;;
    --step) shift; ONLY_STEP="${1:-}" ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1"; usage 1 ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash install.sh"; exit 1; }
[ -f "$CONF" ] || { echo "Missing $CONF"; exit 1; }
# shellcheck source=maps.conf
source "$CONF"
# Older maps.conf files have no test point: fall back to Monaco.
: "${TEST_PLACE:=Monaco}" "${TEST_LAT:=43.7384}" "${TEST_LON:=7.4246}"

# ---------------------------------------------------------------- helpers
c_ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
c_warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
c_bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
say()    { printf '\n== %s\n' "$*"; }

# run CMD...: does it with --go, prints it in test mode
run() {
  if [ "$GO" -eq 1 ]; then
    echo "  + $*"
    "$@"
  else
    echo "  WOULD RUN: $*"
  fi
}

# put_file PATH MODE (content on stdin): backs up an existing different file first
put_file() {
  local path="$1" mode="$2" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [ "$GO" -ne 1 ]; then
    echo "  WOULD WRITE: $path"
    rm -f "$tmp"; return 0
  fi
  if [ -f "$path" ] && ! cmp -s "$tmp" "$path"; then
    mkdir -p "$BACKUP_DIR"
    cp -a "$path" "$BACKUP_DIR/$(basename "$path").$(date +%Y%m%d-%H%M%S)"
  fi
  install -D -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  echo "  wrote $path"
}

done_mark()  { [ "$GO" -eq 1 ] && mkdir -p "$STATE_DIR" && date -Is > "$STATE_DIR/$1.done"; return 0; }
is_done()    { [ -f "$STATE_DIR/$1.done" ]; }

ram_gb()  { awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo; }
free_gb() { local d="$1"; while [ ! -d "$d" ]; do d="$(dirname "$d")"; done; df -BG --output=avail "$d" | tail -1 | tr -dc '0-9'; }
is_mount() { mountpoint -q "$1"; }

is_planet() { [ "$AREA" = "planet" ]; }

# Java heap and storage mode for Planetiler, from the VM's RAM.
# Planet rules from Planetiler's PLANET.md: keep nodes in RAM only when RAM is
# at least 1.5x the planet file (~92 GB in 2026, so ~140 GB); otherwise
# memory-map them and keep the heap small so the OS can cache the files.
pick_memory() {
  local r; r="$(ram_gb)"
  if ! is_planet; then
    HEAP="$(( r / 2 > 8 ? 8 : (r / 2 < 1 ? 1 : r / 2) ))g"; STORAGE="ram"; return
  fi
  if [ "$r" -ge 150 ]; then
    HEAP="$(( r - 24 ))g"; STORAGE="ram"
  elif [ "$r" -ge 46 ]; then
    HEAP="20g"; STORAGE="mmap"
  else
    HEAP="12g"; STORAGE="mmap"
  fi
  if [ "$JAVA_HEAP" != "auto" ]; then HEAP="$JAVA_HEAP"; fi
}

test_tile() {  # prints "z x y" of the zoom-14 tile over TEST_LAT, TEST_LON (maps.conf)
  python3 -I -c 'import math, sys
lat, lon, z = float(sys.argv[1]), float(sys.argv[2]), 14
n = 2 ** z
x = int((lon + 180) / 360 * n)
y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
print(z, x, y)' "$TEST_LAT" "$TEST_LON"
}

# ---------------------------------------------------------------- pre-flight
preflight() {
  say "Pre-flight"
  local r cpus mfree bfree need_b need_m problems=0
  r="$(ram_gb)"; cpus="$(nproc)"
  . /etc/os-release
  if [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ]; then c_ok "OS: $PRETTY_NAME"
  else c_warn "OS: ${PRETTY_NAME:-unknown}. Written and tested for Ubuntu 24.04."; fi

  pick_memory
  if is_planet; then
    if [ "$r" -ge 46 ]; then c_ok "RAM: ${r} GB -> Planetiler heap $HEAP, node storage '$STORAGE'"
    elif [ "$r" -ge 30 ]; then c_warn "RAM: ${r} GB. Planet needs about 46 GB+. It may finish, very slowly. Heap $HEAP."; problems=1
    else c_bad "RAM: ${r} GB. Too little for the planet. Give the VM 64 GB for the build."; problems=1; fi
    if [ "$cpus" -ge 12 ]; then c_ok "CPUs: $cpus"; else c_warn "CPUs: $cpus. Works, but expect the build to take most of a day. 16+ is better."; fi
    need_b=1000; need_m=150
    [ "$MAXZOOM" -gt 14 ] && { need_b=1500; need_m=350; }
  else
    c_ok "RAM: ${r} GB, CPUs: $cpus (small test area '$AREA')"
    need_b=20; need_m=10
  fi

  if is_mount "$BUILD_DIR"; then :; else c_warn "$BUILD_DIR is not its own mounted disk (see --format-disks)"; fi
  if is_mount "$MAPS_DIR"; then :; else c_warn "$MAPS_DIR is not its own mounted disk (see --format-disks)"; fi
  bfree="$(free_gb "$BUILD_DIR")"; mfree="$(free_gb "$MAPS_DIR")"
  if [ "$bfree" -ge "$need_b" ]; then c_ok "Build space at $BUILD_DIR: ${bfree} GB free (need ~${need_b})"
  else c_bad "Build space at $BUILD_DIR: ${bfree} GB free, need ~${need_b} GB"; problems=1; fi
  if [ "$mfree" -ge "$need_m" ]; then c_ok "Map space at $MAPS_DIR: ${mfree} GB free (need ~${need_m})"
  else c_bad "Map space at $MAPS_DIR: ${mfree} GB free, need ~${need_m} GB"; problems=1; fi

  if timeout 10 bash -c 'exec 3<>/dev/tcp/github.com/443' 2>/dev/null; then c_ok "Internet: reachable (BUILD mode)"
  else c_warn "Internet: not reachable. Steps packages, images, assets and tiles need it. config/service/check do not."; fi
  PREFLIGHT_PROBLEMS=$problems
}

# ---------------------------------------------------------------- disks
format_disks() {
  say "Data disks"
  local spec dev label mnt opts
  for spec in "$MAPS_DISK|DWMAPS|$MAPS_DIR|defaults,noatime" \
              "$BUILD_DISK|DWBUILD|$BUILD_DIR|defaults,noatime,nofail,x-systemd.device-timeout=10s"; do
    IFS='|' read -r dev label mnt opts <<< "$spec"
    if blkid -L "$label" >/dev/null 2>&1; then
      c_ok "$label already exists on $(blkid -L "$label")"
    else
      [ -b "$dev" ] || { c_bad "$dev does not exist. Check lsblk and MAPS_DISK/BUILD_DISK in maps.conf."; exit 1; }
      [ "$(lsblk -dno TYPE "$dev")" = "disk" ] || { c_bad "$dev is not a whole disk"; exit 1; }
      if [ "$(lsblk -no NAME "$dev" | wc -l)" -ne 1 ] || [ -n "$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)" ] \
         || [ -n "$(blkid -o value -s PTTYPE "$dev" 2>/dev/null || true)" ]; then
        c_bad "$dev is not blank (it has partitions or a filesystem). Not touching it."; exit 1
      fi
      echo "  $dev ($(lsblk -dno SIZE "$dev")) is blank -> ext4, label $label, mounted at $mnt"
      run mkfs.ext4 -q -m 0 -L "$label" "$dev"
    fi
    run mkdir -p "$mnt"
    if ! grep -q "^LABEL=$label " /etc/fstab; then
      if [ "$GO" -eq 1 ]; then
        mkdir -p "$BACKUP_DIR"; cp -a /etc/fstab "$BACKUP_DIR/fstab.$(date +%Y%m%d-%H%M%S)"
        echo "LABEL=$label $mnt ext4 $opts 0 2" >> /etc/fstab; echo "  added $label to /etc/fstab"
      else echo "  WOULD ADD to /etc/fstab: LABEL=$label $mnt ext4 $opts 0 2"; fi
    fi
  done
  run systemctl daemon-reload
  run mount -a
  [ "$GO" -eq 1 ] && df -h "$MAPS_DIR" "$BUILD_DIR"
  return 0
}

drop_build_disk() {
  say "Release the build disk"
  if docker ps -q --filter name='^planetiler$' 2>/dev/null | grep -q .; then
    c_bad "Planetiler is still running. Wait for it."; exit 1
  fi
  [ -s "$MAPS_DIR/data/$TILES_FILE" ] || { c_bad "No $MAPS_DIR/data/$TILES_FILE yet. Do not delete the build disk."; exit 1; }
  if is_mount "$BUILD_DIR"; then run umount "$BUILD_DIR"; fi
  if grep -q '^LABEL=DWBUILD ' /etc/fstab; then
    if [ "$GO" -eq 1 ]; then
      mkdir -p "$BACKUP_DIR"; cp -a /etc/fstab "$BACKUP_DIR/fstab.$(date +%Y%m%d-%H%M%S)"
      sed -i '/^LABEL=DWBUILD /d' /etc/fstab; echo "  removed DWBUILD from /etc/fstab"
    else echo "  WOULD REMOVE the DWBUILD line from /etc/fstab"; fi
  fi
  echo "  Now: shut the VM down, then in Proxmox detach and remove the ~1.2 TB disk (README step 9)."
}

# ---------------------------------------------------------------- steps
step_packages() {
  say "Step packages: Docker, nginx, git, python3"
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io nginx git python3 curl ca-certificates
  run systemctl enable --now docker
  done_mark packages
}

step_images() {
  say "Step images: pull pinned container images"
  run docker pull "$PLANETILER_IMAGE"
  run docker pull "$TILESERVER_IMAGE"
  done_mark images
}

# fetch_commit URL COMMIT DIR: shallow checkout of exactly one commit
fetch_commit() {
  local url="$1" commit="$2" dir="$3"
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$commit" ]; then
    c_ok "$(basename "$dir") already at ${commit:0:7}"; return 0
  fi
  run rm -rf "$dir"
  run git init -q "$dir"
  run git -C "$dir" -c gc.auto=0 fetch -q --depth 1 "$url" "$commit"
  run git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
}

step_assets() {
  say "Step assets: styles, sprites and fonts (pinned commits, fetched from source)"
  local src="$MAPS_DIR/src" entry name repo style_commit sprite_commit
  run mkdir -p "$src"
  for entry in "${STYLES[@]}"; do
    IFS='|' read -r name repo style_commit sprite_commit <<< "$entry"
    fetch_commit "$repo" "$style_commit" "$src/$name"
    fetch_commit "$repo" "$sprite_commit" "$src/$name-sprites"
  done
  echo "  fonts (pre-built glyphs, a few hundred MB)"
  fetch_commit "$FONTS_REPO" "$FONTS_COMMIT" "$src/fonts"
  done_mark assets
}

step_tiles() {
  say "Step tiles: build OpenMapTiles vector tiles with Planetiler ($AREA, zoom 0-$MAXZOOM)"
  local out="$MAPS_DIR/data/$TILES_FILE" built="$BUILD_DIR/output/$TILES_FILE" state code
  if [ -s "$out" ] && [ "$REBUILD" -eq 0 ]; then
    c_ok "$out exists ($(du -h "$out" | cut -f1)). Use --rebuild-tiles to build again."
    done_mark tiles; return 0
  fi

  state="$(docker inspect -f '{{.State.Status}}' planetiler 2>/dev/null || echo none)"
  if [ "$state" = "running" ]; then
    c_warn "Planetiler is still running. Follow it with:  sudo docker logs -f --tail 20 planetiler"
    echo "  Re-run 'sudo bash install.sh --go' when it finishes."; exit 0
  fi
  if [ "$state" = "exited" ]; then
    code="$(docker inspect -f '{{.State.ExitCode}}' planetiler)"
    if [ "$code" = "0" ] && [ -s "$built" ]; then
      c_ok "Planetiler finished. Moving the tiles to $MAPS_DIR/data"
      run mkdir -p "$MAPS_DIR/data"
      [ -f "$out" ] && run mv -f "$out" "$out.previous"
      run mv "$built" "$out"
      if [ "$GO" -eq 1 ]; then
        docker logs planetiler > "$MAPS_DIR/data/planetiler-$(date +%Y%m%d).log" 2>&1 || true
      fi
      run docker rm planetiler
      if [ -f "/etc/systemd/system/$SERVICE.service" ]; then
        echo "  New tiles: clearing the nginx tile cache and restarting the server"
        run find "$MAPS_DIR/cache" -mindepth 1 -delete
        run systemctl restart "$SERVICE" nginx
      fi
      done_mark tiles; return 0
    fi
    c_bad "The last Planetiler run failed (exit $code). Last lines:"
    docker logs --tail 30 planetiler 2>&1 | sed 's/^/    /'
    echo "  Fix the cause, then: sudo docker rm planetiler ; sudo bash install.sh --go"
    exit 1
  fi

  if [ "$PREFLIGHT_PROBLEMS" -ne 0 ] && [ "$FORCE" -eq 0 ] && [ "$GO" -eq 1 ]; then
    c_bad "Pre-flight found problems (above). Fix them, or add --force to try anyway."; exit 1
  fi

  pick_memory
  local args=(--area="$AREA" --download --download-threads=10 --download-chunk-size-mb=1000
              --output="/data/output/$TILES_FILE" --tmpdir=/data/tmp --force
              --nodemap-type=array --storage="$STORAGE" --maxzoom="$MAXZOOM")
  is_planet && args+=(--bounds=planet)
  [ "$FETCH_WIKIDATA" = "yes" ] && args+=(--fetch-wikidata)

  run mkdir -p "$BUILD_DIR/output" "$BUILD_DIR/tmp"
  run docker run -d --name planetiler \
        -e JAVA_TOOL_OPTIONS="-Xmx$HEAP -XX:MaxHeapFreeRatio=40" \
        -v "$BUILD_DIR":/data \
        "$PLANETILER_IMAGE" "${args[@]}"
  echo
  if [ "$GO" -ne 1 ]; then
    echo "  With --go, Planetiler runs in the background and this script stops here."
    echo "  Re-run with --go after it finishes to carry on with config and service."
    return 0
  fi
  echo "  Planetiler is running in the background. It survives a closed SSH window."
  if is_planet; then
    echo "  Expect: ~92 GB download, then several hours of work (16 CPUs: roughly 3-6 hours)."
  fi
  echo "  Watch it:     sudo docker logs -f --tail 20 planetiler     (Ctrl-C stops watching, not the build)"
  echo "  When done:    sudo bash install.sh --go     (moves the tiles and carries on)"
  [ "$GO" -eq 1 ] && exit 0
  return 0
}

step_config() {
  say "Step config: offline styles, fonts, sprites and TileServer GL config"
  local names=() entry name
  for entry in "${STYLES[@]}"; do names+=(--style "${entry%%|*}"); done
  if [ "$GO" -eq 1 ]; then
    python3 -I "$HERE/tools/make-styles.py" --src "$MAPS_DIR/src" --fonts "$MAPS_DIR/src/fonts" \
      --out "$MAPS_DIR" "${names[@]}" --tiles "$TILES_FILE" --attribution "$ATTRIBUTION"
  else
    echo "  WOULD RUN: python3 tools/make-styles.py --src $MAPS_DIR/src --fonts $MAPS_DIR/src/fonts --out $MAPS_DIR ${names[*]}"
  fi
  done_mark config
}

step_service() {
  say "Step service: TileServer GL (systemd + Docker) and nginx with a tile cache"
  put_file "/etc/systemd/system/$SERVICE.service" 644 <<EOF
# Dire Wolf Security - TileServer GL. Written by assets/maps/install.sh
[Unit]
Description=Dire Wolf grey cell map tile server (TileServer GL)
After=docker.service network-online.target
Requires=docker.service

[Service]
ExecStartPre=-/usr/bin/docker rm -f tileserver
ExecStart=/usr/bin/docker run --rm --name tileserver --pull=never -p 127.0.0.1:$TILESERVER_PORT:8080 -v $MAPS_DIR:/data $TILESERVER_IMAGE -c /data/config.json
ExecStop=/usr/bin/docker stop tileserver
Restart=always
RestartSec=10
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

  put_file /etc/nginx/sites-available/direwolf-maps 644 <<EOF
# Dire Wolf Security - map tile server front end. Written by assets/maps/install.sh
proxy_cache_path $MAPS_DIR/cache levels=1:2 keys_zone=tiles:64m max_size=${NGINX_CACHE_GB}g inactive=365d use_temp_path=off;
# Host is part of the key: TileJSON and style URLs name the host the client used
proxy_cache_key "\$scheme\$host\$request_uri";

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # Health check: never cached
    location = /health { proxy_pass http://127.0.0.1:$TILESERVER_PORT; }

    # OpenStreetMap-style short URL for the default style: /{z}/{x}/{y}.png
    # (same path layout as tile.openstreetmap.org, so Leaflet pages need only a host change)
    location ~ "^/(\d+)/(\d+)/(\d+)(@2x)?\.png\$" {
        proxy_pass http://127.0.0.1:$TILESERVER_PORT/styles/$DEFAULT_STYLE/\$1/\$2/\$3\$4.png;
        proxy_cache tiles;
        proxy_cache_valid 200 30d;
        proxy_cache_lock on;
        add_header X-Cache \$upstream_cache_status;
    }

    # Everything else: TileServer GL (viewer, styles, vector data, fonts, raster tiles)
    location / {
        proxy_pass http://127.0.0.1:$TILESERVER_PORT;
        proxy_cache tiles;
        proxy_cache_valid 200 30d;
        proxy_cache_lock on;
        add_header X-Cache \$upstream_cache_status;
    }
}
EOF
  run mkdir -p "$MAPS_DIR/cache"
  run chown www-data:www-data "$MAPS_DIR/cache"
  run ln -sf /etc/nginx/sites-available/direwolf-maps /etc/nginx/sites-enabled/direwolf-maps
  run rm -f /etc/nginx/sites-enabled/default
  run nginx -t
  run systemctl daemon-reload
  run systemctl enable --now "$SERVICE"
  run systemctl restart "$SERVICE"
  run systemctl enable nginx
  run systemctl reload-or-restart nginx
  done_mark service
}

# ---------------------------------------------------------------- GREY move
grey() {
  say "GREY network (VLAN 110): $MAPS_IP/$MAPS_PREFIX via $MAPS_GATEWAY"
  local nic="$MAPS_NIC" f
  if [ -z "$nic" ]; then
    for f in /sys/class/net/en* /sys/class/net/eth*; do [ -e "$f" ] && { nic="$(basename "$f")"; break; }; done
  fi
  [ -n "$nic" ] || { c_bad "No ethernet NIC found. Set MAPS_NIC in maps.conf."; exit 1; }
  echo "  NIC: $nic"
  for f in /etc/netplan/*.yaml; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "60-direwolf-grey.yaml" ] && continue
    if [ "$GO" -eq 1 ]; then
      mkdir -p "$BACKUP_DIR/netplan"; mv "$f" "$BACKUP_DIR/netplan/"; echo "  moved $f to $BACKUP_DIR/netplan/"
    else echo "  WOULD MOVE $f to $BACKUP_DIR/netplan/ (old DHCP config)"; fi
  done
  put_file /etc/cloud/cloud.cfg.d/99-direwolf-no-network.cfg 644 <<'EOF'
network: {config: disabled}
EOF
  put_file /etc/netplan/60-direwolf-grey.yaml 600 <<EOF
# Dire Wolf Security - grey cell map server. Written by assets/maps/install.sh --grey
network:
  version: 2
  ethernets:
    $nic:
      dhcp4: false
      dhcp6: false
      addresses: [$MAPS_IP/$MAPS_PREFIX]
      routes:
        - to: default
          via: $MAPS_GATEWAY
      nameservers:
        addresses: [$MAPS_DNS]
EOF
  put_file /etc/systemd/timesyncd.conf.d/direwolf.conf 644 <<EOF
[Time]
NTP=$MAPS_NTP
FallbackNTP=
EOF
  run hostnamectl set-hostname "$MAPS_HOSTNAME"
  echo
  echo "  Not applied yet, on purpose: applying now would cut off this SSH session."
  echo "  Next: sudo shutdown -h now -> Proxmox: set the NIC to the GREY bridge/tag 110 -> start the VM."
  echo "  Undo: move the files in $BACKUP_DIR/netplan back to /etc/netplan and delete 60-direwolf-grey.yaml."
}

# ---------------------------------------------------------------- check
check() {
  say "Status"
  local s
  for s in docker "$SERVICE" nginx; do
    if systemctl is-active -q "$s" 2>/dev/null; then c_ok "service $s running"; else c_bad "service $s not running"; fi
  done
  for s in "${ALL_STEPS[@]}"; do
    if is_done "$s"; then c_ok "step $s done ($(cat "$STATE_DIR/$s.done"))"; else c_warn "step $s not done"; fi
  done
  if docker inspect planetiler >/dev/null 2>&1; then
    c_warn "Planetiler container: $(docker inspect -f '{{.State.Status}} (exit {{.State.ExitCode}})' planetiler)"
    docker logs --tail 3 planetiler 2>&1 | sed 's/^/    /'
  fi
  ip -4 -br addr | grep -v '^lo' | sed 's/^/  addr  /'
  timedatectl show -p NTPSynchronized --value 2>/dev/null | sed 's/^/  NTP synchronized: /'
  df -h "$MAPS_DIR" 2>/dev/null | tail -1 | sed 's/^/  disk  /'

  say "Offline check (styles, fonts, sprites, data)"
  python3 -I "$HERE/tools/make-styles.py" --verify --out "$MAPS_DIR" || true

  say "Live tests through nginx (http://127.0.0.1)"
  local t z x y f code
  t="$(mktemp -d)"
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/health || true)"
  [ "$code" = "200" ] && c_ok "/health 200" || c_bad "/health returned '$code' (503 = still starting)"
  read -r z x y <<< "$(test_tile)"
  for f in "/0/0/0.png" "/5/9/12.png" "/$z/$x/$y.png" "/styles/$DEFAULT_STYLE/$z/$x/$y@2x.png" "/data/openmaptiles/$z/$x/$y.pbf"; do
    code="$(curl -s -o "$t/tile" -w '%{http_code}' "http://127.0.0.1$f" || true)"
    if [ "$code" = "200" ] && [ -s "$t/tile" ]; then c_ok "$f  ($(stat -c %s "$t/tile") bytes)"
    else c_bad "$f returned '$code'"; fi
  done
  code="$(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1/fonts/Noto%20Sans%20Regular/0-255.pbf' || true)"
  [ "$code" = "200" ] && c_ok "font Noto Sans Regular" || c_bad "font Noto Sans Regular returned '$code'"
  rm -rf "$t"
  echo
  echo "  $TEST_PLACE tile used above: z$z x$x y$y. Open http://<this-ip>/ in a browser for the viewer."
}

# ---------------------------------------------------------------- main
echo "Dire Wolf Security - grey cell map tile server"
[ "$GO" -eq 1 ] && echo "Mode: GO (changes will be made)" || echo "Mode: test (nothing changes; add --go)"
echo "Settings: $CONF"
echo "  area=$AREA  maxzoom=$MAXZOOM  maps=$MAPS_DIR  build=$BUILD_DIR  ip=$MAPS_IP"

if [ "$CHECK" -eq 1 ]; then check; exit 0; fi
if [ "$FORMAT" -eq 1 ]; then format_disks; exit 0; fi
if [ "$DROP_BUILD" -eq 1 ]; then drop_build_disk; exit 0; fi
if [ "$GREY" -eq 1 ]; then grey; exit 0; fi

PREFLIGHT_PROBLEMS=0
preflight

if [ -n "$ONLY_STEP" ]; then
  case " ${ALL_STEPS[*]} " in *" $ONLY_STEP "*) ;; *) echo "Unknown step '$ONLY_STEP'. Steps: ${ALL_STEPS[*]}"; exit 1 ;; esac
  "step_$ONLY_STEP"; exit 0
fi

for s in "${ALL_STEPS[@]}"; do
  if is_done "$s" && { [ "$s" != "tiles" ] || [ "$REBUILD" -eq 0 ]; }; then
    say "Step $s: already done ($(cat "$STATE_DIR/$s.done"))"; continue
  fi
  "step_$s"
done

if [ "$GO" -eq 1 ]; then check; else
  echo; echo "Test mode finished. Nothing was changed. Run again with --go to do the steps above."
fi
