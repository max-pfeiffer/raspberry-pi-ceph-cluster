#!/usr/bin/env bash
# Flash an Ubuntu Raspberry Pi image onto the OS disk (Transcend 110S) and
# drop the rendered cloud-init files onto its boot partition.
#
# Run on Linux as root, e.g. on the Pi itself booted from an SD card.
#
# Usage: flash-os-disk.sh <ubuntu-...-raspi.img.xz> <target-disk> <cloud-init-dir>
#   e.g. flash-os-disk.sh ubuntu-26.04-preinstalled-server-arm64+raspi.img.xz \
#          /dev/disk/by-id/nvme-TS256GMTE110S_XXXX ./ceph1
set -euo pipefail

if [[ $# -ne 3 ]]; then
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

image=$1
target=$(readlink -f "$2")
cloud_init_dir=$3

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
