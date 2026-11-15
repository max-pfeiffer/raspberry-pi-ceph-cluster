#!/usr/bin/env bash
# Print the inventory pins for a Ceph release: the cephadm checksum and the
# multi-arch container image digest.
#
# Usage: ceph-release-pins.sh <version>    e.g. ceph-release-pins.sh 20.2.1
set -euo pipefail

[[ $# -eq 1 ]] || { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
version=$1
accept="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL -o "$tmp" "https://download.ceph.com/rpm-${version}/el9/noarch/cephadm"
cephadm_sha256=$(shasum -a 256 "$tmp" | cut -d' ' -f1)

token=$(curl -fsSL "https://quay.io/v2/auth?service=quay.io&scope=repository:ceph/ceph:pull" \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["token"])')
manifest=$(curl -fsSL -H "Authorization: Bearer $token" -H "Accept: $accept" \
  "https://quay.io/v2/ceph/ceph/manifests/v${version}")
echo "$manifest" | python3 -c '
import json, sys
platforms = [m["platform"]["architecture"] for m in json.load(sys.stdin).get("manifests", [])]
if "arm64" not in platforms:
    sys.exit(f"Image has no arm64 variant (platforms: {platforms})")
'
digest=$(curl -fsSI -H "Authorization: Bearer $token" -H "Accept: $accept" \
  "https://quay.io/v2/ceph/ceph/manifests/v${version}" \
  | awk -F': ' 'tolower($1) == "docker-content-digest" { print $2 }' | tr -d '\r')

cat <<PINS
ceph_version: "${version}"
cephadm_sha256: "${cephadm_sha256}"
ceph_image_digest: "${digest}"
PINS
