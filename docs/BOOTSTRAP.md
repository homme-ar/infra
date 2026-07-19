# Kubernetes & Talos Linux Cluster Configuration (`talhelper`)

This directory contains the GitOps declarative configuration and initialization scripts for the Kubernetes cluster across the 3 **Minisforum MS-A2** nodes (`ser-msa2cp1`, `ser-msa2cp2`, `ser-msa2cp3`) using `talhelper` and Talos Linux.

## File Structure

- `talconfig.yaml`: Main cluster configuration file defining cluster metadata, VIP (`10.0.20.1`), network interfaces (`enp5s0f0np0`), system disk selectors (`FORESEE*`), Sidero Labs schematics, and Talos/Kubernetes versions.
- `patches/global/longhorn-storage.yaml`: Talos machine patch (`machine.disks`) that partitions, formats (ext4/xfs), and mounts the 1TB NVMe disk (`KINGSTON SKC3000*`) at `/var/lib/longhorn`, with shared bind mounts configured for Kubelet.
- `patches/nodes/ser-msa2cp1-gpu.yaml`: Node-specific Talos patch loading NVIDIA kernel modules and applying `nvidia.com/gpu.present: "true"` node labels for `ser-msa2cp1`.
- `talsecret.sops.yaml` (Generated): SOPS and Age encrypted secret file containing etcd, Talos, and Kubernetes cryptographic materials.

---

## Prerequisites

Ensure your development shell is active via `direnv allow` or `nix develop` to access required binaries (`talhelper`, `talosctl`, `sops`, `age`, `kubectl`).

---

## 1. Cluster Secrets Management (`talsecret.sops.yaml`)

If you need to generate a new secret file for the cluster:

### Encrypting with SOPS + Age (Recommended for GitOps)
Verify that your Age private key is present in `~/.config/sops/age/keys.txt` (automatically loaded by `.envrc`), and run:
```bash
# Generate plaintext secrets in memory and immediately encrypt with SOPS
talhelper gensecret | sops --encrypt --filename-override talsecret.sops.yaml /dev/stdin > talsecret.sops.yaml
```

*(Note: Never commit unencrypted `talsecret.yaml` files to version control).*

---

## 2. Generating Cluster Configurations (`talosconfig` and node manifests)

Once `talsecret.sops.yaml` is present, generate node configurations from `talconfig.yaml`:

```bash
talhelper genconfig
```

This command automatically decrypts `talsecret.sops.yaml` in memory and generates the `clusterconfig/` directory containing:
- `clusterconfig/talosconfig`: Client configuration file for `talosctl`.
- `clusterconfig/homme-cluster-ser-msa2cp1.yaml`: Node configuration for Node 1 (`10.0.20.2`).
- `clusterconfig/homme-cluster-ser-msa2cp2.yaml`: Node configuration for Node 2 (`10.0.20.3`).
- `clusterconfig/homme-cluster-ser-msa2cp3.yaml`: Node configuration for Node 3 (`10.0.20.4`).

---

## 3. Cluster Bootstrap & Initialization Walkthrough

### Step A: Apply Configuration to the First Node (`ser-msa2cp1`)
With Node 1 booted into maintenance mode via Talos USB (displaying its temporary DHCP IP on screen, e.g., `10.0.208.118`), apply its manifest:

```bash
talosctl apply-config --insecure --nodes 10.0.208.118 --file clusterconfig/homme-cluster-ser-msa2cp1.yaml
```

*(The node will reboot and acquire its static IP address `10.0.20.2` while initializing the `10.0.20.1` VIP).*

### Step B: Bootstrap etcd on Node 1
Wait approximately 30-40 seconds for the node to reboot and become reachable at `10.0.20.2`, then trigger etcd bootstrap:

```bash
talosctl bootstrap --nodes 10.0.20.2 --endpoints 10.0.20.2 --talosconfig ./clusterconfig/talosconfig
```

You can monitor cluster health and initialization status using:
```bash
talosctl --nodes 10.0.20.2 --endpoints 10.0.20.2 --talosconfig ./clusterconfig/talosconfig health
```

### Step C: Join Additional Control Plane Nodes (`ser-msa2cp2` and `ser-msa2cp3`)
Boot the remaining two machines with the Talos USB installer. Apply their respective manifests to whatever temporary DHCP IP is displayed on each monitor:

```bash
# For ser-msa2cp2 (replace <DHCP_IP_NODE2> with the actual temporary IP shown on screen)
talosctl apply-config --insecure --nodes <DHCP_IP_NODE2> --file clusterconfig/homme-cluster-ser-msa2cp2.yaml

# For ser-msa2cp3 (replace <DHCP_IP_NODE3> with the actual temporary IP shown on screen)
talosctl apply-config --insecure --nodes <DHCP_IP_NODE3> --file clusterconfig/homme-cluster-ser-msa2cp3.yaml
```

Once rebooted, both nodes will assume their static IPs (`10.0.20.3` and `10.0.20.4`), join the etcd quorum, and establish a fully resilient 3-node HA control plane under the shared VIP `https://10.0.20.1:6443`.

---

## 4. Accessing Kubernetes (`kubectl`)

To retrieve your admin `kubeconfig` and interact with the cluster:
```bash
talosctl kubeconfig --nodes 10.0.20.2 --endpoints 10.0.20.2 --talosconfig ./clusterconfig/talosconfig ./kubeconfig
export KUBECONFIG=./kubeconfig
kubectl get nodes -o wide
```
