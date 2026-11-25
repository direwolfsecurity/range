#!/usr/bin/env bash
# Dire Wolf Security - create the grey cell map server VM on Proxmox
# Run ON THE BUILD HOST (pve18, at home) as root, and later on pve5 for --to-grey.
# Test mode is the default.
#
#   bash create-vm.sh                 show what it would do
#   bash create-vm.sh --go            create the VM (build size: 24 cores, 48 GB RAM, 3 disks)
#   bash create-vm.sh --to-grey --go  move the NIC to GREY (VLAN 110). VM must be shut down.
#                                     Run this one on pve5 after the restore (README step 10).
#   bash create-vm.sh --slim --go     after the build: 4 cores, 8 GB RAM, delete the build disk.
#                                     VM must be shut down, and install.sh --drop-build-disk done first.
#
# Change the values below to match the host. Check bridge names against
# network\proxmox-hosts.csv before running.
# License: CC BY-SA 4.0
set -euo pipefail

VMID=911
NAME="maps"
ISO="local:iso/ubuntu-24.04.5-live-server-amd64.iso"   # CHANGE to the 24.04 ISO name you uploaded
STORAGE_OS="local-lvm"
STORAGE_MAPS="local-lvm"      # 300 GB, kept, included in backups
STORAGE_BUILD="local-lvm"     # 1200 GB, scratch, excluded from backups, deleted after the build
BUILD_BRIDGE="vmbr0"          # a bridge with internet (home LAN on pve18) for the build
BUILD_TAG=""                  # VLAN tag for the build bridge, blank for none
GREY_BRIDGE="vmbr0"           # the bridge that carries VLAN 110 on pve5 (check proxmox-hosts.csv)
GREY_TAG="110"
BUILD_CORES=24; BUILD_RAM_MB=49152    # pve18: 92 GiB, ~37 GiB already used by other VMs
SLIM_CORES=4;   SLIM_RAM_MB=8192

GO=0; MODE="create"
for a in "$@"; do
  case "$a" in
    --go) GO=1 ;;
    --to-grey) MODE="grey" ;;
    --slim) MODE="slim" ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option $a"; exit 1 ;;
  esac
done

command -v qm >/dev/null || { echo "qm not found. Run this on the Proxmox host."; exit 1; }
run() { if [ "$GO" -eq 1 ]; then echo "+ $*"; "$@"; else echo "WOULD RUN: $*"; fi; }
nic() { local s="virtio,bridge=$1"; [ -n "$2" ] && s="$s,tag=$2"; echo "$s"; }
stopped() { qm status "$VMID" | grep -q 'status: stopped' || { echo "VM $VMID is not shut down."; exit 1; }; }

[ "$GO" -eq 1 ] || echo "Test mode. Nothing changes; add --go."

case "$MODE" in
  create)
    if qm status "$VMID" >/dev/null 2>&1; then echo "VM $VMID already exists. Pick another VMID."; exit 1; fi
    for s in "$STORAGE_OS" "$STORAGE_MAPS" "$STORAGE_BUILD"; do
      pvesm status --storage "$s" >/dev/null 2>&1 || { echo "Storage '$s' not found (pvesm status)."; exit 1; }
    done
    echo "Free space per storage (need: OS 64 GB, maps 300 GB, build 1200 GB):"
    pvesm status | awk 'NR==1 || /active/ {printf "  %-16s %-8s avail %6.0f GB\n", $1, $2, $6/1024/1024}'
    run qm create "$VMID" --name "$NAME" --ostype l26 --machine q35 \
      --cpu host --cores "$BUILD_CORES" --memory "$BUILD_RAM_MB" --balloon 0 \
      --scsihw virtio-scsi-single --agent enabled=1 \
      --net0 "$(nic "$BUILD_BRIDGE" "$BUILD_TAG")" \
      --scsi0 "$STORAGE_OS:64,iothread=1,discard=on,ssd=1" \
      --scsi1 "$STORAGE_MAPS:300,iothread=1,discard=on,ssd=1" \
      --scsi2 "$STORAGE_BUILD:1200,iothread=1,discard=on,ssd=1,backup=0" \
      --ide2 "$ISO,media=cdrom" --boot "order=scsi0;ide2" \
      --description "Dire Wolf grey cell map tile server (TileServer GL). GREY 172.16.11.60. assets/maps"
    echo "Next: start VM $VMID, install Ubuntu Server 24.04 on the 64 GB disk only (README step 3)."
    ;;
  grey)
    stopped
    run qm set "$VMID" --net0 "$(nic "$GREY_BRIDGE" "$GREY_TAG")"
    run qm set "$VMID" --onboot 1
    echo "Next: start the VM. It comes up as 172.16.11.60 on GREY."
    ;;
  slim)
    stopped
    run qm set "$VMID" --cores "$SLIM_CORES" --memory "$SLIM_RAM_MB"
    if qm config "$VMID" | grep -q '^scsi2:'; then
      echo "Deleting the build disk (scsi2). This frees about 1.2 TB on $STORAGE_BUILD."
      run qm disk unlink "$VMID" --idlist scsi2 --force 1
    fi
    run qm set "$VMID" --delete ide2
    ;;
esac
