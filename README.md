# Kubernetes Simple Homelab on UTM (Apple Silicon)

A minimal, single-master Kubernetes cluster built from scratch on macOS using UTM (QEMU) virtualization. Fully automated with Ansible — no kubeadm, no managed services, just raw binaries and certificates.

Based on [k8s-utm-ha-homelab](https://github.com/shyamsundart14/k8s-utm-ha-homelab) — a simplified version with fewer VMs and lower resource requirements.

## Highlights

- **Kubernetes v1.32.0** — the hard way, installed from official binaries (ARM64)
- **6 Ubuntu 24.04 VMs** on UTM with cloud-init provisioning
- **HashiCorp Vault PKI** — 3-tier CA hierarchy for all TLS certificates
- **Single etcd node** for simplicity
- **Single master** — no load balancer needed
- **Jump/bastion server** — Mac connects only to jump; all management happens from there
- **Calico CNI** for pod networking
- **Single-command deployment** — one Ansible playbook does everything

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                   Mac Host (Apple Silicon)                       │
│                    192.168.64.1 gateway                          │
└─────────────────────────────┬───────────────────────────────────┘
                              │
                      UTM Shared Network
                       192.168.64.0/24
                              │
       ┌──────────┬───────────┼───────────┬──────────┐
       │          │           │           │          │
  ┌────┴────┐ ┌───┴───┐ ┌────┴────┐ ┌────┴────┐     │
  │  Vault  │ │ Jump  │ │ etcd-1  │ │master-1 │     │
  │   .11   │ │  .12  │ │  .21    │ │  .31    │     │
  │  (PKI)  │ │(bast.)│ │         │ │  (CP)   │     │
  └─────────┘ └───┬───┘ └─────────┘ └────┬────┘     │
                  │                       │          │
             ┌────┴───────────────────────┴──────────┴──┐
             │              Workers                      │
             │  ┌──────────┐  ┌──────────┐               │
             │  │ worker-1 │  │ worker-2 │               │
             │  │   .41    │  │   .42    │               │
             │  └──────────┘  └──────────┘               │
             └───────────────────────────────────────────┘
```

## VM Specifications

| VM | Role | IP | vCPU | RAM | Disk |
|----|------|----|------|-----|------|
| vault | PKI & Secrets (HashiCorp Vault 1.15.4) | 192.168.64.11 | 1 | 2 GB | 20 GB |
| jump | Bastion / Ansible Controller | 192.168.64.12 | 1 | 2 GB | 20 GB |
| etcd-1 | etcd (single node) | 192.168.64.21 | 1 | 2 GB | 20 GB |
| master-1 | K8s control plane | 192.168.64.31 | 2 | 4 GB | 30 GB |
| worker-1 | K8s worker node | 192.168.64.41 | 2 | 4 GB | 40 GB |
| worker-2 | K8s worker node | 192.168.64.42 | 2 | 4 GB | 40 GB |
| **Total** | **6 VMs** | | **9** | **18 GB** | **170 GB** |

## Comparison with HA Setup

| | Simple | HA |
|---|--------|-----|
| Masters | 1 | 2 (behind HAProxy) |
| etcd nodes | 1 | 3 (cluster) |
| Workers | 2 | 3 |
| Load balancer | None | HAProxy |
| Total VMs | 6 | 11 |
| Total RAM | 18 GB | 38 GB |
| Total vCPU | 9 | 22 |
| Fault tolerance | None | Master & etcd HA |

## Component Versions

| Component | Version |
|-----------|---------|
| Kubernetes | 1.32.0 |
| etcd | 3.5.12 |
| containerd | 1.7.24 |
| runc | 1.2.4 |
| Calico CNI | 3.28.0 |
| HashiCorp Vault | 1.15.4 |
| Ubuntu | 24.04 LTS (ARM64 cloud image) |

## Prerequisites

- **macOS** on Apple Silicon (M1/M2/M3/M4)
- **UTM** installed from [utm.app](https://mac.getutm.app/)
- **~18 GB free RAM** (all 6 VMs running simultaneously)

```bash
# Install required tools
brew install ansible

# Link utmctl for CLI-based VM control
sudo ln -sf /Applications/UTM.app/Contents/MacOS/utmctl /usr/local/bin/utmctl

# Install required Ansible collection
cd ansible && ansible-galaxy collection install -r requirements.yml
```

## Quick Start

### Option A: Ansible Playbook (from Mac)

```bash
cd ~/k8s-utm-simple-homelab/ansible
ansible-playbook -i inventory/localhost.yml playbooks/k8s-utm-simple-homelab.yml --ask-become-pass
```

### Option B: Shell Script (standalone, no Ansible required on Mac)

```bash
./scripts/k8s-utm-simple-homelab.sh
```

The shell script does everything in a single run — creates VMs, downloads binaries, bootstraps Vault, deploys etcd, control plane, workers, and Calico. Requires only `utmctl`, `ssh`, and `curl` on the Mac.

---

Both options orchestrate the same deployment:

1. **Creates 6 UTM VMs** with Ubuntu cloud images and cloud-init
2. **Configures Mac** — `/etc/hosts`, SSH config for jump host
3. **Downloads all binaries** in parallel (K8s, etcd, containerd, runc, Calico)
4. **Sets up the jump server** — copies SSH keys, Ansible project, binaries
5. **Bootstraps Vault** — install, initialize, unseal
6. **Configures Vault PKI** — 3-tier CA hierarchy with all certificate roles
7. **Issues & deploys certificates** to all nodes via Vault
8. **Deploys etcd** (single node with TLS)
9. **Deploys control plane** — kube-apiserver, controller-manager, scheduler
10. **Deploys worker nodes** — containerd, kubelet, kube-proxy on 2 workers
11. **Installs Calico CNI** and verifies the cluster

### Access the Cluster

```bash
# SSH to the jump server (only host accessible from Mac)
ssh jump

# From jump, access any VM
ssh master-1
ssh worker-1

# Use kubectl (pre-configured on jump)
kubectl get nodes
kubectl get pods -A
```

## Step-by-Step Deployment

For more control, run each phase individually from the jump server:

```bash
# Phase 1: Bootstrap Vault (install, init, unseal, PKI setup)
ansible-playbook playbooks/vault-full-setup.yml

# Phase 2: Issue and deploy certificates to all nodes
ansible-playbook playbooks/k8s-certs.yml

# Phase 3: Deploy etcd
ansible-playbook playbooks/etcd-cluster.yml

# Phase 4: Deploy control plane
ansible-playbook playbooks/control-plane.yml

# Phase 5: Deploy worker nodes
ansible-playbook playbooks/worker.yml
```

## PKI Architecture

All TLS certificates are issued by HashiCorp Vault using a 3-tier CA hierarchy:

```
Root CA (365 days, pathlen:2)
└── Intermediate CA (180 days, pathlen:1)
    ├── Kubernetes CA (90 days, pathlen:0)
    │   ├── kube-apiserver (server + kubelet-client)
    │   ├── kube-controller-manager
    │   ├── kube-scheduler
    │   ├── admin (cluster-admin)
    │   ├── service-account signing key
    │   ├── kube-proxy
    │   └── kubelet (server + client per node)
    ├── etcd CA (90 days, pathlen:0)
    │   ├── etcd-server
    │   ├── etcd-peer
    │   ├── etcd-client (apiserver → etcd)
    │   └── etcd-healthcheck-client
    └── Front Proxy CA (90 days, pathlen:0)
        └── front-proxy-client (API aggregation)
```

## Project Structure

```
k8s-utm-simple-homelab/
├── README.md
│
├── scripts/
│   ├── k8s-utm-simple-homelab.sh    # Full deploy script (Option B)
│   ├── start_vms.sh                 # Start all 6 VMs
│   ├── stop_vms.sh                  # Stop all VMs (frees RAM)
│   └── destroy_utm_vms.sh           # Delete all VMs (destructive)
│
├── ansible/
│   ├── ansible.cfg                  # Ansible config (forks=12, pipelining)
│   ├── requirements.yml             # community.hashi_vault collection
│   │
│   ├── inventory/
│   │   ├── homelab.yml              # All 6 hosts grouped by role
│   │   └── localhost.yml            # Mac localhost inventory
│   │
│   ├── playbooks/
│   │   ├── k8s-utm-simple-homelab.yml  # Full end-to-end deployment
│   │   ├── vault-bootstrap.yml      # Install & initialize Vault
│   │   ├── vault-pki.yml            # Configure PKI hierarchy
│   │   ├── vault-full-setup.yml     # Bootstrap + PKI combined
│   │   ├── vault-issue-certs.yml    # Issue certs to Vault KV
│   │   ├── k8s-certs.yml           # Issue & deploy certs to nodes
│   │   ├── etcd-cluster.yml         # Deploy etcd
│   │   ├── control-plane.yml        # Deploy K8s master
│   │   ├── worker.yml               # Deploy K8s workers + kubeconfig
│   │   └── ping.yml                 # Connectivity test
│   │
│   └── roles/
│       ├── vm-provision/            # Create UTM VMs with cloud-init
│       ├── mac-setup/               # Configure Mac /etc/hosts + SSH
│       ├── download-binaries/       # Parallel download of all binaries
│       ├── jump-setup/              # Configure bastion server
│       ├── vault-bootstrap/         # Install, init, unseal Vault
│       ├── vault-pki/               # 3-tier CA hierarchy in Vault
│       ├── k8s-certs/               # Issue & deploy certs to nodes
│       ├── etcd/                    # etcd with TLS
│       ├── control-plane/           # apiserver, controller-manager, scheduler
│       └── worker/                  # containerd, kubelet, kube-proxy
│
├── images/                          # Ubuntu cloud images (generated)
├── iso/                             # Cloud-init ISOs (generated)
└── k8s-binaries/                    # Downloaded binaries (cached)
```

## Networking

| Network | CIDR | Purpose |
|---------|------|---------|
| VM Network | 192.168.64.0/24 | UTM shared network for all VMs |
| Service CIDR | 10.96.0.0/12 | Kubernetes ClusterIP services |
| Pod CIDR | 10.244.0.0/16 | Calico pod network |

Workers and control plane components connect directly to master-1 (192.168.64.31:6443) — no load balancer needed with a single master.

## VM Management

```bash
# Start all VMs
./scripts/start_vms.sh

# Stop all VMs (frees ~18 GB RAM)
./scripts/stop_vms.sh

# Destroy all VMs (permanent deletion)
./scripts/destroy_utm_vms.sh
```

> **Note:** After stopping VMs, Vault will need to be unsealed on next start. A `vault-unseal` helper is configured in the jump server's `.bashrc`.

## Ansible Usage

```bash
cd ~/k8s-utm-simple-homelab/ansible

# Test connectivity to all hosts
ansible all -m ping

# Target specific groups
ansible k8s_masters -m shell -a "hostname"
ansible etcd_servers -m shell -a "systemctl is-active etcd"
ansible k8s_workers -m shell -a "systemctl is-active kubelet"
```

## Troubleshooting

### VM doesn't get the correct IP

1. Check cloud-init logs: `sudo cat /var/log/cloud-init-output.log`
2. Verify the cloud-init ISO is attached as a CD-ROM drive
3. Check the network interface name: `ip link show`

### Can't SSH to a VM

1. Verify the VM is running: `utmctl list`
2. Check bridge interface: `ifconfig bridge100`
3. SSH to jump first, then hop: `ssh jump`, then `ssh master-1`

### Vault is sealed after VM restart

```bash
ssh jump
vault-unseal   # helper function in .bashrc
```

### etcd unhealthy

```bash
ssh etcd-1
ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://etcd-1:2379 \
  --cacert=/etc/etcd/pki/ca.crt \
  --cert=/etc/etcd/pki/healthcheck-client.crt \
  --key=/etc/etcd/pki/healthcheck-client.key
```

### API server not responding

```bash
ssh master-1
sudo systemctl status kube-apiserver
sudo journalctl -u kube-apiserver --no-pager -l
```

## License

MIT
