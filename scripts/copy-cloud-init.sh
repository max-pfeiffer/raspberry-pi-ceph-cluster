#!/usr/bin/env bash
# Copy the rendered cloud-init files of one node onto the boot partition of a
# freshly flashed OS disk, then eject the disk.
#
# Run on macOS after flashing with Raspberry Pi Imager. The Imager ejects the
# disk when it's done: unplug and replug the enclosure so the volume is mounted.
#
# Usage: copy-cloud-init.sh <cloud-init-dir> [volume]
#   e.g. copy-cloud-init.sh build/cloud-init/ceph1
#
# The volume defaults to /Volumes/system-boot (the label of Ubuntu's boot partition).
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

cloud_init_dir=$1
volume=${2:-/Volumes/system-boot}

for f in user-data network-config meta-data; do
  [[ -f $cloud_init_dir/$f ]] || { echo "Missing $cloud_init_dir/$f. Run: make cloud-init" >&2; exit 1; }
done
[[ -d $volume ]] || { echo "$volume is not mounted. Replug the disk after flashing." >&2; exit 1; }
# The Ubuntu image ships its own user-data and network-config, anything else is the wrong volume.
for f in user-data network-config; do
  [[ -f $volume/$f ]] || { echo "$volume has no $f: not the boot partition of an Ubuntu Raspberry Pi image." >&2; exit 1; }
done

cp "$cloud_init_dir"/{user-data,network-config,meta-data} "$volume"/
for f in user-data network-config meta-data; do
  cmp -s "$cloud_init_dir/$f" "$volume/$f" || { echo "$volume/$f differs from its source after copying." >&2; exit 1; }
done
sync
diskutil eject "$volume"
echo "Done. Cloud-init files of $(basename "$cloud_init_dir") copied, the disk can be unplugged."
