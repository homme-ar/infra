# BACKUPS.md — Backup & Restore Runbook (`homme-cluster`)

This runbook documents the backup policy, where backups land, how to verify
them, and how to restore each class of workload.

## Overview

All backups land on the QNAP NAS (`192.0.2.20`) over NFS:

| Destination | What | Mechanism |
|---|---|---|
| `/backup/longhorn` | Longhorn volumes (app configs + observability) | Longhorn RecurringJobs |
| `/backup/versitygw/postgres` | PostgreSQL (CNPG) base backups + WAL | CNPG `barmanObjectStore` → Versity Gateway (S3) |
| `/backup/etcd` | etcd snapshots | CronJob `etcd-backup` (namespace `backup`) |

The **Versity Gateway** (`cluster/infrastructure/storage/versitygw`) exposes an
S3 API backed by the NFS share `/backup/versitygw` — CNPG cannot write backups
to NFS directly, so it talks S3 to the gateway. S3 buckets are plain
subdirectories of the share (posix backend); create new buckets by creating
directories on the QNAP.

## Backup matrix

| Workload | Storage | Backup | Retention |
|---|---|---|---|
| App configs (media stack, n8n, vaultwarden, home-assistant, esphome, mosquitto, ntfy-auth, waha-sessions) | SC `longhorn` | Longhorn RecurringJob → NFS | 7 daily + 4 weekly |
| `ntfy-cache`, `waha-media` | SC `longhorn` | **None** (regenerable) | — |
| Observability (prometheus TSDB, grafana, alertmanager) | SC `longhorn-singlenode` | Longhorn RecurringJob → NFS | 7 daily + 4 weekly |
| PostgreSQL (CNPG) | SC `longhorn-singlenode` | CNPG → S3 (versitygw) → NFS. Weekly base + continuous WAL | 30 days (PITR) |
| Media content (`nas-media` PVCs) | NFS direct (QNAP) | **None** (already on the NAS) | — |
| etcd | control-plane local disk | CronJob → NFS | 14 daily |

### Longhorn policy details

- Backup target and poll interval are set in
  `cluster/infrastructure/storage/longhorn/release.yaml`
  (`defaultSettings.backupTarget`, `backupstorePollInterval`).
- Jobs are defined in `cluster/infrastructure/storage/longhorn/recurring-jobs.yaml`
  (`backup-daily` 03:00 retain 7, `backup-weekly` Sun 04:00 retain 4), both in
  the group `backup`.
- **Opt-in per volume**: a PVC joins the backup jobs via the label
  `recurring-job-group.longhorn.io/backup: enabled`. Add it to every new
  app PVC that should be backed up. CNPG volumes never carry the label
  (the database has its own backup); neither do `ntfy-cache`/`waha-media`.
- Observability PVCs are Helm-managed: the label is set in the
  kube-prometheus-stack `volumeClaimTemplate` (applies to *new* claims) and
  was applied once manually to the existing claims:
  ```bash
  kubectl label pvc -n observability \
    prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 \
    kube-prometheus-stack-grafana \
    alertmanager-kube-prometheus-stack-alertmanager-db-alertmanager-kube-prometheus-stack-alertmanager-0 \
    recurring-job-group.longhorn.io/backup=enabled
  ```
  Re-run this if any of those PVCs is ever recreated (the grafana chart cannot
  set PVC labels via values).
- Note on Prometheus consistency: backups are crash-consistent. On restore,
  Prometheus replays its WAL; worst case ~2h of the most recent metrics are
  lost. The 15-day TSDB history inside the volume survives.

### One-time steps already performed on the live cluster

These were applied manually once (documented for cluster rebuilds):

1. **BackupTarget CR**: the `default` BackupTarget CR was created by
   longhorn-manager with an empty URL (`defaultSettings` from the Helm chart
   only apply on fresh installs, not upgrades). Fixed with:
   ```bash
   kubectl -n longhorn-system patch backuptarget default --type merge \
     -p '{"spec":{"backupTargetURL":"nfs://192.0.2.20:/backup/longhorn"}}'
   ```
   On a fresh install the Helm `defaultSettings.backupTarget` should take
   effect; verify `kubectl -n longhorn-system get backuptarget` shows
   `AVAILABLE=true` after any rebuild.
2. **Volume labels for existing volumes**: the PVC → volume label sync can
   lag for pre-existing volumes. All 19 in-scope volumes were labeled
   directly:
   ```bash
   kubectl get pvc -A -l recurring-job-group.longhorn.io/backup=enabled \
     -o jsonpath='{range .items[*]}{.spec.volumeName}{"\n"}{end}' | while read vol; do
     kubectl -n longhorn-system label volume "$vol" recurring-job-group.longhorn.io/backup=enabled --overwrite
   done
   ```
3. **V2 instance-manager convergence after the v1.12.1 upgrade** (2026-08-23):
   the chart upgrade alone did not replace the running v2 instance-managers
   (they are only swapped once they hold zero instances), so the #13331 fix
   stayed inactive and backups kept forcing ext4 read-only remounts. All
   workloads were bounced once to drain every volume; the v1.12.0 IMs were
   auto-deleted and replaced by v1.12.1. See the troubleshooting section below.

### CNPG policy details

- `cluster/apps/platform/postgres/cluster.yaml`: `spec.backup` points barman at
  `s3://postgres` via `http://versitygw.backup.svc.cluster.local:7070`, gzip
  compression for data + WAL, `retentionPolicy: "30d"`.
- `cluster/apps/platform/postgres/scheduledbackup.yaml`: weekly base backup
  (Sun 02:00, `target: primary`). Continuous WAL archiving gives PITR to any
  second inside the 30-day window.

### etcd policy details

- `cluster/infrastructure/etcd-backup/cronjob.yaml`: daily 01:00, snapshots
  `/backup/etcd/etcd-snapshot-<date>-<time>.db` from the first reachable
  control-plane node, prunes files older than 14 days.
- Credentials: `etcd-backup-talosconfig` (SOPS) holds a talosconfig restricted
  to the `os:etcd:backup` role (snapshot-only, TTL 10y). To regenerate:
  ```bash
  talosctl --talosconfig talos/clusterconfig/talosconfig -n 192.0.2.2 -e 192.0.2.2 \
    config new /tmp/etcd-backup-talosconfig --roles os:etcd:backup --crt-ttl 87600h
  # then update the secret and re-encrypt with sops
  ```
- Snapshots are deliberately NOT routed through versitygw: etcd backups must
  be restorable with zero cluster services running.

## Verification

```bash
export KUBECONFIG=talos/clusterconfig/kubeconfig

# Longhorn: jobs defined, backups landing in the backupstore
kubectl get recurringjobs -n longhorn-system
kubectl get backups -n longhorn-system
kubectl get backupvolumes -n longhorn-system
# (or the Longhorn UI: Setting → Backup Target must show Available)

# CNPG: WAL archiving + scheduled backups
kubectl get scheduledbackups -n postgres
kubectl get backups.postgresql.cnpg.io -n postgres
kubectl describe cluster postgres -n postgres | grep -A5 "Continuous Backup"

# etcd: last CronJob runs and produced files
kubectl get jobs -n backup
kubectl logs -n backup -l app.kubernetes.io/name=etcd-backup --tail=20
```

## Troubleshooting: read-only filesystems during backups (v2 data engine)

Symptom: after a backup window, app pods keep running but their Longhorn
mounts are dead — writes fail with `Read-only file system` / EIO and the
mount table shows `emergency_ro`. Root cause (Longhorn ≤ v1.12.0,
https://github.com/longhorn/longhorn/issues/13331): the temporary NVMe/TCP
snapshot path created for a backup could flap the volume's live frontend; the
kernel ext4 then aborts its journal and remounts read-only.

Detection:

```bash
# In each suspect pod (mount shows emergency_ro instead of plain rw):
kubectl -n <ns> exec <pod> -- sh -c 'grep longhorn /proc/mounts'
# On the nodes (journal aborts + RO remounts during the backup window):
talosctl -n <node-ip> dmesg | grep -E 'Remounting filesystem read-only|Aborting journal'
# Backup side effect: snapshots of already-RO volumes fail with
# "failed to suspend linear dm device ... Read-only file system"
kubectl -n longhorn-system logs ds/longhorn-manager --since=12h | grep -B2 'Read-only file system'
```

Recovery per workload (the stale dm device only clears on detach):

```bash
kubectl -n <ns> scale deploy <app> --replicas=0
# wait for the volume to detach:
kubectl -n longhorn-system get volume <pvc-...> -o jsonpath='{.status.state}'
kubectl -n <ns> scale deploy <app> --replicas=1
```

Prevention: after ANY Longhorn chart upgrade, confirm the running v2
instance-managers actually moved to the new version — they are only replaced
when drained to zero instances, so attached volumes keep the old IM (and its
bugs) alive indefinitely:

```bash
kubectl -n longhorn-system get instancemanagers.longhorn.io \
  -o custom-columns=NODE:.spec.nodeID,ENGINE:.spec.dataEngine,IMAGE:.spec.image,STATE:.status.currentState
# every v2 row must show the new image + running; the old one must be gone
```

If an old IM survives, bounce the remaining workloads holding volumes on that
node (scale to 0 → wait for detach → scale back) until it is replaced.

## Troubleshooting: CNPG "Not enough disk space" / WAL archiving silently broken

Symptom (seen 2026-09-07): CNPG primary in CrashLoopBackOff, Cluster phase
`Not enough disk space`, and **no failover** — that is by design: the
operator's `ensure_sufficient_disk_space` gate blocks the whole reconcile
loop until the PVC is enlarged (it also runs BEFORE the PVC-resize logic, so
bumping `spec.storage.size` alone deadlocks: patch the PVC request manually
to the same value, then the gate passes and the instance starts).

Chain to check, in order:

```bash
# 1. Is archiving broken? (failed_count growing, last_archived_time stale)
kubectl -n postgres exec postgres-1 -c postgres -- psql "host=/controller/run user=postgres dbname=postgres" \
  -Atc "select archived_count, failed_count, now() - last_archived_time from pg_stat_archiver;"
# 2. Is versitygw rejecting PUTs? (507 InsufficientStorage = /meta out of
#    inodes — versitygw writes ~3 sidecar files per object; check df -i, not df -h)
kubectl -n backup logs deploy/versitygw | grep PUT | tail
kubectl -n backup exec deploy/versitygw -- df -i /meta
# 3. pg_wal piling up on the primary = archiving failing (a replica that
#    streams fine does NOT prevent this; only successful archiving frees WAL)
```

Fix: enlarge `versitygw-meta` (ext4 resize adds inodes) + enlarge the CNPG
PVCs (see above). Once Postgres starts, the archiver drains the pg_wal
backlog on its own (~1 segment/s) and the disk empties at the next
checkpoints.

Related gotcha: CNPG `ScheduledBackup.spec.schedule` is a **6-field cron
with seconds** and the webhook rejects 5-field expressions. `0 2 * * * 0`
does NOT mean "Sundays 02:00" — it means "minute 2 of every hour on Sunday"
(24 backups per Sunday, which is what inflated the versitygw meta inode
count in the first place).

## Restore procedures

### Longhorn volume

1. In the Longhorn UI → Backup, pick the volume and the backup to restore.
2. Restore creates a **new** volume; detach the workload, then either swap the
   PVC to the restored volume or create a PVC from the backup:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: <app>-restored
     namespace: <ns>
   spec:
     storageClassName: longhorn
     dataSource:
       kind: PersistentVolume
       name: <restored-longhorn-volume-name>
     accessModes: ["ReadWriteOnce"]
     resources:
       requests:
         storage: <size>
   ```
3. Re-point the app's PVC (GitOps change) and reconcile.

### PostgreSQL (CNPG)

Create a **new** cluster bootstrapped from the object store (never restore
in-place over a live cluster). Example skeleton:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-restored
  namespace: postgres
spec:
  instances: 2
  bootstrap:
    recovery:
      source: postgres-backup
      recoveryTarget:
        targetTime: "2026-07-25 10:00:00.00000+00"   # omit for latest
  externalClusters:
    - name: postgres-backup
      barmanObjectStore:
        destinationPath: s3://postgres
        endpointURL: http://versitygw.backup.svc.cluster.local:7070
        s3Credentials:
          accessKeyId:
            name: postgres-backup-s3
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: postgres-backup-s3
            key: SECRET_ACCESS_KEY
        wal:
          compression: gzip
        data:
          compression: gzip
  storage:
    size: 150Gi
    storageClass: longhorn-singlenode
```

Then migrate the per-app `Database` objects / connection secrets to the
restored cluster and delete the broken one. See the CNPG "Recovery" docs for
the full matrix of `recoveryTarget` options (PITR by time, XID, LSN, name).

### etcd (Talos)

An etcd snapshot is the last-resort disaster recovery artifact (full cluster
loss or etcd quorum corruption). High level — follow the Talos "Disaster
Recovery" guide for the exact procedure of your Talos version:

1. Copy the desired `etcd-snapshot-*.db` from the NAS to your workstation.
2. On the cluster (or the surviving CP node):
   ```bash
   export TALOSCONFIG=talos/clusterconfig/talosconfig
   talosctl -n 192.0.2.2 etcd snapshot /tmp/snapshot-check.db   # sanity check current state
   # Stop kubelet/etcd on all CP nodes, then:
   talosctl -n <cp> etcd restore --nodes <cp> --file /path/to/etcd-snapshot-<ts>.db
   ```
3. Re-bootstrap following `docs/BOOTSTRAP.md` if the whole cluster is being
   rebuilt.

Note: restoring etcd brings back the Kubernetes API state; application data in
Longhorn volumes and PostgreSQL is NOT in etcd and must be restored via the
procedures above.
