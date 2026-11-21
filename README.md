# raspberry-pi-ceph-cluster

A three-node [Ceph](https://ceph.io) cluster on Raspberry Pi 5, set up entirely as code:
cloud-init for first boot, Ansible for host configuration, and
[cephadm](https://docs.ceph.com/en/latest/cephadm/) service specs for the cluster
layout. Provides **RBD** (block devices) and **CephFS** (shared file system).

## Hardware
Three Raspberry Pi 5 with:
* 8GB Ram
* [Waveshare PCIe To 2-Ch M.2 Adapter Type B](https://www.waveshare.com/pcie-to-2-ch-m.2-hat-plus-b.htm)
* [Transcend 110S NVMe SSD](https://www.transcend-info.com/product/internal-ssd/mte110s-112s)
* [Kingston NV3 NVMe SSD 1000GB](https://www.kingston.com/en/ssd/nv3-nvme-pcie-ssd)
* [UGREEN 2.5G USB LAN Adapter Ethernet Adapter USB to RJ45 Network Adapter](https://www.amazon.de/dp/B0CWV2Q6HJ)

Also needed: the official 27 W USB-C power supply and the Active Cooler for each Pi,
plus a switch with 2.5 GbE ports.

| Component            | Role                                                           |
|----------------------|----------------------------------------------------------------|
| Transcend 110S       | Boot / OS disk (Ubuntu Server LTS)                             |
| Kingston NV3 1 TB    | Ceph OSD (BlueStore, data + DB + WAL on the same disk)         |
| UGREEN 2.5 GbE USB   | The only network: Ceph clients, MON, replication, SSH, updates |
| Onboard 1 GbE `eth0` | Not used (left unconfigured)                                   |

## Ceph nodes
IP and hostnames for nodes:
* ceph1.internal, IP 192.168.30.10
* ceph2.internal, IP 192.168.30.11
* ceph3.internal, IP 192.168.30.12

Gateway: 192.168.30.1
DNS: 192.168.30.1

All addresses are on the 2.5 GbE adapter. Ceph uses one network for everything; there's
no separate cluster (replication) network.

## Cluster design

* 3 MONs (one per node, quorum survives one node failure), 2 MGRs (active/standby)
* 3 OSDs, one per node, CRUSH failure domain `host`
* Replicated pools with `size=3`, `min_size=2`. There are too few hosts for erasure coding.
* Capacity: about 2.7 TiB raw (3 × 1 TB), about 0.9 TiB usable; plan for about 780 GiB because of the 85 % nearfull limit
* CephFS `cephfs` with 2 MDS (active + standby) on `ceph2` and `ceph3`, and an RBD pool `rbd`
* Kubernetes clusters `production` and `test` are tenants: each has its own RBD pool and
  CephFS data pool with subvolume group, a quota on both, and its own Ceph users that can
  only reach these. Their keys exist only in Ceph and are never stored in a repo: copy
  them into your own secret store (see "Kubernetes clusters")
* Monitoring stack (Prometheus with 7 days retention, Grafana, Alertmanager) only on
  `ceph1`, node-exporter everywhere
* Memory budget per 8 GB node: OSD 2.5 GiB, MON 1 GiB, MDS cache 1 GiB (see
  `ceph_config` in `roles/ceph_cluster/defaults/main.yml`). MDS and monitoring are on
  different nodes so no node runs every memory-hungry daemon at once.
* All three nodes have the `_admin` label, so `ceph` commands work on any node. If `ceph1`
  is down (or was re-flashed and is empty), playbooks automatically use another node
  that runs the cluster for cluster-wide commands.

## Repository layout

```
ansible.cfg, Makefile           Entry points (`make help`)
inventory/
  hosts.yml                     Nodes, IPs, preferred admin/bootstrap node
  group_vars/all/main.yml       Networks, firewall, admin user, timezone
  group_vars/all/vault.yml      Secrets, encrypted with ansible-vault (you create it, git-ignored)
  group_vars/ceph/main.yml      Ceph version + checksums, OSD disk models, placement labels,
                                Kubernetes clusters and their quotas
  host_vars/cephN.yml           Per node labels (ceph1: monitoring, ceph2/3: mds)
playbooks/
  render-cloud-init.yml         Renders first-boot files into build/cloud-init/<host>/
  render-specs.yml              Renders the cephadm service specs into build/specs/ for review
  site.yml                      Runs 00 → 40 in order
  select-admin.yml              Checks all nodes for an existing cluster, picks the node for cluster-wide commands
  00-firmware.yml               EEPROM boot order, optional config.txt lines (one node at a time, reboots health-gated)
  10-base.yml                   Hostname, /etc/hosts, chrony, packages, firewall, unattended-upgrades
  20-network.yml                Netplan for the 2.5 GbE adapter (one node at a time, changes health-gated)
  30-ceph-prereqs.yml           Podman, pinned cephadm, image pre-pull, optional OSD disk wipe
  40-ceph-cluster.yml           Bootstrap, add hosts, config, services, pools, CephFS, Kubernetes tenants
  upgrade-ceph.yml              Rolling Ceph upgrade to `ceph_version`
  rolling-reboot.yml            Reboot nodes one by one, waiting for health
roles/                          rpi_firmware, base, network, ceph_prereqs, ceph_cluster,
                                ceph_maintenance (health gating, rolling reboots)
roles/ceph_cluster/templates/   cephadm service specs (cluster.yml, cephfs.yml)
scripts/flash-os-disk.sh        Writes Ubuntu + cloud-init onto the OS disk
scripts/copy-cloud-init.sh      Copies cloud-init onto a disk flashed on macOS (`make cloud-init-copy`)
scripts/ceph-release-pins.sh    Prints the version pins for a Ceph release
scripts/check-vault-encrypted.sh  Fails on a plain-text vault.yml (pre-commit, `make lint`)
tests/                          Template rendering for `make test`, CI integration test
```

Principles:

* **Git is the source of truth.** Every change is made in the repo and applied with
  `make site`. Don't use `ceph config set` by hand for anything that should persist.
  Removals are manual: something that is just deleted from the repo stays on the
  cluster (see "Remove something" under Day-2 operations).
* **Idempotent.** Running `make site` again changes nothing on a converged cluster.
* **Declarative Ceph.** Daemons and OSDs are described in cephadm service specs and
  the orchestrator converges to them.
* **Pinned versions.** The Ceph release is pinned in `inventory/group_vars/ceph/main.yml`,
  with the cephadm checksum and the container image digest. Ansible, the linters,
  collections and CI actions are pinned to exact versions; Dependabot proposes updates.
* **Safe to rerun on a live cluster.** Playbooks that can disrupt a node (firmware,
  network, reboots) change one node at a time. Before a node is rebooted or its network
  is reconfigured they wait for a healthy cluster, and wait again for recovery before
  moving to the next node. A node without pending changes is not gated, so `make site`
  also works on a degraded cluster. A cluster is only bootstrapped when no node runs
  Ceph daemons, so an empty (re-flashed) node never starts a second cluster. This needs
  at least one node that still runs the cluster: if all nodes are re-flashed, the old
  cluster is gone and a new one is bootstrapped (see step 9 for its OSD disks).
* **Secrets encrypted and local.** They're kept in `vault.yml` with ansible-vault. The
  file is git-ignored, so not even its ciphertext is published; should it be committed
  anyway, pre-commit and `make lint` refuse a plain-text `vault.yml`. Rendered cloud-init
  files and specs are written to `build/`, which is git-ignored.

## Setup

### 1. Prepare your workstation

Requires [uv](https://docs.astral.sh/uv/getting-started/installation/), GNU Make (the
macOS default 3.81 works) and an SSH key (`~/.ssh/id_ed25519.pub` by default, see
`admin_ssh_public_keys` in `inventory/group_vars/all/main.yml`).

```shell
make deps     # Python (from .python-version), locked packages into .venv, collections into ./collections
make hooks    # optional: lint on each commit with pre-commit
```

You don't need to run `make deps` yourself: every target installs whatever is missing
or outdated first, and is a no-op when nothing changed. There's no virtualenv to
activate. For ad-hoc commands, prefix them with `uv run`, e.g. `uv run ansible-vault view …`.

The Python toolchain is defined in `pyproject.toml`. `uv.lock` pins every package,
including transitive dependencies, with hashes. Ansible collections are pinned in
`requirements.yml` and installed into the git-ignored `./collections`, so they're
isolated from `~/.ansible`. To update:

```shell
uv lock --upgrade                 # or: uv lock --upgrade-package ansible-lint
make lint                         # re-syncs automatically because uv.lock changed
```

Dependabot proposes these updates monthly.

### 2. Create the secrets

```shell
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
uv run ansible-vault encrypt inventory/group_vars/all/vault.yml   # choose the vault password
uv run ansible-vault edit inventory/group_vars/all/vault.yml      # set the dashboard password (≥ 12 chars)
```

The file is encrypted before it holds a real secret and only ever edited with
`ansible-vault edit`, so no secret is written to disk in plain text.

Generate the vault password (e.g. 24+ random characters from a password manager) and
store it there: it's the only protection of the file, and without it `vault.yml` can't
be read. To avoid typing it each time, put it in `.vault-pass` (git-ignored) and run
`chmod 600 .vault-pass`. The Makefile picks it up automatically.

`vault.yml` is git-ignored. Don't commit it to a public repo: ansible-vault derives its
key with a fast KDF, so published ciphertext can be brute-forced offline, and it can't
be taken back once it's pushed. Back it up with the vault password in your password
manager. If you want it versioned, do that in a private repo (`git add -f`); pre-commit
and `make lint` then check that it's encrypted.

`vault_ceph_grafana_password` is optional. If set, Grafana gets an admin user when it's
first deployed; otherwise Grafana is read-only.

### 3. Review the inventory

Check `inventory/hosts.yml` and `inventory/group_vars/`, in particular `public_network`,
`firewall_allowed_networks`, `ceph_version` and `ceph_osd_services`.

**Workstation access:** the firewall only lets the networks in `firewall_allowed_networks`
(`inventory/group_vars/all/main.yml`) reach the dashboard, Grafana and the other Ceph
ports; SSH is open to all. If your workstation isn't on `public_network`, add its network
to the list, e.g. `192.168.1.0/24`. The list replaces the role default, so keep
`"{{ public_network }}"` in it, or the nodes can't reach each other. Networks of Ceph
clients such as Kubernetes nodes go into `firewall_ceph_client_networks` instead: they
only reach the Ceph ports (3300, 6789, 6800-7300), not the dashboard or monitoring.

**OSD disks from other vendors:** each entry in `ceph_osd_services` becomes one cephadm
OSD service that picks up empty disks whose model contains its `model` string
(case-sensitive). The nodes can use different SSDs: add one entry per model, e.g.
Kingston on ceph1 and ceph2, Samsung on ceph3. Every node must have exactly one
matching disk, which `make ceph-prereqs` checks. Keep the `service_id` of entries that
already have OSDs; renaming one creates a new service, and the old one has to be removed
by hand.

### 4. Assemble the hardware

1. Mount the HAT and both SSDs, attach the Active Cooler, plug the 2.5 GbE adapter into a
   **blue USB 3** port. Put the Transcend (OS disk) in the HAT's **NVME1** slot: the
   bootloader tries NVME1 first, and Waveshare recommends it for the boot disk.
2. Connect the 2.5 GbE adapter to the 2.5 GbE switch on the 192.168.30.0/24 network.
   The onboard `eth0` port stays unused once Ubuntu is installed.

### 5. Configure the bootloader (one time per Pi)

The Pi must be able to boot from NVMe behind the HAT's PCIe switch. This is the one step
that can't be automated, because no OS is installed yet.

1. Flash **Raspberry Pi OS Lite (64-bit)** onto an SD card and boot the Pi from it.
2. Update the bootloader and set the boot order:

   ```shell
   sudo rpi-eeprom-update -a
   sudo reboot
   sudo rpi-eeprom-config --edit
   ```

   Set or add:

   ```
   BOOT_ORDER=0xf461
   ```

   `0xf461` is read right to left: SD first, then NVMe, then USB. Without an SD card
   the Pi boots from NVMe. To recover a node, insert a Pi OS SD card and power on;
   don't leave a card in otherwise. `PCIE_PROBE=1` isn't needed: the updated bootloader
   finds the NVMe behind the HAT without it. After you save, run `sudo reboot` to apply
   the change.
3. Check that both SSDs are visible: `lsblk -d -o NAME,MODEL,SIZE`. Note the model string
   of the OSD drive (the Kingston). It must be listed in `ceph_osd_services`.

From now on, `playbooks/00-firmware.yml` enforces these settings, so any drift gets
corrected.

### 6. Render the cloud-init files

```shell
make cloud-init           # → build/cloud-init/ceph1/, ceph2/, ceph3/
```

Each directory contains `user-data` (hostname, admin user `ansible`, your SSH key),
`network-config` (static IP on the 2.5 GbE adapter) and `meta-data`.

### 7. Flash Ubuntu onto the Transcend SSD

Download the **Ubuntu Server 24.04 LTS** *preinstalled server image for Raspberry Pi*
(`ubuntu-24.04.…-preinstalled-server-arm64+raspi.img.xz`) from
<https://ubuntu.com/download/raspberry-pi>, and verify its checksum.

Use a release that Ceph tests as a container host for the pinned `ceph_version` (see the
[OS recommendations](https://docs.ceph.com/en/latest/start/os-recommendations/)): for
Ceph 21 that's 24.04 or 22.04, not 26.04. `make ceph-prereqs` refuses any other release;
the list is `ceph_prereqs_supported_ubuntu` in `roles/ceph_prereqs/defaults/main.yml`.

**Option A: on the Pi, still booted from the SD card (no extra hardware):**

```shell
# on your workstation
scp ubuntu-*-raspi.img.xz scripts/flash-os-disk.sh pi@<pi-ip>:
scp -r build/cloud-init/ceph1 pi@<pi-ip>:

# on the Pi: identify the Transcend disk (NOT the OSD disk!)
ls -l /dev/disk/by-id/ | grep nvme
sudo ./flash-os-disk.sh ubuntu-*-raspi.img.xz /dev/disk/by-id/nvme-<Transcend…> ./ceph1 <sha256>
sudo poweroff
```

The script refuses to overwrite the running system's disk, a disk that holds Ceph OSD
data (from any vendor), or a Kingston disk, which protects the still empty OSD disk of a
new node (set `OSD_DISK_MODEL` for an OSD disk from another vendor). It asks for
confirmation, and verifies the image if you pass its SHA256 (from Ubuntu's `SHA256SUMS`)
as the fourth argument.

**Option B: on your Mac with a USB NVMe enclosure:** flash the image with
[Raspberry Pi Imager](https://www.raspberrypi.com/software/) ("Use custom", **no** OS customisation). The Imager ejects
the disk when it's done, so unplug and replug the enclosure. Then run:

```shell
make cloud-init-copy HOST=ceph1
```

It renders the cloud-init files, overwrites `user-data`, `network-config` and `meta-data`
on the `system-boot` volume with those from `build/cloud-init/ceph1/`, and ejects the disk.

Remove the SD card and power on. cloud-init sets up the node on first boot, which
takes a few minutes because it upgrades packages. Repeat for all three Pis.

### 8. Check connectivity

```shell
ssh-keygen -R 192.168.30.10 -R 192.168.30.11 -R 192.168.30.12   # after re-flashing
ssh-keyscan 192.168.30.1{0,1,2} >> ~/.ssh/known_hosts
make ping
```

### 9. Run the setup

Run everything at once:

```shell
make site
# first install on OSD disks that aren't empty (see below):
make site ANSIBLE_ARGS="-e wipe_osd_disks=true"
```

Or run it step by step:

```shell
make firmware        # may reboot nodes, one at a time
make base
make network         # re-applies netplan; the node keeps its IP
make ceph-prereqs ANSIBLE_ARGS="-e wipe_osd_disks=true"   # wipes the OSD SSDs (first install only)
make ceph
```

On a first install, `make firmware` only verifies step 5: the EEPROM settings are
already in place, so it reports no change and doesn't reboot. If it does report a
change, step 5 wasn't completed on that node. Later runs correct any drift, e.g. after
an EEPROM update or on a replacement Pi.

Once the cluster exists, `make firmware` and `make network` gate their disruptive step
(the reboot, `netplan apply`) on cluster health: no health checks and all placement
groups `active+clean`, before and after each node. Nodes without a pending change are
not gated. If the cluster has a known, harmless warning, add its check name to
`ceph_health_allowed_checks` in `inventory/group_vars/ceph/main.yml`, or a run with
pending changes stops after about 30 minutes of waiting. A change that couldn't be
applied is remembered on the node and applied by the next run.

Use `wipe_osd_disks=true` only if the OSD disks have old partitions. Without it,
cephadm ignores disks that aren't empty: the cluster is bootstrapped without OSDs, and
`make site` fails after 20 minutes at "Wait for all OSDs to be up" (see
Troubleshooting). The wipe only selects disks whose model matches
one in `ceph_osd_services`, never touches the root disk, and is refused on a node that runs
Ceph daemons or has a `ceph.conf`, so it only works before the first bootstrap. A disk
that holds Ceph OSD data (for example after re-flashing all nodes of an earlier cluster)
additionally needs `-e wipe_osd_disks_force=true`. Never use that on a
re-flashed node of a cluster that still exists: its disk is a live OSD (see "Replace a
node" under Day-2 operations).

`make ceph` checks all nodes for an existing cluster and bootstraps one on `ceph1` only
if no node runs Ceph daemons and every node could be checked. It then authorizes the
cephadm SSH key on all nodes, applies the configuration,
applies the service specs (hosts, MON, MGR, OSD, monitoring), waits until all 3 OSDs are
up, then creates the `rbd` pool and the `cephfs` file system.

The bootstrap output is hidden because it contains the dashboard password. If bootstrap
fails, rerun with `make ceph ANSIBLE_ARGS="-e ceph_debug=true"` to see it. If a failed bootstrap
leaves a half-built cluster behind, the playbook stops and prints the cleanup commands.

### 10. Verify

```shell
ssh ansible@ceph1
sudo cephadm shell -- ceph -s            # expect HEALTH_OK, 3 mons, 3 osds up/in
sudo cephadm shell -- ceph orch ps       # all daemons and where they run
sudo cephadm shell -- ceph fs status
```

* Dashboard: <https://ceph1.internal:8443> (user `admin`, password from the vault). It
  runs on the active MGR; after a failover, `ceph mgr services` shows its current URL.
* Grafana: <https://ceph1.internal:3000>

Both use self-signed certificates, so the browser shows a warning. They're only
reachable from the networks in `firewall_allowed_networks` (step 3).

Run `make site` a second time. It should finish with `changed=0` on all hosts.

## Using the cluster

Create a client key with the least privileges it needs. Run these commands in
`sudo cephadm shell` on any node.

For Kubernetes, see "Kubernetes clusters" below. For other clients:

**RBD** (e.g. for a VM host):

```shell
ceph auth get-or-create client.rbd-user mon 'profile rbd' osd 'profile rbd pool=rbd' > ceph.client.rbd-user.keyring
rbd create rbd/disk01 --size 50G
```

On the client: `rbd map rbd/disk01 --id rbd-user`. It needs `ceph.conf` (`ceph config
generate-minimal-conf`) and the keyring in `/etc/ceph/`.

**CephFS**:

```shell
ceph fs authorize cephfs client.fs-user / rw > ceph.client.fs-user.keyring
```

On the client: `mount -t ceph ceph1,ceph2,ceph3:/ /mnt/cephfs -o name=fs-user,fs=cephfs`.

To make additional pools or file systems part of the code, add them to `ceph_rbd_pools`
or `ceph_filesystems` in the inventory.

## Kubernetes clusters

The Kubernetes clusters are listed in `ceph_k8s_clusters`
(`inventory/group_vars/ceph/main.yml`). `make ceph` creates for each cluster `<name>`:

| Ceph resource | Name | Purpose |
|---|---|---|
| RBD pool | `k8s-<name>-rbd` | Block volumes (RWO), pool quota `rbd_quota_gib` |
| CephFS data pool | `k8s-<name>-cephfs-data` | File data of the cluster's CephFS volumes |
| CephFS subvolume group | `k8s-<name>` | Parent of all CephFS volumes (RWX), quota `cephfs_quota_gib`, data in the pool above |
| RADOS namespace | `k8s-<name>` in the metadata pool | ceph-csi's CephFS volume journal |
| Ceph users | `client.k8s-<name>-{rbd,cephfs}-{provisioner,node}` | Caps limited to the pools, namespace and path above |

The caps are in `roles/ceph_cluster/templates/k8s-tenants.yml.j2`, and `make ceph` corrects
any drift. A key of one cluster can't read or change the volumes of another. Exception:
the CephFS users need `mgr "allow rw"` for ceph-csi, which can't be narrowed to a tenant,
so treat the CephFS keys like admin credentials. The sum of all quotas must stay below
the usable capacity (about 780 GiB): a full pool stops only its own tenant, but a full
cluster stops all of them.

### Handing the keys to a Kubernetes cluster

The repo and the playbooks never contain or store a key: Ceph creates the keys, and you
copy them into the secret store your Kubernetes clusters use (OpenBao, Vault, a cloud
secret manager, SOPS, Sealed Secrets, ...). Read a key on any node, ideally piped straight
into that store so it's never written to a file:

```shell
ssh ansible@ceph1 sudo cephadm shell -- ceph auth print-key client.k8s-production-rbd-node
```

ceph-csi expects four Secrets per Kubernetes cluster:

| Kubernetes Secret (suggested name) | Fields | Ceph user | Used for |
|---|---|---|---|
| `csi-rbd-provisioner` | `userID`, `userKey` | `k8s-<name>-rbd-provisioner` | RBD provisioner and controller-expand secret |
| `csi-rbd-node` | `userID`, `userKey` | `k8s-<name>-rbd-node` | RBD node-stage secret |
| `csi-cephfs-provisioner` | `adminID`, `adminKey` | `k8s-<name>-cephfs-provisioner` | CephFS provisioner and controller-expand secret |
| `csi-cephfs-node` | `userID`, `userKey` | `k8s-<name>-cephfs-node` | CephFS node-stage secret |

The ID is the user name without `client.`, the key is the output of `ceph auth
print-key`. Deploy the ceph-csi Helm charts with `secret.create: false`, so the keys
don't end up in Helm values either.

The rest of ceph-csi's configuration isn't secret:

* `csiConfig`: `clusterID` from `ceph fsid`, `monitors` from `ceph mon dump` (the msgr1
  addresses, `192.168.30.10:6789,...`, which kernel clients use without extra mount
  options).
* RBD StorageClass: `pool: k8s-<name>-rbd`.
* CephFS: `fsName: cephfs`, and in `csiConfig` `cephFS.subvolumeGroup: k8s-<name>` and
  `cephFS.radosNamespace: k8s-<name>`. The CephFS users can only write ceph-csi's
  journal in that namespace, so the ceph-csi release must support
  `cephFS.radosNamespace`.
* `clusterName: <name>`, so ceph-csi tags every image and subvolume with the cluster
  that owns it.

#### Example: OpenBao and the External Secrets Operator

Store the keys in OpenBao (KV v2 at `secret/`), one path per Ceph user. `userKey=-`
reads the key from stdin, so it's never in a file, the shell history or the process
list:

```shell
for role in rbd-provisioner rbd-node cephfs-node; do
  ssh ansible@ceph1 sudo cephadm shell -- ceph auth print-key "client.k8s-production-$role" \
    | bao kv put -mount=secret "ceph-csi/production/$role" userID="k8s-production-$role" userKey=-
done
ssh ansible@ceph1 sudo cephadm shell -- ceph auth print-key client.k8s-production-cephfs-provisioner \
  | bao kv put -mount=secret ceph-csi/production/cephfs-provisioner \
      adminID=k8s-production-cephfs-provisioner adminKey=-
```

Give each Kubernetes cluster its own policy and auth mount, so `production` and `test`
can only read their own keys (the same for `test`):

```shell
bao policy write ceph-csi-production - <<'HCL'
path "secret/data/ceph-csi/production/*" { capabilities = ["read"] }
HCL
bao auth enable -path=kubernetes-production kubernetes
bao write auth/kubernetes-production/config \
  kubernetes_host=https://<production-api>:6443 kubernetes_ca_cert=@production-ca.crt
bao write auth/kubernetes-production/role/ceph-csi \
  bound_service_account_names=ceph-csi-openbao \
  bound_service_account_namespaces=ceph-csi-rbd,ceph-csi-cephfs \
  token_policies=ceph-csi-production token_ttl=15m
```

The auth method calls the cluster's TokenReview API, so the service account needs the
`system:auth-delegator` ClusterRole (or set `token_reviewer_jwt`). In the Kubernetes
cluster, the External Secrets Operator then creates the Secrets, e.g. in namespace
`ceph-csi-rbd`:

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: openbao
  namespace: ceph-csi-rbd
spec:
  provider:
    vault:
      server: https://openbao.example:8200
      path: secret
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes-production
          role: ceph-csi
          serviceAccountRef:
            name: ceph-csi-openbao
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: csi-rbd-provisioner
  namespace: ceph-csi-rbd
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: SecretStore
  target:
    name: csi-rbd-provisioner
  dataFrom:
    - extract:
        key: ceph-csi/production/rbd-provisioner
# ... and csi-rbd-node; the same for CephFS in namespace ceph-csi-cephfs
```

## Day-2 operations

| Task                        | How                                                                                                  |
|-----------------------------|------------------------------------------------------------------------------------------------------|
| Change configuration        | Edit the inventory / role defaults, run `make site`                                                  |
| Add a Kubernetes cluster    | Add it to `ceph_k8s_clusters`, `make ceph`, then copy its keys into your secret store (see "Kubernetes clusters") |
| Change a Kubernetes quota   | Change `rbd_quota_gib` / `cephfs_quota_gib`, `make ceph`                                              |
| Rotate a Kubernetes key     | `ceph auth rm client.k8s-<name>-<role>`, `make ceph` (creates it with a new key), copy the new key into your secret store, update the Kubernetes Secret, restart the ceph-csi pods. Mounts using the old key stop working once it's removed, so do this in a maintenance window |
| Revoke a Kubernetes cluster | `ceph auth rm` its four `client.k8s-<name>-*` users. No other cluster is affected |
| Remove a Kubernetes cluster | Delete its volumes in Kubernetes, remove it from `ceph_k8s_clusters`, then by hand: `ceph auth rm` its users, `ceph fs subvolumegroup rm cephfs k8s-<name>`, `ceph fs rm_data_pool cephfs k8s-<name>-cephfs-data`, delete both pools (needs `mon_allow_pool_delete`), delete its keys from your secret store |
| Remove something            | Delete it from the repo, then remove it on the cluster by hand: `ceph config rm <who> <option>` for a config option, `ceph orch rm <service>` for a service (e.g. the monitoring stack after setting `ceph_monitoring_enabled: false`), `sudo ufw delete allow proto tcp from <network> to any` on every node for a network removed from `firewall_allowed_networks` |
| Change the dashboard password | In the dashboard, or `ceph dashboard ac-user-set-password admin -i <file>`. The vault value is only used at bootstrap |
| Review the service specs    | `make specs` renders them into `build/specs/` without touching the cluster                           |
| Preview a spec change       | `sudo cephadm shell --mount /etc/ceph/specs:/specs -- ceph orch apply -i /specs/cluster.yml --dry-run` |
| Upgrade Ceph                | `scripts/ceph-release-pins.sh <version>`, copy the three values into `group_vars/ceph/main.yml`, `make upgrade` |
| Reboot a single node        | `make reboot ANSIBLE_ARGS="--limit ceph2"`                                                            |
| Reboot after kernel updates | `make reboot`: requires a healthy cluster, sets `noout`, asks the orchestrator whether each node is safe to stop, reboots one node at a time, waits for recovery, always unsets `noout` |
| Replace a failed OSD        | `ceph orch osd rm <id> --replace --zap`, swap disk; the OSD spec redeploys it                        |
| Replace a node (new OS disk) | Flash it as in steps 6 to 8, run `make site` **without** `wipe_osd_disks`. The node rejoins the existing cluster. If its OSD disk still holds the OSD, bring it back with `ceph cephadm osd activate <host>` |
| Check memory headroom       | `ceph orch ps` (column `MEM USE`) and `free -h` on each node, after a few days of real load           |
| Dry run of all changes      | `make check` (`--check --diff`, changes nothing; reads the live cluster state, so it needs an installed cluster) |
| Lint and test               | `make lint` (yamllint, ansible-lint, shellcheck, actionlint, vault check) and `make test` (syntax check; renders cloud-init files, netplan and specs with dummy secrets and validates them; needs no vault password); CI runs both |
| Check the release pins      | `make check-pins`: the cephadm checksum and image digest in the inventory must belong to `ceph_version` |

Unattended-upgrades installs security updates but never reboots a node on its own.
Upgrades run at staggered times (ceph1 03:00, ceph2 04:00, ceph3 05:00), and
needrestart is configured never to restart Ceph daemons. Use `make reboot` to pick up
kernel and library updates with only one node down at a time.

## Continuous integration

Two workflows run on every push to `main` and every pull request:

* **lint:** `make lint`, `make test`, `make check-pins`, and a secret scan of the whole
  git history (gitleaks).
* **integration:** `tests/integration/run.sh` runs the real `base`, `ceph_prereqs` and
  `ceph_cluster` playbooks against an arm64 runner and builds a single-node Ceph cluster
  on it, with the OSD on a logical volume. It then waits for a healthy cluster, runs
  everything a second time (which must change nothing, and must not print a key) and
  once more in check mode, and verifies the OSD, the `rbd` pool, the `cephfs` file
  system and the Kubernetes tenants. The test's overrides are in
  `tests/integration/vars.yml`.

CI can't cover the Raspberry Pi firmware, the netplan change on the USB adapter,
reboots, upgrades, or anything that needs more than one node.

## Troubleshooting

Run the `ceph` commands in `sudo cephadm shell` on any node.

| Symptom | Cause and fix |
|---------|---------------|
| `make site` fails at "Wait for all OSDs to be up", `ceph osd stat` shows `num_osds: 0` | The OSD disks aren't empty. `ceph orch device ls --wide` shows why under REJECT REASONS, e.g. `LVM detected` or `Has a FileSystem`. `sudo lvs -o lv_name,lv_tags` on a node shows whether the disk holds an OSD and of which cluster (`ceph.cluster_fsid`). If that cluster no longer exists, zap the disks through the orchestrator (destroys their data): `ceph orch device zap <host> /dev/nvme0n1 --force` for each node. The OSD spec creates the OSDs within a few minutes; then rerun `make site`. `wipe_osd_disks` doesn't help here, because it's refused once a cluster exists |
| An OSD disk is missing from `ceph orch device ls` | Its model doesn't match `ceph_osd_services`, or the HAT doesn't detect it: check `lsblk -d -o NAME,MODEL,SIZE` on the node |
| Dashboard or Grafana don't load, SSH works | The firewall: your workstation's network isn't in `firewall_allowed_networks` (step 3). Check with `sudo ufw status` on the node and `nc -z ceph1.internal 8443` on the workstation |
| Dashboard doesn't load, port is open | The MGR failed over and the dashboard moved to another node: `ceph mgr services` shows the current URL |
| `HEALTH_WARN` with `MON_CLOCK_SKEW` | chrony isn't synced: `chronyc tracking` on each node; the nodes need outbound NTP |
| `make firmware`, `make network` or `make reboot` wait for 30 minutes and fail | The cluster isn't healthy, or not all placement groups are `active+clean`. Check `ceph health detail`. For a known, harmless warning, add its check name to `ceph_health_allowed_checks` |
| `make site` stops at "Refuse to continue on a half-bootstrapped node" | A failed bootstrap left a partial cluster. Follow the cleanup commands in the error message, then rerun. For the bootstrap output, rerun with `ANSIBLE_ARGS="-e ceph_debug=true"` |
| SSH fails with `REMOTE HOST IDENTIFICATION HAS CHANGED` | The node was re-flashed and has new host keys: run the commands in step 8 |
| A node is unreachable after `make network` | Netplan didn't come up on the USB adapter. Log in through a keyboard and micro-HDMI console and check `ip link` and `netplan get` |

## Notes and pitfalls

* **PCIe bandwidth:** both SSDs share one PCIe Gen2 x1 link through the HAT's ASM1182e
  switch (~450 MB/s total). Forcing Gen3 brings no benefit with this HAT.
* **Kingston NV3** is a DRAM-less consumer SSD without power-loss protection. It's fine
  for a homelab, but sync-write latency (e.g. databases on RBD) will be modest.
* **Mixed OSD disks:** with `size=3` on three hosts every object has a copy on every
  node, so usable capacity is set by the smallest OSD, and the slowest SSD sets write
  latency. Mix vendors freely, but keep capacities equal.
* **USB NIC:** the 2.5 GbE adapter is each node's only network link. It's matched by
  the name pattern `enx*` (Ubuntu's name for USB NICs), so don't plug a second USB network
  adapter into a node; the `network` role refuses to continue if more than one matches.
  USB autosuspend is disabled for the RTL8156B via a udev rule to prevent link flaps.
  Use a blue USB 3 port. If the adapter fails, the node is offline: Ceph keeps serving
  from the other two nodes. Repair it through a keyboard and micro-HDMI console.
* **Memory is tight.** The budget leaves little headroom on 8 GB, `osd_memory_target`
  is a target rather than a hard limit, and the Ubuntu image has no swap. Watch
  `ceph orch ps` and `free -h` after a few days of real load; if a node gets close to
  the limit, lower `osd_memory_target` or the Prometheus retention before adding swap
  (swapping Ceph daemons hurts more than it helps).
* **Alerts go nowhere by default.** Alertmanager only shows them in its UI and the
  dashboard. Set `ceph_alertmanager_webhook_urls` to get notified.
* **Firewall:** nodes accept TCP on every port from the networks in
  `firewall_allowed_networks` (`public_network` and the workstation LAN), the Ceph ports
  from `firewall_ceph_client_networks` (the Kubernetes nodes), and SSH from anywhere;
  everything else is denied. The networks are the trust boundary: every
  device on them can reach all Ceph and monitoring ports.
* **SSH is open to every network** that can route to the nodes (key-only logins). To
  restrict it, set `firewall_ssh_allowed_networks`; include your workstation's network
  and the cluster network, or you lock yourself and cephadm out.
* **Time sync matters.** MONs warn about clock skew above 0.05 s. The `base` role installs chrony
  with Ubuntu's default configuration (Ubuntu's NTP pools, clock stepped at boot).
* **Ubuntu rather than Raspberry Pi OS:** Pi OS uses a 16K page kernel on the Pi 5, which
  can break some arm64 container images. Ubuntu uses 4K pages and is a supported cephadm
  platform.
* **Tear down** (destroys all data): `sudo cephadm rm-cluster --fsid <fsid> --zap-osds --force`
  on every node.
