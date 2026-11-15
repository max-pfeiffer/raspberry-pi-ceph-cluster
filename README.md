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
plus a switch (or VLAN) with 2.5 GbE ports for the cluster network.

| Component            | Role                                                     |
|----------------------|----------------------------------------------------------|
| Transcend 110S       | Boot / OS disk (Ubuntu Server LTS)                       |
| Kingston NV3 1 TB    | Ceph OSD (BlueStore, data + DB + WAL on the same disk)   |
| Onboard 1 GbE `eth0` | Ceph **public** network: clients, MON, management, SSH   |
| UGREEN 2.5 GbE USB   | Ceph **cluster** network: OSD replication and heartbeats |

## Ceph nodes
IP and hostnames for nodes:
* ceph1.internal, IP 192.168.30.10
* ceph2.internal, IP 192.168.30.11
* ceph3.internal, IP 192.168.30.12

Gateway: 192.168.30.1
DNS: 192.168.30.1

Cluster network (2.5 GbE): `10.10.30.0/24`, with nodes at `.10`, `.11` and `.12`.
To use a different subnet, change `cluster_network` and `cluster_ip` in the inventory.

## Cluster design

* 3 MONs (one per node, quorum survives one node failure), 2 MGRs (active/standby)
* 3 OSDs, one per node, CRUSH failure domain `host`
* Replicated pools with `size=3`, `min_size=2`. There are too few hosts for erasure coding.
* Capacity: about 3 TB raw, about 1 TB usable; plan for about 800 GB because of the 85 % nearfull limit
* CephFS `cephfs` with 2 MDS (active + standby) and an RBD pool `rbd`
* Monitoring stack (Prometheus, Grafana, Alertmanager) only on `ceph1`, node-exporter everywhere
* Memory budget per 8 GB node: OSD 2.5 GiB, MON 1 GiB, MDS cache 1 GiB (see
  `ceph_config` in `roles/ceph_cluster/defaults/main.yml`)
* All three nodes have the `_admin` label, so `ceph` commands work on any node

## Repository layout

```
ansible.cfg, Makefile           Entry points (`make help`)
inventory/
  hosts.yml                     Nodes, IPs, bootstrap node
  group_vars/all/main.yml       Networks, admin user, NTP, timezone
  group_vars/all/vault.yml      Secrets, encrypted with ansible-vault (you create it)
  group_vars/ceph/main.yml      Ceph version, OSD disk model, placement labels
  host_vars/cephN.yml           Per node: MAC of the 2.5 GbE adapter
playbooks/
  render-cloud-init.yml         Renders first-boot files into build/cloud-init/<host>/
  site.yml                      Runs 00 → 40 in order
  00-firmware.yml               EEPROM boot order, PCIe in config.txt
  10-base.yml                   Hostname, /etc/hosts, chrony, packages, firewall, unattended-upgrades
  20-network.yml                Netplan for both networks, USB autosuspend off
  30-ceph-prereqs.yml           Podman, pinned cephadm, image pre-pull, optional OSD disk wipe
  40-ceph-cluster.yml           Bootstrap, add hosts, config, services, pools, CephFS
  upgrade-ceph.yml              Rolling Ceph upgrade to `ceph_version`
  rolling-reboot.yml            Reboot nodes one by one, waiting for health
roles/                          rpi_firmware, base, network, ceph_prereqs, ceph_cluster
roles/ceph_cluster/templates/   cephadm service specs (cluster.yml, cephfs.yml)
scripts/flash-os-disk.sh        Writes Ubuntu + cloud-init onto the OS disk
```

Principles:

* **Git is the source of truth.** Every change is made in the repo and applied with
  `make site`. Don't use `ceph config set` by hand for anything that should persist.
* **Idempotent.** Running `make site` again changes nothing on a converged cluster.
* **Declarative Ceph.** Daemons and OSDs are described in cephadm service specs and
  the orchestrator converges to them.
* **Pinned versions.** The Ceph release lives in `inventory/group_vars/ceph/main.yml`.
* **Secrets encrypted.** They're kept in `vault.yml` with ansible-vault. Rendered
  cloud-init files are written to `build/`, which is git-ignored.

## Setup

### 1. Prepare your workstation

Requires Python 3 and an SSH key (`~/.ssh/id_ed25519.pub` by default, see
`admin_ssh_public_keys` in `inventory/group_vars/all/main.yml`).

```shell
make deps                 # creates .venv with ansible-core, ansible-lint, yamllint + collections
source .venv/bin/activate
```

Optional: run `pip install pre-commit && pre-commit install` to lint on each commit.

### 2. Create the secrets

```shell
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
$EDITOR inventory/group_vars/all/vault.yml        # set the dashboard password (≥ 12 chars)
ansible-vault encrypt inventory/group_vars/all/vault.yml
```

Commit the encrypted `vault.yml`. To avoid typing the vault password each time, put it in
`.vault-pass` (git-ignored, `chmod 600`). The Makefile picks it up automatically.

### 3. Review the inventory

Check `inventory/hosts.yml` and `inventory/group_vars/`, in particular `cluster_network`,
`ceph_version` and `ceph_osd_device_model`.

### 4. Assemble the hardware

1. Mount the HAT and both SSDs, attach the Active Cooler, plug the 2.5 GbE adapter into a
   **blue USB 3** port.
2. Connect `eth0` to the 192.168.30.0/24 network and the 2.5 GbE adapter to the cluster
   network switch/VLAN.

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
`network-config` (static IP on `eth0`) and `meta-data`.

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

### 9. Find the cluster NIC MAC

The 2.5 GbE adapter is matched by MAC address and renamed to `cluster0`. Read the MACs:

```shell
ansible ceph -a "ip -br link" --ask-vault-pass
```

The adapter appears as `enx<mac>`. Enter each MAC in `inventory/host_vars/cephN.yml`
(`cluster_nic_mac`).

### 10. Run the setup

Run everything at once:

```shell
make site
```

Or run it step by step:

```shell
make firmware        # may reboot nodes, one at a time
make base
make network         # re-applies netplan; eth0 keeps its IP
make ceph-prereqs ARGS="-e wipe_osd_disks=true"   # wipes the Kingston SSDs (first install only)
make ceph
```

Use `wipe_osd_disks=true` only if the Kingston disks have old partitions. Without it,
cephadm ignores disks that aren't empty. The wipe only selects disks whose model matches
`ceph_osd_device_model`, never touches the root disk, and is refused once the cluster
exists.

`make ceph` bootstraps the cluster on `ceph1`, authorizes the cephadm SSH key on all
nodes, applies the configuration, applies the service specs (hosts, MON, MGR, OSD,
monitoring), waits until all 3 OSDs are up, then creates the `rbd` pool and the `cephfs`
file system.

### 11. Verify

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

| Task                               | How                                                                                     |
|------------------------------------|-----------------------------------------------------------------------------------------|
| Change configuration               | Edit the inventory / role defaults, run `make site`                                     |
| Upgrade Ceph                       | Bump `ceph_version`, run `make upgrade` (requires `HEALTH_OK`, upgrades daemon by daemon) |
| Reboot after kernel updates        | `make reboot`: sets `noout`, reboots one node at a time, waits for recovery             |
| Replace a failed OSD               | `ceph orch osd rm <id> --replace --zap`, swap disk; the OSD spec redeploys it           |
| Lint                               | `make lint` (also runs in GitHub Actions)                                               |

Unattended-upgrades installs security updates but never reboots a node on its own.
Use `make reboot` so that only one node is down at a time.

## Notes and pitfalls

* **PCIe bandwidth:** both SSDs share one PCIe Gen2 x1 link through the HAT's ASM1182e
  switch (~450 MB/s total). Forcing Gen3 brings no benefit with this HAT.
* **Kingston NV3** is a DRAM-less consumer SSD without power-loss protection. It's fine
  for a homelab, but sync-write latency (e.g. databases on RBD) will be modest.
* **USB NIC:** USB autosuspend is disabled for the RTL8156B adapter via a udev rule, to
  prevent link flaps on the cluster network. Use a USB 3 port.
* **Time sync matters.** MONs warn about clock skew above 0.05 s. chrony is managed by the
  `base` role.
* **Ubuntu rather than Raspberry Pi OS:** Pi OS uses a 16K page kernel on the Pi 5, which
  can break some arm64 container images. Ubuntu uses 4K pages and is a supported cephadm
  platform.
* **Tear down** (destroys all data): `sudo cephadm rm-cluster --fsid <fsid> --zap-osds --force`
  on every node.
