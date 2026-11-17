#!/usr/bin/env bash
# Flash an Ubuntu Raspberry Pi image onto the OS disk (Transcend 110S) and
# drop the rendered cloud-init files onto its boot partition.
#
# Run on Linux as root, e.g. on the Pi itself booted from an SD card.
#
# Usage: flash-os-disk.sh <ubuntu-...-raspi.img.xz> <target-disk> <cloud-init-dir> [image-sha256]
#   e.g. flash-os-disk.sh ubuntu-24.04.4-preinstalled-server-arm64+raspi.img.xz \
#          /dev/disk/by-id/nvme-TS256GMTE110S_XXXX ./ceph1 <sha256 from SHA256SUMS>
#
# Refuses a disk that holds Ceph OSD data, from any vendor, and a Kingston disk
# (the empty OSD disk of a new node). Override the patterns with
# OSD_DISK_MODEL / OS_DISK_MODEL if your hardware differs.
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

image=$1
target=$(readlink -f "$2")
cloud_init_dir=$3
image_sha256=${4:-}
osd_disk_model=${OSD_DISK_MODEL:-KINGSTON}
os_disk_model=${OS_DISK_MODEL:-110S}

[[ $EUID -eq 0 ]] || { echo "Must run as root." >&2; exit 1; }
[[ -f $image ]] || { echo "Image not found: $image" >&2; exit 1; }
[[ -b $target ]] || { echo "Not a block device: $target" >&2; exit 1; }
for f in user-data network-config meta-data; do
  [[ -f $cloud_init_dir/$f ]] || { echo "Missing $cloud_init_dir/$f" >&2; exit 1; }
done

root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")
if [[ /dev/$root_disk == "$target" ]]; then
  echo "Refusing to overwrite the disk the running system booted from ($target)." >&2
  exit 1
fi
if lsblk -no MOUNTPOINTS "$target" | grep -q .; then
  echo "Partitions of $target are mounted. Unmount them first." >&2
  exit 1
fi

model=$(lsblk -dno MODEL "$target")
if [[ $model == *"$osd_disk_model"* ]]; then
  echo "Refusing to flash $target ($model): it looks like the Ceph OSD disk." >&2
  exit 1
fi
if [[ $model != *"$os_disk_model"* ]]; then
  echo "WARNING: $target ($model) does not look like the OS disk (expected a model containing '$os_disk_model')." >&2
fi

# cephadm OSDs are LVM volume groups named ceph-*; raw-mode OSDs carry a
# ceph_bluestore signature. Without lvm2 (e.g. Raspberry Pi OS Lite) the volume
# group names can't be read, so any LVM data is refused.
fstypes=$(lsblk -nro FSTYPE "$target")
if grep -qx ceph_bluestore <<<"$fstypes"; then
  echo "Refusing to flash $target ($model): it holds a Ceph BlueStore OSD." >&2
  exit 1
fi
if grep -qx LVM2_member <<<"$fstypes"; then
  ceph_vgs=""
  if command -v pvs >/dev/null; then
    ceph_vgs=$(pvs --noheadings -o pv_name,vg_name 2>/dev/null \
      | awk -v dev="$target" 'index($1, dev) == 1 && $2 ~ /^ceph-/ { print $2 }' || true)
  fi
  if [[ -n $ceph_vgs ]] || ! command -v pvs >/dev/null; then
    echo "Refusing to flash $target ($model): it holds LVM data${ceph_vgs:+ of Ceph OSDs ($ceph_vgs)}." >&2
    echo "It may be a live OSD of the cluster. If you're sure it isn't, wipe it first: sudo wipefs --all $target" >&2
    exit 1
  fi
fi

if [[ -n $image_sha256 ]]; then
  echo "Verifying checksum of $image ..."
  echo "$image_sha256  $image" | sha256sum --check --quiet
else
  echo "WARNING: no checksum given, the image is not verified." >&2
fi

lsblk -o NAME,SIZE,MODEL,SERIAL "$target"
read -r -p "ALL DATA ON $target WILL BE DESTROYED. Type 'yes' to continue: " answer
[[ $answer == yes ]] || exit 1

echo "Writing $image to $target ..."
xzcat "$image" | dd of="$target" bs=4M conv=fsync status=progress
partprobe "$target"
udevadm settle

boot_part=$(lsblk -lnpo NAME,TYPE "$target" | awk '$2 == "part" { print $1; exit }')
mnt=$(mktemp -d)
trap 'umount "$mnt" 2>/dev/null || true; rmdir "$mnt"' EXIT
mount "$boot_part" "$mnt"
cp "$cloud_init_dir"/{user-data,network-config,meta-data} "$mnt"/
sync
echo "Done. Cloud-init files copied to $boot_part."
