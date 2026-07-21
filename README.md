# Local Wazuh with Vagrant

This directory runs the existing distributed Wazuh configuration locally using
three Debian 12 VirtualBox VMs. It replaces the AWS-only pieces (AMI, EBS,
ASGs, NLBs, and Route 53) with Vagrant provisioning, persistent VDI data
disks, bridged LAN addresses, and localhost port forwards.

## Topology

| Role | Default bridged IP | VM resources | Persistent data disk |
| --- | --- | --- | --- |
| Indexer | `192.168.0.110` | 4 GiB RAM, 2 CPUs | `disks/indexer.vdi` (100 GiB) |
| Manager | `192.168.0.111` | 4 GiB RAM, 2 CPUs | `disks/manager.vdi` (100 GiB) |
| Dashboard | `192.168.0.112` | 4 GiB RAM, 2 CPUs | `disks/dashboard.vdi` (30 GiB) |

The VMs resolve the same internal names used by the AWS stack:

```text
wazuh-indexer.wazuh.internal
wazuh-manager.wazuh.internal
wazuh-dashboard.wazuh.internal
```


## Before you start

Find your host's network interface name (needed for VM bridging):

```bash
ip -brief link show
```

Then run with your interface (and your LAN's subnet, if different from `192.168.0.0/24`):

```bash
WAZUH_BRIDGE_ADAPTER=<your-interface> \
WAZUH_INDEXER_IP=192.168.x.x \
WAZUH_MANAGER_IP=192.168.x.x \
WAZUH_DASHBOARD_IP=192.168.x.x \
vagrant up
```

If your host is already on `192.168.0.0/24`, only `WAZUH_BRIDGE_ADAPTER` is required.

## Start

From this directory, run:

```bash
vagrant up
```

By default the VMs bridge through host interface `eno1` and use the static LAN
addresses above. Override those values when needed:

```bash
WAZUH_BRIDGE_ADAPTER=eno1 \
WAZUH_INDEXER_IP=192.168.0.110 \
WAZUH_MANAGER_IP=192.168.0.111 \
WAZUH_DASHBOARD_IP=192.168.0.112 \
vagrant up
```

The first run downloads the Debian box, installs Docker in each VM, downloads
the Wazuh images, generates the shared Wazuh certificates, and starts the
roles in dependency order. It can take several minutes.

When it completes, open [https://localhost:8443](https://localhost:8443) or
the bridged dashboard address, such as
[https://192.168.0.112](https://192.168.0.112).
The dashboard uses the credentials defined by the copied Wazuh configuration.

Local-only forwarded ports:

| Host endpoint | Service |
| --- | --- |
| `https://127.0.0.1:8443` | Wazuh dashboard |
| `https://127.0.0.1:19200` | Wazuh indexer API |
| `tcp://127.0.0.1:1514` | Agent event traffic |
| `tcp://127.0.0.1:1515` | Agent enrollment |
| `https://127.0.0.1:55000` | Wazuh manager API |

## Operate

```bash
vagrant status
vagrant ssh indexer
vagrant ssh manager
vagrant ssh dashboard
vagrant halt
vagrant up
```

To see a role's service status:

```bash
vagrant ssh manager -c 'cd /opt/wazuh-distributed/manager && sudo docker compose ps'
```

Re-run only a role's provisioning after changing a script or configuration:

```bash
vagrant provision indexer
vagrant provision manager
vagrant provision dashboard
```

## Data persistence and reset

`vagrant destroy` removes the VMs but deliberately keeps `disks/*.vdi`, so the
Wazuh role data survives recreation. The generated certificates in
`runtime/certs/` are also retained to keep the cluster identity stable.

To reset all local Wazuh data, halt and destroy the VMs, then delete the three
specific VDI files and generated certificate directory before running
`vagrant up` again:

```bash
vagrant destroy -f
rm -f disks/indexer.vdi disks/manager.vdi disks/dashboard.vdi
rm -rf runtime/certs
vagrant up
```

Do not run those removal commands unless a full local reset is intended.

## Source configuration

`config/` is a self-contained copy of the distributed Docker configuration and
Wazuh version file, originally sourced from a separate `wazuh-iac` Terraform
project. It requires no external path or dependency at runtime — everything
Vagrant needs is in this repository. The provisioning script is
intentionally local-only: it never calls AWS, discovers EBS volumes, or
changes any AWS Terraform deployment.
