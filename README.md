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
* Capacity: about 3 TB raw, about 1 TB usable; plan for about 800 GB because of the 85 % nearfull limit
* CephFS `cephfs` with 2 MDS (active + standby) on `ceph2` and `ceph3`, and an RBD pool `rbd`
* Monitoring stack (Prometheus with 7 days retention, Grafana, Alertmanager) only on
  `ceph1`, node-exporter everywhere
* Memory budget per 8 GB node: OSD 2.5 GiB, MON 1 GiB, MDS cache 1 GiB (see
  `ceph_config` in `roles/ceph_cluster/defaults/main.yml`). MDS and monitoring are on
  different nodes so no node runs every memory-hungry daemon at once.
* All three nodes have the `_admin` label, so `ceph` commands work on any node. If `ceph1`
  is down, playbooks automatically use another node for cluster-wide commands.

## Repository layout

```
ansible.cfg, Makefile           Entry points (`make help`)
inventory/
  hosts.yml                     Nodes, IPs, preferred admin/bootstrap node
  group_vars/all/main.yml       Networks, admin user, NTP, timezone
  group_vars/all/vault.yml      Secrets, encrypted with ansible-vault (you create it)
  group_vars/ceph/main.yml      Ceph version + checksums, OSD disk model, placement labels
  host_vars/cephN.yml           Per node labels (ceph1: monitoring, ceph2/3: mds)
playbooks/
  render-cloud-init.yml         Renders first-boot files into build/cloud-init/<host>/
  site.yml                      Runs 00 → 40 in order
  select-admin.yml              Picks the node for cluster-wide commands (ceph1, else first reachable)
  00-firmware.yml               EEPROM boot order, PCIe in config.txt (one node at a time, health-gated)
  10-base.yml                   Hostname, /etc/hosts, chrony, packages, firewall, unattended-upgrades
  20-network.yml                Netplan for the 2.5 GbE adapter (one node at a time, health-gated)
  30-ceph-prereqs.yml           Podman, pinned cephadm, image pre-pull, optional OSD disk wipe
  40-ceph-cluster.yml           Bootstrap, add hosts, config, services, pools, CephFS
  upgrade-ceph.yml              Rolling Ceph upgrade to `ceph_version`
  rolling-reboot.yml            Reboot nodes one by one, waiting for health
roles/                          rpi_firmware, base, network, ceph_prereqs, ceph_cluster,
                                ceph_maintenance (health gating, rolling reboots)
roles/ceph_cluster/templates/   cephadm service specs (cluster.yml, cephfs.yml)
scripts/flash-os-disk.sh        Writes Ubuntu + cloud-init onto the OS disk
scripts/ceph-release-pins.sh    Prints the version pins for a Ceph release
```

Principles:

* **Git is the source of truth.** Every change is made in the repo and applied with
  `make site`. Don't use `ceph config set` by hand for anything that should persist.
* **Idempotent.** Running `make site` again changes nothing on a converged cluster.
* **Declarative Ceph.** Daemons and OSDs are described in cephadm service specs and
  the orchestrator converges to them.
* **Pinned versions.** The Ceph release is pinned in `inventory/group_vars/ceph/main.yml`,
  with the cephadm checksum and the container image digest. Ansible, the linters,
  collections and CI actions are pinned to exact versions; Dependabot proposes updates.
* **Safe to rerun on a live cluster.** Playbooks that can disrupt a node (firmware,
  network, reboots) change one node at a time. They first wait for a healthy cluster,
  and wait again for recovery before moving to the next node.
* **Secrets encrypted.** They're kept in `vault.yml` with ansible-vault. Rendered
  cloud-init files are written to `build/`, which is git-ignored.

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
$EDITOR inventory/group_vars/all/vault.yml        # set the dashboard password (≥ 12 chars)
uv run ansible-vault encrypt inventory/group_vars/all/vault.yml
```

Commit the encrypted `vault.yml`. To avoid typing the vault password each time, put it in
`.vault-pass` (git-ignored, `chmod 600`). The Makefile picks it up automatically.

### 3. Review the inventory

Check `inventory/hosts.yml` and `inventory/group_vars/`, in particular `public_network`,
`ceph_version` and `ceph_osd_device_model`.

### 4. Assemble the hardware

1. Mount the HAT and both SSDs, attach the Active Cooler, plug the 2.5 GbE adapter into a
   **blue USB 3** port.
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
   BOOT_ORDER=0xf416
   PCIE_PROBE=1
   ```

   `0xf416` tries NVMe first, then SD, then USB. `PCIE_PROBE=1` is required for M.2
   adapters without a HAT+ EEPROM. After you save, run `sudo reboot` to apply the change.
3. Check that both SSDs are visible: `lsblk -d -o NAME,MODEL,SIZE`. Note the model string
   of the Kingston drive. It must match `ceph_osd_device_model`.

From now on, `playbooks/00-firmware.yml` enforces these settings, so any drift gets
corrected.

### 6. Render the cloud-init files

```shell
make cloud-init           # → build/cloud-init/ceph1/, ceph2/, ceph3/
```

Each directory contains `user-data` (hostname, admin user `ansible`, your SSH key),
`network-config` (static IP on the 2.5 GbE adapter) and `meta-data`.

### 7. Flash Ubuntu onto the Transcend SSD

Download the **Ubuntu Server 26.04 LTS** (or 24.04 LTS) *preinstalled server image
for Raspberry Pi* (`ubuntu-…-preinstalled-server-arm64+raspi.img.xz`) from
<https://ubuntu.com/download/raspberry-pi>, and verify its checksum.

**Option A: on the Pi, still booted from the SD card (no extra hardware):**

```shell
# on your workstation
scp ubuntu-*-raspi.img.xz scripts/flash-os-disk.sh pi@<pi-ip>:
scp -r build/cloud-init/ceph1 pi@<pi-ip>:

# on the Pi: identify the Transcend disk (NOT the Kingston!)
ls -l /dev/disk/by-id/ | grep nvme
sudo ./flash-os-disk.sh ubuntu-*-raspi.img.xz /dev/disk/by-id/nvme-<Transcend…> ./ceph1
sudo poweroff
```

The script refuses to overwrite the running system's disk and asks for confirmation.

**Option B: on your Mac with a USB NVMe enclosure:** flash the image with
Raspberry Pi Imager ("Use custom", **no** OS customisation), then copy `user-data`,
`network-config` and `meta-data` from `build/cloud-init/<host>/` onto the `system-boot`
volume and overwrite the existing files.

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
```

Or run it step by step:

```shell
make firmware        # may reboot nodes, one at a time
make base
make network         # re-applies netplan; the node keeps its IP
make ceph-prereqs ANSIBLE_ARGS="-e wipe_osd_disks=true"   # wipes the Kingston SSDs (first install only)
make ceph
```

`make firmware` and `make network` wait for `HEALTH_OK` before and after each node once
the cluster exists. If the cluster has a known, harmless warning, add its check name to
`ceph_health_allowed_checks` in `inventory/group_vars/ceph/main.yml`, or the run stops
after about 30 minutes of waiting.

Use `wipe_osd_disks=true` only if the Kingston disks have old partitions. Without it,
cephadm ignores disks that aren't empty. The wipe only selects disks whose model matches
`ceph_osd_device_model`, never touches the root disk, and is refused once the cluster
exists.

`make ceph` bootstraps the cluster on `ceph1` (only if no cluster exists yet), authorizes the cephadm SSH key on all
nodes, applies the configuration, applies the service specs (hosts, MON, MGR, OSD,
monitoring), waits until all 3 OSDs are up, then creates the `rbd` pool and the `cephfs`
file system.

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

* Dashboard: <https://ceph1.internal:8443> (user `admin`, password from the vault)
* Grafana: <https://ceph1.internal:3000>

Run `make site` a second time. It should finish with `changed=0` on all hosts.

## Using the cluster

Create a client key with the least privileges it needs. Run these commands in
`sudo cephadm shell` on any node.

**RBD** (e.g. for a VM host or Kubernetes via ceph-csi):

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

## Day-2 operations

| Task                        | How                                                                                                  |
|-----------------------------|------------------------------------------------------------------------------------------------------|
| Change configuration        | Edit the inventory / role defaults, run `make site`                                                  |
| Preview a spec change       | `sudo cephadm shell --mount /etc/ceph/specs:/specs -- ceph orch apply -i /specs/cluster.yml --dry-run` |
| Upgrade Ceph                | `scripts/ceph-release-pins.sh <version>`, copy the three values into `group_vars/ceph/main.yml`, `make upgrade` |
| Reboot after kernel updates | `make reboot`: requires a healthy cluster, sets `noout`, reboots one node at a time, waits for recovery, always unsets `noout` |
| Replace a failed OSD        | `ceph orch osd rm <id> --replace --zap`, swap disk; the OSD spec redeploys it                        |
| Check memory headroom       | `ceph orch ps` (column `MEM USE`) and `free -h` on each node, after a few days of real load           |
| Dry run of all changes      | `make check` (`--check --diff`, changes nothing)                                                            |
| Lint                        | `make lint` (yamllint, ansible-lint, shellcheck; CI runs the same `make deps lint`) |

Unattended-upgrades installs security updates but never reboots a node on its own.
Upgrades run at staggered times (ceph1 03:00, ceph2 04:00, ceph3 05:00), and
needrestart is configured never to restart Ceph daemons. Use `make reboot` to pick up
kernel and library updates with only one node down at a time.

## Notes and pitfalls

* **PCIe bandwidth:** both SSDs share one PCIe Gen2 x1 link through the HAT's ASM1182e
  switch (~450 MB/s total). Forcing Gen3 brings no benefit with this HAT.
* **Kingston NV3** is a DRAM-less consumer SSD without power-loss protection. It's fine
  for a homelab, but sync-write latency (e.g. databases on RBD) will be modest.
* **USB NIC:** the 2.5 GbE adapter is each node's only network link. It's matched by
  the name pattern `enx*` (Ubuntu's name for USB NICs), so don't plug a second USB network
  adapter into a node; the `network` role refuses to continue if more than one matches.
  USB autosuspend is disabled for the RTL8156B via a udev rule to prevent link flaps.
  Use a blue USB 3 port. If the adapter fails, the node is offline: Ceph keeps serving
  from the other two nodes. Repair it through a keyboard and micro-HDMI console.
* **Time sync matters.** MONs warn about clock skew above 0.05 s. chrony is managed by the
  `base` role.
* **Ubuntu rather than Raspberry Pi OS:** Pi OS uses a 16K page kernel on the Pi 5, which
  can break some arm64 container images. Ubuntu uses 4K pages and is a supported cephadm
  platform.
* **Tear down** (destroys all data): `sudo cephadm rm-cluster --fsid <fsid> --zap-osds --force`
  on every node.
