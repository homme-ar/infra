# Kubernetes Upgrade Runbook

Operational procedure used to upgrade Kubernetes on `homme-cluster`. Talos OS
upgrades are a separate procedure (see `docs/TALOS-UPGRADE.md`); this runbook
changes Kubernetes components only.

## Scope and supported path

- Talos performs the upgrade with `talosctl upgrade-k8s`. It rolls
  `kube-apiserver`, `kube-controller-manager` and `kube-scheduler` across the
  control-plane nodes, then the kubelet on every node, then the Talos bootstrap
  manifests (CoreDNS).
- Talos OS and etcd are not touched. Talos must declare compatibility with the
  target Kubernetes version (`talosctl upgrade-k8s --dry-run` reports it).
- `kubernetesVersion` in `talos/talconfig.yaml` is the source of truth and must
  be bumped so `talhelper genconfig` reproduces the running state.
- Upgrade one minor at a time; patch releases within a supported minor can be
  applied directly. Current path: `v1.36.0 -> v1.37.1` (Talos `v1.14.5`
  supports Kubernetes `v1.37.1`).

## Pre-flight

1. Dry-run and compatibility check. The dry-run also detects removed component
   flags, removed API versions still in use, and bootstrap manifest drift:

   ```bash
   export TALOSCONFIG=talos/clusterconfig/talosconfig
   talosctl upgrade-k8s -n 10.0.20.2 --to v1.37.1 --dry-run
   ```

   Require `Talos version v1.14.5 is compatible with Kubernetes version
   v1.37.1` for every node, no warnings from the removed-flags/removed-APIs
   checks, and review every manifest diff.

2. etcd snapshot. Reuse the backup CronJob under a unique name:

   ```bash
   export KUBECONFIG=talos/clusterconfig/kubeconfig
   kubectl -n backup create job etcd-backup-preupgrade-<version> --from=cronjob/etcd-backup
   kubectl -n backup wait --for=condition=complete job/etcd-backup-preupgrade-<version> --timeout=5m
   kubectl -n backup logs job/etcd-backup-preupgrade-<version> --tail=6
   ```

3. Baseline checks: all nodes `Ready`, `flux get kustomizations -A` green, all
   `volumes.longhorn.io` `attached/healthy`, CNPG `Cluster` healthy, Gateway
   `PROGRAMMED`, all `HTTPRoute`s `Accepted`, no unavailable `APIService`s.

4. Pin and validate the configuration. Edit `kubernetesVersion`, regenerate,
   and validate the machine configs:

   ```bash
   cd talos && talhelper genconfig
   talosctl validate --config clusterconfig/homme-cluster-ser-msa2cp1.yaml --mode metal
   # repeat for the other three configs
   ```

5. Confirm the target images exist (kube-apiserver, kube-controller-manager,
   kube-scheduler, `ghcr.io/siderolabs/kubelet:<version>`, CoreDNS).

## Upgrade procedure

```bash
export TALOSCONFIG=talos/clusterconfig/talosconfig
talosctl upgrade-k8s -n 10.0.20.2 --to v1.37.1 \
  --with-docs=false --with-examples=false
```

- `--with-docs=false --with-examples=false` keeps the patched live machine
  config aligned with the lean configs generated from `talconfig.yaml`.
- No node drain is involved: control-plane components and kubelets restart in
  place, one node at a time. Longhorn rebuilds replicas and CNPG may perform a
  switchover; both recover automatically.
- If the command is interrupted, re-run it. The operation is convergent and
  reports each component that is already current.
- Existing live `etcd` is reused; the upgrade does not rotate etcd.

## Post-upgrade verification

```bash
export KUBECONFIG=talos/clusterconfig/kubeconfig
kubectl get nodes -o wide                       # all Ready, v1.37.1
kubectl version                                 # Server Version v1.37.1
talosctl version --nodes 10.0.20.2,10.0.20.3,10.0.20.4,10.0.20.5
talosctl -n 10.0.20.2 etcd members              # 3 members, no learner
flux --kubeconfig=talos/clusterconfig/kubeconfig get kustomizations -A
kubectl get hr -A                               # all Ready
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl -n longhorn-system get volumes.longhorn.io   # 35/35 attached/healthy
kubectl get clusters.postgresql.cnpg.io -A           # healthy
kubectl -n kube-system get ds cilium                 # 4/4
kubectl -n kube-system get deploy coredns            # image coredns:v1.14.7
kubectl -n kube-system get gateway envoy-gateway     # PROGRAMMED True
kubectl get apiservices | awk '$3 != "True"'         # must be empty
kubectl get node ser-msa2cp1 -o json | jq '.status.capacity["nvidia.com/gpu"]'
kubectl -n frigate logs deploy/frigate --tail=-1 | grep -i "TPU found"
```

End-to-end check through the Gateway (TLS verified, no `-k`):

```bash
DOMAIN=$(kubectl -n flux-system get configmap cluster-vars-private -o jsonpath='{.data.CLUSTER_DOMAIN}')
GW=$(kubectl -n kube-system get gateway envoy-gateway -o jsonpath='{.status.addresses[0].value}')
curl -s -o /dev/null -w '%{http_code}\n' --resolve "status.$DOMAIN:443:$GW" "https://status.$DOMAIN/"
```

Finally, take a post-upgrade etcd snapshot with the same CronJob pattern
(`etcd-backup-postupgrade-<version>`).

## Rollback

`talosctl upgrade-k8s` does not support downgrades. If the cluster cannot be
recovered:

1. Restore the pre-upgrade etcd snapshot (see `docs/BACKUPS.md`).
2. Revert `kubernetesVersion` in `talos/talconfig.yaml`, run
   `talhelper genconfig`, and re-apply the machine configs to the nodes.
3. Talos OS itself can be rolled back with `talosctl rollback --nodes <ip>`.

## Component compatibility notes (Kubernetes 1.37)

Checked on 2026-10-31 against the latest component releases:

- **Flux v2.10.0** — explicitly supports Kubernetes 1.35, 1.36 and 1.37.
- **Cilium 1.20.4** — e2e-tested through 1.36; Cilium 1.21 (the first release
  listing 1.37) is not released yet. A reported Cilium 1.20.1 install on 1.37
  ran normally (upstream issue #48694), and Cilium status is `OK` here.
- **Longhorn 1.13.0** — requires Kubernetes >= 1.34 and is tested through 1.36;
  no upper bound is documented.
- **cert-manager 1.21.3** — tested through 1.36; 1.37 dependency/e2e support is
  already merged for the next release.
- **CloudNativePG 1.30.1** — lists 1.37 as "tested, but not supported".
- **Gateway API 1.5.1**, metrics-server 0.9.0, kube-prometheus-stack 92.x — no
  1.37-specific blockers.

Kubernetes 1.37 specifics reviewed for this cluster:

- `scheduling.k8s.io/v1alpha2` is removed — no such objects existed.
- `PreventStaticPodAPIReferences` is locked on — Talos static pods only use a
  `downwardAPI` fieldRef (`POD_IP`), no Secret/ConfigMap/ServiceAccount refs.
- `SELinuxMount` is GA — Talos does not use SELinux.
- Deprecated cAdvisor flags were removed and some cAdvisor series
  (`container_cpu_load_average_10s`, `container_tasks_state`) are gone — none
  are configured or referenced by the Prometheus rules in this repo.
- `metrics.k8s.io` was promoted to `v1` (v1beta1 still served); metrics-server
  0.9.0 keeps working and the cluster has no HPAs.

## Run log

### 2026-10-31 — v1.36.0 -> v1.37.1

- Dry-run: Talos `v1.14.5` compatible on all four nodes; no removed flags or
  API versions; only the expected CoreDNS manifest change.
- Pre-flight snapshot: `etcd-backup-preupgrade-1371` ->
  `etcd-snapshot-2026-10-31-0538.db`.
- `talosctl upgrade-k8s` rolled kube-apiserver, kube-controller-manager and
  kube-scheduler on `ser-msa2cp1..3`, then kubelet on all four nodes. CoreDNS
  moved from `v1.14.2` to `v1.14.7` (with an explicit OS/arch nodeAffinity).
- Post-upgrade: all nodes `v1.37.1`; etcd `v3.7.3` with 3 healthy members;
  Flux/HelmReleases Ready; 35/35 Longhorn volumes `attached/healthy`; CNPG
  `postgres` 2/2; Gateway programmed and every HTTPRoute `Accepted`; verified
  TLS routes (302 for Authelia-protected apps, 200 for public ones); GPU
  allocatable `10`; Frigate running with both Coral TPUs detected.
- Post-upgrade snapshot: `etcd-backup-postupgrade-1371` ->
  `etcd-snapshot-2026-10-31-0558.db`.
