# Talos Upgrade Runbook

Operational procedure used to upgrade the `homme-cluster` Talos nodes. The
cluster runs three control-plane nodes (`ser-msa2cp1..3`) and one worker
(`ser-n100wk1`); the upgrade is always performed one node at a time.

## Scope and supported path

- Upgrade the OS only. `kubernetesVersion` stays pinned in
  `talos/talconfig.yaml`; a Talos upgrade never changes Kubernetes.
- Always upgrade to the latest patch of every intermediate minor first, then
  jump to the next minor. Current path:

  `v1.13.6 -> v1.13.12 -> v1.14.5`

- Talos 1.14 removed the `ghcr.io/siderolabs/installer` image. Installer images
  come from Image Factory and must carry each node's schematic:

  | Node | Schematic |
  | --- | --- |
  | `ser-msa2cp1` | `c4333c1262d1ffeacc6edcc4f6f14c674fd4036b4c208aa2265e6605bf07e886` (amd-ucode, amdgpu, iscsi-tools, util-linux-tools, nvidia) |
  | `ser-msa2cp2` | `65cf8364cd0de4cf7b851dc7067a2db83d0ba04f11d8635c6cd3334be6ffb825` |
  | `ser-msa2cp3` | `65cf8364cd0de4cf7b851dc7067a2db83d0ba04f11d8635c6cd3334be6ffb825` |
  | `ser-n100wk1` | `84b8638071e89478ad993bbd628e03311daba9a0284427e8d135268fbc959700` (intel-ucode, i915, util-linux-tools) |

  Use the node's own schematic. Upgrading with the default installer image (the
  empty schematic) drops all system extensions, including the NVIDIA driver and
  the Coral/VA-API support.

## Tooling

Run everything from the dev shell. The flake pins `talosctl`/`talhelper`; verify
the client version before starting. Talos recommends a `talosctl` matching the
running cluster version.

```bash
nix flake update          # bring talosctl to the target release when nixpkgs is stale
nix develop --command talosctl version --client
nix develop --command talhelper --version
```

Talhelper prints a "might not be compatible" warning for a patch release newer
than its embedded version map. Check that the minor is supported
(`v1.14`) and that the generated configs validate; the warning is then benign.

## Pre-flight

1. Cluster health. `talosctl health` with no arguments fails with
   `command "health" is not supported with multiple nodes` because the context
   lists all four nodes. Pass one node plus the role lists:

   ```bash
   export TALOSCONFIG=talos/clusterconfig/talosconfig
   talosctl health --nodes 10.0.20.2 \
     --control-plane-nodes 10.0.20.2,10.0.20.3,10.0.20.4 \
     --worker-nodes 10.0.20.5 --wait-timeout 2m
   ```

2. etcd snapshot. Create a dedicated job with a **unique name** (an earlier
   `etcd-backup-preupgrade` job from a previous upgrade still exists and blocks
   reuse of the name):

   ```bash
   export KUBECONFIG=talos/clusterconfig/kubeconfig
   kubectl -n backup create job etcd-backup-preupgrade-<version> --from=cronjob/etcd-backup
   kubectl -n backup wait --for=condition=complete job/etcd-backup-preupgrade-<version> --timeout=5m
   kubectl -n backup logs job/etcd-backup-preupgrade-<version> --tail=5   # snapshot must appear on the NFS share
   ```

3. Baseline checks: all nodes `Ready`, `flux get kustomizations -A` green, all
   `volumes.longhorn.io` `attached/healthy`, CNPG `Cluster` healthy, Gateways
   `PROGRAMMED`, all `HTTPRoute`s `Accepted`.

4. Configuration. Regenerate and validate before touching nodes. The generated
   `talos/clusterconfig/` is gitignored and not applied by `talosctl upgrade`.

   ```bash
   talhelper genconfig
   talosctl validate --config talos/clusterconfig/homme-cluster-ser-msa2cp1.yaml --mode metal
   # repeat for the other three configs
   ```

   Talos 1.14 expresses CNI and kube-proxy in the multi-document model:
   `cniConfig: name: none` renders no `KubeFlannelCNIConfig` document (absence
   disables Flannel), and `talos/patches/global/kube-proxy-disabled.yaml` sets
   `KubeProxyConfig.enabled: false`.

5. Verify the installer exists for every schematic at the target version:

   ```bash
   for id in c4333c12... 65cf8364... 84b86380...; do
     docker manifest inspect "factory.talos.dev/metal-installer/$id:v1.14.5" >/dev/null
   done
   ```

## Upgrade procedure

Order: worker first, then control planes one at a time. Talos refuses a control
plane upgrade that would break etcd quorum, but do not parallelize.

### Drain gotcha: Longhorn instance-manager PDBs

A normal `talosctl upgrade` (drain enabled) gets stuck on control-plane nodes:
the drain loops forever evicting the same Longhorn `instance-manager-*` pods
because their PodDisruptionBudgets have `minAvailable: 1` and
`ALLOWED DISRUPTIONS: 0`, and each pod is pinned to its node. The drain times out
and the upgrade aborts **after** the new image has been written to the inactive
partition; the node is left cordoned but still on the old version.

Use `--drain=false` for the control-plane nodes (and for the worker if its
Longhorn pods cause the same loop). Talos still stops all pods during shutdown;
the only difference is that Kubernetes does not pre-evict them. Longhorn volumes
that have a replica on the rebooting node go `degraded`/`faulted` while it is
down and rebuild after it returns.

If an upgrade aborts in drain: `kubectl uncordon <node>`, confirm it is healthy,
and re-run the upgrade with `--drain=false`.

```bash
WORKER_IMAGE=factory.talos.dev/metal-installer/84b8638071e89478ad993bbd628e03311daba9a0284427e8d135268fbc959700:v1.14.5
CP1_IMAGE=factory.talos.dev/metal-installer/c4333c1262d1ffeacc6edcc4f6f14c674fd4036b4c208aa2265e6605bf07e886:v1.14.5
CP23_IMAGE=factory.talos.dev/metal-installer/65cf8364cd0de4cf7b851dc7067a2db83d0ba04f11d8635c6cd3334be6ffb825:v1.14.5

talosctl upgrade --nodes 10.0.20.5 --image "$WORKER_IMAGE" --wait --timeout 30m
talosctl upgrade --nodes 10.0.20.2 --image "$CP1_IMAGE"  --drain=false --wait --timeout 30m
talosctl upgrade --nodes 10.0.20.3 --image "$CP23_IMAGE" --drain=false --wait --timeout 30m
talosctl upgrade --nodes 10.0.20.4 --image "$CP23_IMAGE" --drain=false --wait --timeout 30m
```

Between nodes:

```bash
talosctl health --nodes <a control-plane IP> \
  --control-plane-nodes 10.0.20.2,10.0.20.3,10.0.20.4 \
  --worker-nodes 10.0.20.5 --wait-timeout 5m
kubectl get nodes -o wide
kubectl -n longhorn-system get volumes.longhorn.io --no-headers \
  | awk '$3 != "attached" || $4 != "healthy"'
```

Do not start the next node until Longhorn has no `degraded`/`faulted` volumes.

## Post-upgrade verification

```bash
talosctl version --nodes 10.0.20.2,10.0.20.3,10.0.20.4,10.0.20.5   # server v1.14.5
talosctl etcd members --nodes 10.0.20.2                            # 3 members, no learner
kubectl get nodes -o wide                                          # all Ready, K8s v1.36.0
flux --kubeconfig=talos/clusterconfig/kubeconfig get kustomizations -A
kubectl -n longhorn-system get volumes.longhorn.io --no-headers    # all attached/healthy
kubectl get clusters.postgresql.cnpg.io -A                         # healthy
kubectl -n kube-system get pods -l k8s-app=kube-proxy              # must be empty (Cilium replacement)
kubectl -n kube-system get ds cilium                               # 4/4
kubectl get node ser-msa2cp1 -o json | jq '.status.capacity["nvidia.com/gpu"]'
kubectl -n frigate logs deploy/frigate --tail=-1 | grep -i "TPU found"   # two Coral TPUs
talosctl -n 10.0.20.2 get kernelmodulestatus | grep -E "nvme_tcp|vfio_pci"
talosctl -n <node> get extensions                                  # schematic unchanged
```

Frigate runs on `ser-n100wk1`; after its reboot confirm the pod is `Running`,
the pod is still pinned by the `dedicated=nvr:NoSchedule` taint/label and
Longhorn still ignores the node, and that the model cache under
`/var/lib/frigate/model_cache/` survived.

## Rollback

The Talos A/B image scheme keeps the previous kernel and OS. If a node comes up
broken, or upgrades successfully but workloads cannot run on it:

```bash
talosctl rollback --nodes <ip>
```

A rollback reboots the node into the previous image; it is not a git revert.

## Talos 1.14 notes intentionally not enabled

- `sandboxd`/`workloadIsolation` is enabled only for clusters generated with
  1.14; upgraded clusters keep it disabled. Do not enable it without testing the
  iSCSI path used by Longhorn (`iscsi-tools`).
- `FilesystemTrimConfig`/`FilesystemScrubConfig` are in the generated 1.14
  config but are not applied by an upgrade, so trim/scrub stay disabled.
- etcd 3.7 moved metrics to `:2383`; etcd is not scraped today, so no
  `ServiceMonitor` change was needed.
- The v1alpha1 config is deprecated but still supported. Only the fields
  talhelper rejects on 1.14 (`.cluster.network.cni`, `.cluster.proxy`) were
  moved to documents (`cniConfig` and `KubeProxyConfig`); the remaining
  migration (KubeNodeConfig, SysctlConfig, KernelModuleConfig,
  KubePrismConfig, ImageCacheConfig, ...) is a separate change.

## Run log

### 2026-10-31 — v1.13.6 -> v1.13.12 -> v1.14.5

- `bcd1bd0` pinned `v1.13.12` (latest 1.13 patch) and rolled all four nodes.
- `7018ca9` pinned `v1.14.5`, moved CNI/kube-proxy to the 1.14 config model,
  and bumped the etcd-backup CronJob's `talosctl` to `v1.14.5` (sha256
  `ff432b68986709e6b69c563a08a2ced4232d5196b0dccd6d2e783e9d714d7d7d`).
- Pre-flight snapshot: `etcd-backup-preupgrade-1145` -> `etcd-snapshot-2026-10-31-0359.db`.
- Rollout order: `ser-n100wk1`, `ser-msa2cp1`, `ser-msa2cp2`, `ser-msa2cp3`.
  The worker drained normally; the three control planes used `--drain=false`
  because of the Longhorn instance-manager PDB loop. The first cp1 attempt
  aborted in drain (image staged, node uncordoned), then succeeded on retry.
- All nodes ended on `v1.14.5`, kernel `6.18.58-talos`, containerd `2.3.7`;
  Kubernetes stayed on `v1.36.0`.
- Longhorn returned to 35/35 `attached/healthy` after each node rebuilt its
  replicas; CNPG performed a switchover and stayed healthy.
