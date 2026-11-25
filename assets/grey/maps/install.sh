#!/usr/bin/env bash
# Dire Wolf Security - grey cell map tile server installer (no Docker)
#
# Builds an offline world map from OpenStreetMap (Planetiler -> OpenMapTiles
# vector tiles) and serves it with TileServer GL behind nginx.
# Planetiler runs as a plain Java program and TileServer GL is installed from
# npm. Both run as systemd services. Docker is not used anywhere.
# Target: a clean Ubuntu Server 24.04 LTS VM on Proxmox. Final home: GREY, VLAN 110.
#
# Test mode is the default. Nothing changes without --go.
#
#   sudo bash install.sh --area monaco --go  small test build (minutes), then serve it
#   sudo bash install.sh --go                do every step that is not done yet (AREA in maps.conf)
#   sudo bash install.sh                     test mode: settings, pre-flight, plan
#   sudo bash install.sh --check             status and live tests
#   sudo bash install.sh --step NAME --go    run one step again (disks packages programs assets tiles config service)
#   sudo bash install.sh --grey --go         write the GREY static address (takes effect at next boot)
#   sudo bash install.sh --drop-build-disk --go   unmount /build before you delete that disk
#
# Extra: --area NAME      build this area instead of AREA in maps.conf (monaco, planet, ...)
#        --force          go past the RAM and disk warnings
#        --rebuild-tiles  build the tiles again even though they are up to date
#        --format-disks   only do the disks step
#
# Safe to run again at any time: finished steps are skipped, and a running
# build is picked up where it is. Settings live in maps.conf next to this script.
# License: GPL-3.0. Map data: (c) OpenStreetMap contributors, ODbL.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HERE/maps.conf"
STATE_DIR="/var/lib/direwolf-maps"
BACKUP_DIR="/var/backups/direwolf-maps"
SERVICE="direwolf-tileserver"
BUILDER="direwolf-planetiler"
ALL_STEPS=(disks packages programs assets tiles config service)

GO=0; CHECK=0; FORCE=0; GREY=0; FORMAT=0; DROP_BUILD=0; REBUILD=0; ONLY_STEP=""; AREA_ARG=""

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

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
    --area) shift; AREA_ARG="${1:-}"; [ -n "$AREA_ARG" ] || { echo "--area needs a name, for example --area monaco"; exit 1; } ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1"; usage 1 ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash install.sh"; exit 1; }
[ -f "$CONF" ] || { echo "Missing $CONF"; exit 1; }
# shellcheck source=maps.conf
source "$CONF"
# Older maps.conf files lack some settings: fall back to the defaults.
: "${TEST_PLACE:=Monaco}" "${TEST_LAT:=43.7384}" "${TEST_LON:=7.4246}"
: "${PLANETILER_VERSION:=0.10.2}" "${PLANETILER_SHA256:=}" "${TILESERVER_VERSION:=5.6.0}"
: "${NODE_VERSION:=22.23.5}" "${NODE_SHA256:=}" "${APP_DIR:=/opt/direwolf-maps}" "${RUN_USER:=dwmaps}"
[ -n "$AREA_ARG" ] && AREA="$AREA_ARG"

NODE_DIR="$APP_DIR/node"
NODE_BIN="$NODE_DIR/bin/node"
TS_DIR="$APP_DIR/tileserver"
TS_MAIN="$TS_DIR/node_modules/tileserver-gl/src/main.js"
JAR="$APP_DIR/planetiler-$PLANETILER_VERSION.jar"
WORK="$BUILD_DIR/planetiler"          # Planetiler's working folder: downloads, scratch, output
BUILD_LOG="$WORK/planetiler.log"
RESULT="$STATE_DIR/planetiler.result"  # written by systemd when Planetiler stops

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
  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 0; fi
  if [ -f "$path" ]; then
    mkdir -p "$BACKUP_DIR"
    cp -a "$path" "$BACKUP_DIR/$(basename "$path").$(date +%Y%m%d-%H%M%S)"
  fi
  install -D -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  echo "  wrote $path"
}

done_mark()  { if [ "$GO" -eq 1 ]; then mkdir -p "$STATE_DIR"; date -Is > "$STATE_DIR/$1.done"; fi; return 0; }
is_done()    { [ -f "$STATE_DIR/$1.done" ]; }

ram_gb()  { awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo; }
free_gb() { local d="$1"; while [ ! -d "$d" ]; do d="$(dirname "$d")"; done; df -BG --output=avail "$d" | tail -1 | tr -dc '0-9'; }
is_mount() { mountpoint -q "$1"; }
is_planet() { [ "$AREA" = "planet" ]; }
builder_running() { systemctl is-active -q "$BUILDER" 2>/dev/null; }
sha_ok() { [ -z "$2" ] || [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]; }
clean_line() { sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\r' | cut -c1-150; }
mins() { local s=$(( $(date +%s) - $1 )); printf '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 )); }

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
  else
    c_bad "OS: ${PRETTY_NAME:-unknown}. This needs Ubuntu Server 24.04."
    echo "        TileServer GL's map-drawing library is built for Ubuntu 24.04's system libraries,"
    echo "        so Debian and other Ubuntu releases do not work. Reinstall the VM with Ubuntu 24.04."
    problems=1
  fi
  if command -v docker >/dev/null 2>&1; then
    c_warn "Docker is installed. This script does not use it. It does no harm, or remove it later."
  fi

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

  if ! is_mount "$BUILD_DIR"; then c_warn "$BUILD_DIR is a folder on the main disk, not its own disk (fine for a small test)"; fi
  if ! is_mount "$MAPS_DIR"; then c_warn "$MAPS_DIR is a folder on the main disk, not its own disk (fine for a small test)"; fi
  bfree="$(free_gb "$BUILD_DIR")"; mfree="$(free_gb "$MAPS_DIR")"
  if [ "$bfree" -ge "$need_b" ]; then c_ok "Build space at $BUILD_DIR: ${bfree} GB free (need ~${need_b})"
  else c_bad "Build space at $BUILD_DIR: ${bfree} GB free, need ~${need_b} GB"; problems=1; fi
  if [ "$mfree" -ge "$need_m" ]; then c_ok "Map space at $MAPS_DIR: ${mfree} GB free (need ~${need_m})"
  else c_bad "Map space at $MAPS_DIR: ${mfree} GB free, need ~${need_m} GB"; problems=1; fi

  if timeout 10 bash -c 'exec 3<>/dev/tcp/github.com/443' 2>/dev/null; then c_ok "Internet: reachable"
  else c_warn "Internet: not reachable. The packages, programs, assets and tiles steps need it."; fi
  PREFLIGHT_PROBLEMS=$problems
}

# ---------------------------------------------------------------- disks
# Formats MAPS_DISK and BUILD_DISK, but only when a disk is completely blank.
# A missing disk is not an error: the folder is then made on the main disk.
step_disks() {
  say "Step disks: the two data disks (only blank disks are formatted)"
  local spec dev label mnt opts changed=0
  for spec in "$MAPS_DISK|DWMAPS|$MAPS_DIR|defaults,noatime" \
              "$BUILD_DISK|DWBUILD|$BUILD_DIR|defaults,noatime,nofail,x-systemd.device-timeout=10s"; do
    IFS='|' read -r dev label mnt opts <<< "$spec"
    if blkid -L "$label" >/dev/null 2>&1; then
      c_ok "$label is on $(blkid -L "$label")"
    elif [ ! -b "$dev" ]; then
      c_warn "No disk $dev. $mnt will be a folder on the main disk. Fine for a small test, not for the planet."
      run mkdir -p "$mnt"; continue
    elif [ "$(lsblk -dno TYPE "$dev")" != "disk" ] || [ "$(lsblk -no NAME "$dev" | wc -l)" -ne 1 ] \
         || [ -n "$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)" ] \
         || [ -n "$(blkid -o value -s PTTYPE "$dev" 2>/dev/null || true)" ]; then
      c_warn "$dev is not blank (it has partitions or a filesystem). Not touching it. Check lsblk and maps.conf."
      run mkdir -p "$mnt"; continue
    else
      echo "  $dev ($(lsblk -dno SIZE "$dev")) is blank -> ext4, label $label, mounted at $mnt"
      run mkfs.ext4 -q -m 0 -L "$label" "$dev"
    fi
    run mkdir -p "$mnt"
    if ! grep -q "^LABEL=$label " /etc/fstab; then
      if [ "$GO" -eq 1 ]; then
        mkdir -p "$BACKUP_DIR"; cp -a /etc/fstab "$BACKUP_DIR/fstab.$(date +%Y%m%d-%H%M%S)"
        echo "LABEL=$label $mnt ext4 $opts 0 2" >> /etc/fstab; echo "  added $label to /etc/fstab"
      else echo "  WOULD ADD to /etc/fstab: LABEL=$label $mnt ext4 $opts 0 2"; fi
      changed=1
    fi
  done
  if [ "$changed" -eq 1 ]; then
    run systemctl daemon-reload
    run mount -a
  fi
  done_mark disks
}

drop_build_disk() {
  say "Release the build disk"
  if builder_running; then c_bad "Planetiler is still running. Wait for it."; exit 1; fi
  [ -s "$MAPS_DIR/data/$TILES_FILE" ] || { c_bad "No $MAPS_DIR/data/$TILES_FILE yet. Do not delete the build disk."; exit 1; }
  if is_mount "$BUILD_DIR"; then run umount "$BUILD_DIR"; fi
  if grep -q '^LABEL=DWBUILD ' /etc/fstab; then
    if [ "$GO" -eq 1 ]; then
      mkdir -p "$BACKUP_DIR"; cp -a /etc/fstab "$BACKUP_DIR/fstab.$(date +%Y%m%d-%H%M%S)"
      sed -i '/^LABEL=DWBUILD /d' /etc/fstab; echo "  removed DWBUILD from /etc/fstab"
    else echo "  WOULD REMOVE the DWBUILD line from /etc/fstab"; fi
  fi
  echo "  Now: shut the VM down, then run create-vm.sh --slim --go on the Proxmox host (README step 7)."
}

# ---------------------------------------------------------------- steps
step_packages() {
  say "Step packages: Java, nginx, and the libraries TileServer GL needs (from Ubuntu)"
  # Runtime: Java 21 for Planetiler, Xvfb (a screen in memory) for map drawing,
  # the drawing libraries, nginx. Build tools: TileServer GL's 'canvas' part is
  # compiled on this machine, the same way TileServer GL's own release is built.
  local pkgs=(openjdk-21-jre-headless nginx git python3 curl ca-certificates xz-utils
              xvfb xauth libopengl0 libglx0 libglfw3 libuv1t64 libcurl4t64 libicu74 libjpeg-turbo8
              libwebp7 libpng16-16t64 libgif7 libcairo2 libpango-1.0-0 librsvg2-2 libjemalloc2
              build-essential pkg-config python3-setuptools libcairo2-dev libpango1.0-dev
              libpng-dev libjpeg-dev libgif-dev librsvg2-dev)
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
  done_mark packages
}

# download URL FILE SHA256: fetch to FILE.part, check, then move into place
download() {
  local url="$1" file="$2" sha="$3"
  run curl -fL --retry 3 --progress-bar -o "$file.part" "$url"
  if [ "$GO" -eq 1 ]; then
    if ! sha_ok "$file.part" "$sha"; then
      rm -f "$file.part"; c_bad "Checksum does not match for $url. Not using it."; exit 1
    fi
    mv "$file.part" "$file"
  fi
}

step_programs() {
  say "Step programs: Node.js $NODE_VERSION, TileServer GL $TILESERVER_VERSION, Planetiler $PLANETILER_VERSION (pinned)"
  run mkdir -p "$APP_DIR"
  if ! id "$RUN_USER" >/dev/null 2>&1; then
    run useradd --system --create-home --home-dir "/var/lib/$RUN_USER" --shell /usr/sbin/nologin "$RUN_USER"
  else c_ok "user $RUN_USER exists"; fi

  # Node.js: the official build from nodejs.org, checked against its SHA-256
  if [ -x "$NODE_BIN" ] && [ "$("$NODE_BIN" -v)" = "v$NODE_VERSION" ]; then
    c_ok "Node.js v$NODE_VERSION"
  else
    local tarball="node-v$NODE_VERSION-linux-x64.tar.xz"
    echo "  Node.js v$NODE_VERSION (about 30 MB)"
    download "https://nodejs.org/dist/v$NODE_VERSION/$tarball" "$APP_DIR/$tarball" "$NODE_SHA256"
    run rm -rf "$APP_DIR/node-v$NODE_VERSION-linux-x64"
    run tar -xJf "$APP_DIR/$tarball" -C "$APP_DIR"
    run ln -sfn "$APP_DIR/node-v$NODE_VERSION-linux-x64" "$NODE_DIR"
    run rm -f "$APP_DIR/$tarball"
  fi

  # TileServer GL from npm, then compile its 'canvas' part against Ubuntu's libraries
  local have=""
  [ -f "$TS_DIR/node_modules/tileserver-gl/package.json" ] && \
    have="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$TS_DIR/node_modules/tileserver-gl/package.json" | head -1)"
  if [ "$have" = "$TILESERVER_VERSION" ] && [ -f "$TS_DIR/.canvas-built" ]; then
    c_ok "TileServer GL $TILESERVER_VERSION"
  else
    echo "  TileServer GL $TILESERVER_VERSION from npm (a few minutes)"
    run mkdir -p "$TS_DIR"
    if [ "$GO" -eq 1 ]; then
      rm -f "$TS_DIR/.canvas-built"
      [ -f "$TS_DIR/package.json" ] || printf '{ "name": "direwolf-tileserver", "private": true }\n' > "$TS_DIR/package.json"
    fi
    run env PATH="$NODE_DIR/bin:$PATH" NODE_ENV=production npm --prefix "$TS_DIR" install \
          --omit=dev --no-audit --no-fund --loglevel=error "tileserver-gl@$TILESERVER_VERSION"
    echo "  compiling the canvas part (about a minute)"
    run env PATH="$NODE_DIR/bin:$PATH" npm --prefix "$TS_DIR" rebuild canvas --build-from-source --loglevel=error
    [ "$GO" -eq 1 ] && touch "$TS_DIR/.canvas-built"
  fi

  # Planetiler: the release jar from GitHub, checked against the SHA-256 in maps.conf
  if [ -s "$JAR" ] && sha_ok "$JAR" "$PLANETILER_SHA256"; then
    c_ok "Planetiler $PLANETILER_VERSION"
  else
    echo "  Planetiler $PLANETILER_VERSION (about 90 MB)"
    download "https://github.com/onthegomap/planetiler/releases/download/v$PLANETILER_VERSION/planetiler.jar" \
             "$JAR" "$PLANETILER_SHA256"
  fi
  done_mark programs
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

# Follow a running build: one progress line at a time. Ctrl-C stops watching only.
watch_build() {
  local start every last="" line
  start="$(date +%s)"; every=10; is_planet && every=60
  echo
  echo "  Planetiler is building the '$AREA' map. It runs as a service, so you can close this"
  echo "  window: the build keeps going. Run the same command again later to watch or finish."
  is_planet && echo "  The planet takes several hours: about 92 GB to download, then the build."
  echo "  Full log: sudo tail -f $BUILD_LOG"
  echo
  trap 'echo; echo "  Stopped watching. The build is still running."; echo "  Run the same command again to watch it or to finish."; exit 0' INT
  while builder_running; do
    line="$(tail -n 1 "$BUILD_LOG" 2>/dev/null | clean_line)"
    if [ -n "$line" ] && [ "$line" != "$last" ]; then printf '  [%s] %s\n' "$(mins "$start")" "$line"; last="$line"; fi
    sleep "$every"
  done
  trap - INT
  echo "  Planetiler stopped after $(mins "$start") of watching."
}

# Move a finished build into place and restart the server if it is installed.
collect_tiles() {
  local out="$MAPS_DIR/data/$TILES_FILE" built="$WORK/output/$TILES_FILE"
  c_ok "Planetiler finished. Moving the tiles to $MAPS_DIR/data (big files take a few minutes)"
  run mkdir -p "$MAPS_DIR/data"
  [ -f "$out" ] && run mv -f "$out" "$out.previous"
  run mv "$built" "$out"
  run chown "$RUN_USER:$RUN_USER" "$MAPS_DIR/data" "$out"
  run cp "$BUILD_LOG" "$MAPS_DIR/data/planetiler-$(date +%Y%m%d-%H%M).log"
  if [ "$GO" -eq 1 ]; then
    rm -f "$RESULT"
    cat "$STATE_DIR/planetiler.area" > "$STATE_DIR/tiles.area" 2>/dev/null || echo "$AREA" > "$STATE_DIR/tiles.area"
  fi
  if [ -f "/etc/systemd/system/$SERVICE.service" ]; then
    echo "  New tiles: clearing the nginx tile cache and restarting the server"
    run find "$MAPS_DIR/cache" -mindepth 1 -delete
    run systemctl restart "$SERVICE" nginx
  fi
  done_mark tiles
}

# After Planetiler stops: collect the tiles, or show why it failed and stop.
finish_build() {
  local built="$WORK/output/$TILES_FILE" res _
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$RESULT" ] && break; sleep 1; done
  res="$(cat "$RESULT" 2>/dev/null || echo "no result recorded")"
  if [ "${res%% *}" = "success" ] && [ -s "$built" ]; then
    collect_tiles; return 0
  fi
  c_bad "The last Planetiler run did not finish ($res). Last lines of its log:"
  tail -n 30 "$BUILD_LOG" 2>/dev/null | clean_line | sed 's/^/    /'
  if [ "$GO" -eq 1 ]; then
    mv -f "$BUILD_LOG" "$BUILD_LOG.failed-$(date +%Y%m%d-%H%M)" 2>/dev/null || true
    rm -f "$RESULT"
  fi
  echo "  Fix the cause (often disk space or RAM), then run the same command again."
  echo "  It starts Planetiler again. Files it already downloaded are kept."
  exit 1
}

step_tiles() {
  say "Step tiles: build OpenMapTiles vector tiles with Planetiler ($AREA, zoom 0-$MAXZOOM)"
  local out="$MAPS_DIR/data/$TILES_FILE" have_area
  have_area="$(cat "$STATE_DIR/tiles.area" 2>/dev/null || true)"

  # 1. A build is running: watch it, then collect it
  if builder_running; then
    c_ok "Planetiler is running (area '$(cat "$STATE_DIR/planetiler.area" 2>/dev/null || echo "?")')"
    [ "$GO" -eq 1 ] || { echo "  Run with --go to watch it and finish."; return 0; }
    watch_build
    finish_build; return 0
  fi

  # 2. A build has stopped since the last run: collect it, or show why it failed
  if [ -f "$RESULT" ]; then finish_build; return 0; fi

  # 3. Tiles for this area are already in place
  if [ -s "$out" ] && [ "$REBUILD" -eq 0 ] && { [ -z "$have_area" ] || [ "$have_area" = "$AREA" ]; }; then
    c_ok "$out exists ($(du -h "$out" | cut -f1), area '${have_area:-unknown}'). Use --rebuild-tiles to build again."
    done_mark tiles; return 0
  fi
  if [ -s "$out" ] && [ -n "$have_area" ] && [ "$have_area" != "$AREA" ]; then
    echo "  The tiles in place are for '$have_area'. Building '$AREA' now."
  fi

  # 4. Start a new build
  if [ "$PREFLIGHT_PROBLEMS" -ne 0 ] && [ "$FORCE" -eq 0 ] && [ "$GO" -eq 1 ]; then
    c_bad "Pre-flight found problems (above). Fix them, or add --force to try anyway."; exit 1
  fi
  pick_memory
  local args=(--area="$AREA" --download --download-threads=10 --download-chunk-size-mb=1000
              --output="$WORK/output/$TILES_FILE" --tmpdir="$WORK/tmp" --force
              --nodemap-type=array --storage="$STORAGE" --maxzoom="$MAXZOOM")
  is_planet && args+=(--bounds=planet)
  [ "$FETCH_WIKIDATA" = "yes" ] && args+=(--fetch-wikidata)

  run mkdir -p "$WORK/output" "$WORK/tmp" "$STATE_DIR"
  run chown -R "$RUN_USER:$RUN_USER" "$WORK"
  put_file "/etc/systemd/system/$BUILDER.service" 644 <<EOF
# Dire Wolf Security - Planetiler map build. Written by assets/grey/maps/install.sh
# Started by install.sh when tiles are needed. Not started at boot.
[Unit]
Description=Dire Wolf map build (Planetiler $PLANETILER_VERSION, area $AREA)
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=$RUN_USER
Group=$RUN_USER
WorkingDirectory=$WORK
ExecStartPre=+/bin/rm -f $RESULT
ExecStart=/usr/bin/java -Xmx$HEAP -XX:MaxHeapFreeRatio=40 -jar $JAR ${args[*]}
ExecStopPost=+/bin/sh -c 'echo "\$SERVICE_RESULT \$EXIT_STATUS" > $RESULT'
StandardOutput=append:$BUILD_LOG
StandardError=append:$BUILD_LOG
LimitNOFILE=65536
Nice=5
Restart=no
TimeoutStopSec=60
EOF
  if [ "$GO" -eq 1 ]; then
    [ -f "$BUILD_LOG" ] && mv -f "$BUILD_LOG" "$BUILD_LOG.$(date +%Y%m%d-%H%M)"
    echo "$AREA" > "$STATE_DIR/planetiler.area"
  fi
  run systemctl daemon-reload
  run systemctl start "$BUILDER"
  [ "$GO" -eq 1 ] || return 0
  sleep 3
  watch_build
  finish_build
}

step_config() {
  say "Step config: offline styles, fonts, sprites and TileServer GL config"
  local names=() entry
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
  say "Step service: TileServer GL (systemd) and nginx with a tile cache"
  local jemalloc=""
  for f in /usr/lib/x86_64-linux-gnu/libjemalloc.so.2 /usr/lib/aarch64-linux-gnu/libjemalloc.so.2; do
    [ -f "$f" ] && { jemalloc="Environment=LD_PRELOAD=$f"; break; }
  done
  put_file "/etc/systemd/system/$SERVICE.service" 644 <<EOF
# Dire Wolf Security - TileServer GL. Written by assets/grey/maps/install.sh
[Unit]
Description=Dire Wolf grey cell map tile server (TileServer GL $TILESERVER_VERSION)
After=network-online.target local-fs.target
Wants=network-online.target

[Service]
Type=exec
User=$RUN_USER
Group=$RUN_USER
WorkingDirectory=$MAPS_DIR
Environment=NODE_ENV=production
$jemalloc
# xvfb-run gives the map-drawing library a screen in memory, as TileServer GL's own release does
ExecStart=/usr/bin/xvfb-run -a -s "-screen 0 1024x768x24 -nolisten tcp" $NODE_BIN $TS_MAIN -c $MAPS_DIR/config.json -b 127.0.0.1 -p $TILESERVER_PORT
PrivateTmp=yes
Restart=always
RestartSec=10
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

  local ipv6_listen="    # (no IPv6 on this VM)"
  [ -e /proc/net/if_inet6 ] && ipv6_listen="    listen [::]:80 default_server;"
  put_file /etc/nginx/sites-available/direwolf-maps 644 <<EOF
# Dire Wolf Security - map tile server front end. Written by assets/grey/maps/install.sh
proxy_cache_path $MAPS_DIR/cache levels=1:2 keys_zone=tiles:64m max_size=${NGINX_CACHE_GB}g inactive=365d use_temp_path=off;
# Host is part of the key: TileJSON and style URLs name the host the client used
proxy_cache_key "\$scheme\$host\$request_uri";

server {
    listen 80 default_server;
$ipv6_listen
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
  run systemctl enable "$SERVICE"
  run systemctl restart "$SERVICE"
  run systemctl enable nginx
  run systemctl reload-or-restart nginx
  if [ "$GO" -eq 1 ]; then
    echo "  waiting for the server to open the tiles (up to 2 minutes)"
    local _
    for _ in $(seq 1 24); do
      [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/health || true)" = "200" ] && break
      sleep 5
    done
  fi
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
# Dire Wolf Security - grey cell map server. Written by assets/grey/maps/install.sh --grey
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
  for s in "$SERVICE" nginx; do
    if systemctl is-active -q "$s" 2>/dev/null; then c_ok "service $s running"; else c_bad "service $s not running"; fi
  done
  for s in "${ALL_STEPS[@]}"; do
    if is_done "$s"; then c_ok "step $s done ($(cat "$STATE_DIR/$s.done"))"; else c_warn "step $s not done"; fi
  done
  [ -f "$STATE_DIR/tiles.area" ] && c_ok "tiles in place are for area '$(cat "$STATE_DIR/tiles.area")'"
  if builder_running; then
    c_warn "Planetiler is still building '$(cat "$STATE_DIR/planetiler.area" 2>/dev/null)'. Latest log line:"
    tail -n 1 "$BUILD_LOG" 2>/dev/null | clean_line | sed 's/^/    /'
  elif [ -f "$RESULT" ]; then
    c_warn "Planetiler stopped ($(cat "$RESULT")). Run 'sudo bash install.sh --go' to finish or see why."
  fi
  ip -4 -br addr 2>/dev/null | grep -v '^lo' | sed 's/^/  addr  /' || true
  timedatectl show -p NTPSynchronized --value 2>/dev/null | sed 's/^/  NTP synchronized: /' || true
  df -h "$MAPS_DIR" 2>/dev/null | tail -1 | sed 's/^/  disk  /' || true

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
  echo "  $TEST_PLACE tile used above: z$z x$x y$y."
  echo "  Open http://$(hostname -I 2>/dev/null | awk '{print $1}')/ in a browser for the map viewer."
}

# ---------------------------------------------------------------- main
echo "Dire Wolf Security - grey cell map tile server (no Docker)"
[ "$GO" -eq 1 ] && echo "Mode: GO (changes will be made)" || echo "Mode: test (nothing changes; add --go)"
echo "Settings: $CONF"
echo "  area=$AREA  maxzoom=$MAXZOOM  maps=$MAPS_DIR  build=$BUILD_DIR  ip=$MAPS_IP"

if [ "$CHECK" -eq 1 ]; then check; exit 0; fi
if [ "$FORMAT" -eq 1 ]; then step_disks; exit 0; fi
if [ "$DROP_BUILD" -eq 1 ]; then drop_build_disk; exit 0; fi
if [ "$GREY" -eq 1 ]; then grey; exit 0; fi

PREFLIGHT_PROBLEMS=0
if [ -n "$ONLY_STEP" ]; then
  case " ${ALL_STEPS[*]} " in *" $ONLY_STEP "*) ;; *) echo "Unknown step '$ONLY_STEP'. Steps: ${ALL_STEPS[*]}"; exit 1 ;; esac
  preflight
  "step_$ONLY_STEP"; exit 0
fi

# Disks first, so the pre-flight sees the real free space.
is_done disks || step_disks
preflight
if [ "$PREFLIGHT_PROBLEMS" -ne 0 ] && [ "$FORCE" -eq 0 ] && [ "$GO" -eq 1 ] && ! is_done packages; then
  echo; c_bad "Pre-flight found problems (above). Fix them, or add --force to try anyway."; exit 1
fi

for s in packages programs assets tiles config service; do
  # programs and tiles check themselves every time (versions, area, a running build)
  if is_done "$s" && [ "$s" != "programs" ] && [ "$s" != "tiles" ]; then
    say "Step $s: already done ($(cat "$STATE_DIR/$s.done"))"; continue
  fi
  "step_$s"
done

if [ "$GO" -eq 1 ]; then
  check
  echo
  echo "Done. If every line above says ok, the map server is working."
else
  echo; echo "Test mode finished. Nothing was changed. Run again with --go to do the steps above."
fi
