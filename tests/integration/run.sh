#!/usr/bin/env bash
# Integration test: runs the real playbooks against the machine it runs on and
# builds a single-node Ceph cluster there. The OSD is a logical volume on a
# loop device.
#
# Only for throwaway CI runners: it renames the host, enables the firewall,
# installs packages and bootstraps Ceph. Refuses to run unless CI=true.
#
# Covered: base, ceph_prereqs and ceph_cluster roles, a second run that must
# change nothing, check mode, and the health gate.
# Also covered: the Kubernetes tenants (pools, quotas, subvolume groups, users).
# Not covered: firmware, network (netplan), reboots, upgrades, more than one node.
set -euo pipefail

[[ ${CI:-} == true ]] || { echo "Refusing to run outside CI (it reconfigures this machine)." >&2; exit 1; }
cd "$(dirname "$0")/../.."

work=build/integration
node=ceph1
osd_vg=ci-osd

group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }
playbook() {
  uv run --no-sync ansible-playbook -i "$work/inventory/hosts.yml" -e @tests/integration/vars.yml "$@"
}
ceph() { sudo /usr/local/sbin/cephadm shell -- ceph "$@"; }

CI_NODE_IP=$(ip -4 route get 1.1.1.1 | awk '{ for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1) }')
export CI_NODE_IP
export ANSIBLE_FORCE_COLOR=true

group "Prepare the runner (node IP $CI_NODE_IP)"
sudo apt-get update -qq
sudo apt-get install -y -qq lvm2 openssh-server
# The base role sets the hostname; sudo must be able to resolve it right away.
echo "$CI_NODE_IP $node.internal $node" | sudo tee -a /etc/hosts
# cephadm manages the node over SSH as root, with its own key.
echo "PermitRootLogin prohibit-password" | sudo tee /etc/ssh/sshd_config.d/00-integration.conf
sudo systemctl restart ssh
# The OSD "disk".
sudo truncate -s 12G /var/tmp/ci-osd.img
loop=$(sudo losetup --find --show /var/tmp/ci-osd.img)
sudo pvcreate "$loop"
sudo vgcreate "$osd_vg" "$loop"
sudo lvcreate --extents 100%FREE --name data "$osd_vg"
# The real group_vars with the test's own hosts.
rm -rf "$work"
mkdir -p "$work"
cp -R inventory "$work/inventory"
rm -rf "$work/inventory/host_vars" "$work/inventory/group_vars/all/vault.yml"
cp tests/integration/hosts.yml "$work/inventory/hosts.yml"
endgroup

playbooks=(playbooks/10-base.yml playbooks/30-ceph-prereqs.yml playbooks/40-ceph-cluster.yml)

group "First run: install and bootstrap"
playbook "${playbooks[@]}"
endgroup

group "Health gate"
playbook tests/integration/health.yml
endgroup

group "Second run: must change nothing"
# Without colors, so the recap line can be matched.
ANSIBLE_FORCE_COLOR=false ANSIBLE_NOCOLOR=true playbook "${playbooks[@]}" | tee "$work/second-run.log"
endgroup
if ! grep -Eq "^$node +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0 " "$work/second-run.log"; then
  echo "::error::The second run was not idempotent (see the changed tasks above)."
  exit 1
fi

# The tenant tasks read `ceph auth ls`, which holds every key of the cluster.
if grep -Eq "AQ[A-Za-z0-9+/]{38}==" "$work/second-run.log"; then
  echo "::error::A Ceph key appears in the playbook output."
  exit 1
fi

group "Check mode on the live cluster"
playbook --check --diff "${playbooks[@]}"
endgroup

group "Verify the cluster"
ceph status
ceph orch ls
ceph orch ps
[[ $(ceph osd stat --format json | jq .num_up_osds) -eq 1 ]] || { echo "::error::Expected 1 OSD up."; exit 1; }
ceph osd pool ls detail --format json \
  | jq -e '.[] | select(.pool_name == "rbd") | .application_metadata | has("rbd")' >/dev/null \
  || { echo "::error::Pool rbd is missing or not initialized."; exit 1; }
ceph fs ls --format json | jq -e '.[] | select(.name == "cephfs")' >/dev/null \
  || { echo "::error::File system cephfs is missing."; exit 1; }
ceph orch ls --format json | jq -e '[.[].service_name] | index("osd.nvme") and index("mds.cephfs")' >/dev/null \
  || { echo "::error::Expected services osd.nvme and mds.cephfs."; exit 1; }
for cluster in production test; do
  ceph osd pool ls detail --format json \
    | jq -e --arg p "k8s-$cluster-rbd" '.[] | select(.pool_name == $p) | (.application_metadata | has("rbd")) and .quota_max_bytes > 0' >/dev/null \
    || { echo "::error::Pool k8s-$cluster-rbd is missing, not initialized or has no quota."; exit 1; }
  ceph fs subvolumegroup info cephfs "k8s-$cluster" \
    | jq -e --arg p "k8s-$cluster-cephfs-data" '.data_pool == $p and (.bytes_quota | type) == "number"' >/dev/null \
    || { echo "::error::Subvolume group k8s-$cluster has the wrong pool or no quota."; exit 1; }
  for role in rbd-provisioner rbd-node cephfs-provisioner cephfs-node; do
    ceph auth get "client.k8s-$cluster-$role" --format json | jq -e '.[0].caps | length > 0' >/dev/null \
      || { echo "::error::User client.k8s-$cluster-$role is missing."; exit 1; }
  done
done
endgroup

echo "Integration test passed."
