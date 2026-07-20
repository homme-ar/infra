# Home Assistant Migration Runbook

Migrates Home Assistant from the legacy Pulumi-managed cluster
(`homme-ar/infraestructura`) to the new Talos / Flux cluster in this
repo.

## Goals

- Zero loss of `/config` (integrations, YAML, HACS custom_components,
  blueprints, secrets, `.storage/` — everything HA persists to disk).
- **Near-zero recorder data loss** via PostgreSQL logical replication.
- Minimum downtime for the household automations (target: < 15 min).

## Source vs destination

| Aspect               | Legacy (source)                                                             | New cluster (destination)                                                                       |
|----------------------|-----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| Manifest tooling     | Pulumi (`infraestructura/core/home-assistant`)                              | Flux + Kustomize (`cluster/apps/iot/home-assistant/`)                                           |
| HA image             | `homeassistant/home-assistant:2026.6.1`                                     | Same tag, pinned identically to isolate the infra move from an app upgrade                      |
| Config volume        | NFS `nfs://192.0.2.20/k8s/home-assistant-config-pvc-fb7de188-…` (50 Gi)        | Longhorn RWO PVC `home-assistant-config` (30 Gi, expandable)                                    |
| Ingress              | Ingress on `ha.example.com`                                                    | Gateway API `HTTPRoute` on `ha.${CLUSTER_DOMAIN}` behind `envoy-gateway`                        |
| PostgreSQL           | Bitnami chart 18.7.2, PG **18.4**, LB `192.0.2.102`, DB `home-assistant`, user `home-assistant` | Shared CNPG PG18 cluster in `postgres` namespace, DB `homeassistant`, role `homeassistant`      |
| Reachable at         | `postgresql://home-assistant:***@192.0.2.102:5432/home-assistant`             | `postgresql://homeassistant:***@postgres-rw.postgres.svc.cluster.local:5432/homeassistant`      |

The recorder DB is **~5.6 Gi**, not 150 Gi as originally estimated. The
migration uses native logical replication anyway (both sides run PG18)
because it keeps the cutover window under a minute and is idempotent.

## Prerequisites

- `direnv` loaded (Nix shell → `kubectl`, `talosctl`, `flux`, `sops`).
- Kubeconfig at `talos/clusterconfig/kubeconfig` (see `AGENTS.md`).
- Legacy PG super-user + `home-assistant` app passwords available (from
  `pulumi config get --show-secrets` in `infraestructura/core/postgresql`
  and `infraestructura/core/home-assistant`).
- Legacy PG has `wal_level=logical`. Verify with:
  `psql -h 192.0.2.102 -U postgres -c 'SHOW wal_level;'`
  (already applied preventively before starting Phase 0).
- SOPS Age key at `$SOPS_AGE_KEY_FILE` for the destination secrets.

## Environment variables

```bash
export KUBECONFIG="$PWD/talos/clusterconfig/kubeconfig"

# Legacy PG (source)
export SRC_HOST=192.0.2.102
export SRC_PORT=5432
export SRC_DB=home-assistant
export SRC_APP_USER=home-assistant
export SRC_SUPER_USER=postgres
export SRC_SUPER_PASSWORD='...'     # from pulumi
export SRC_APP_PASSWORD='...'       # from pulumi

# Destination (shared CNPG PG18, same cluster as Authelia)
export DST_HOST=postgres-rw.postgres.svc.cluster.local
export DST_PORT=5432
export DST_DB=homeassistant
export DST_APP_USER=homeassistant
export DST_SUPER_USER=postgres
# The homeassistant role password is auto-managed by CNPG from the SOPS
# secret home-assistant-postgres-secret in the `postgres` namespace.
# Retrieve with:
export DST_APP_PASSWORD=$(kubectl -n postgres get secret home-assistant-postgres-secret \
    -o jsonpath='{.data.password}' | base64 -d)
# Superuser password lives in postgres-superuser-secret (same namespace):
export DST_SUPER_PASSWORD=$(kubectl -n postgres get secret postgres-superuser-secret \
    -o jsonpath='{.data.password}' | base64 -d)
```

---

## Phase 0 — Deploy the empty destination

1. Commit and push the manifests under `cluster/apps/iot/home-assistant/`
   plus the shared-cluster additions
   (`cluster/apps/platform/postgres/home-assistant-database.yaml`,
   `home-assistant-secret.yaml`, `cluster.yaml`, `kustomization.yaml`).
2. Trigger reconciliation:

   ```bash
   flux -n flux-system reconcile source git flux-system
   flux -n flux-system reconcile kustomization cluster-apps
   ```

3. Verify the DB pieces landed inside the shared cluster:

   ```bash
   # Role
   kubectl -n postgres exec postgres-1 -c postgres -- \
     psql -U postgres -tAc "SELECT rolname, rolreplication FROM pg_roles WHERE rolname='homeassistant';"
   # expect: homeassistant|t

   # Database
   kubectl -n postgres exec postgres-1 -c postgres -- \
     psql -U postgres -tAc "SELECT datname, pg_get_userbyid(datdba) FROM pg_database WHERE datname='homeassistant';"
   # expect: homeassistant|homeassistant
   ```

4. Verify the HA namespace pieces:

   ```bash
   kubectl -n home-assistant get pods,pvc,svc,httproute
   ```

   - `home-assistant-config` PVC should be `Bound` on `longhorn`.
   - The `home-assistant` Deployment ships committed with
     `replicas: 0` so nothing tries to attach the PVC yet.

---

## Phase 1 — Copy the `/config` directory (hot, safe)

`/config` is the HA state directory: integrations, YAML, `.storage/`,
HACS custom_components, Python `deps/`. The recorder DB is separate, so
rsyncing `/config` while HA is running is safe as long as we do a final
delta pass during the cutover.

### 1.1 Initial rsync from legacy NFS to Longhorn PVC

Run a one-shot Job in the new cluster that mounts:
- the legacy NFS export directly (`nfs://192.0.2.20/…`), and
- the new Longhorn PVC `home-assistant-config`.

```yaml
# /tmp/ha-rsync-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: ha-config-rsync
  namespace: home-assistant
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: rsync
          image: instrumentisto/rsync-ssh:latest
          command:
            - sh
            - -c
            - |
              rsync -aHAX --numeric-ids --delete --info=progress2 \
                /src/ /dst/
          volumeMounts:
            - { name: src, mountPath: /src }
            - { name: dst, mountPath: /dst }
      volumes:
        - name: src
          nfs:
            server: 192.0.2.20
            path: /k8s/home-assistant-config-pvc-fb7de188-f14f-4b3c-95f5-3e5b943ce775
            readOnly: true
        - name: dst
          persistentVolumeClaim:
            claimName: home-assistant-config
```

Apply and follow:

```bash
kubectl apply -f /tmp/ha-rsync-job.yaml
kubectl -n home-assistant logs -f job/ha-config-rsync
kubectl -n home-assistant delete job ha-config-rsync
```

`--delete` mirrors the source. Re-running the same Job at cutover time
is idempotent and only transfers the delta.

### 1.2 Pin the recorder DB URL in configuration.yaml

Open a debug pod that mounts the freshly-rsynced PVC and edit
`/config/configuration.yaml` so the recorder reads the new env var:

```yaml
recorder:
  db_url: !env_var RECORDER_DB_URL
  # Optional: purge older raw rows, keep summaries.
  purge_keep_days: 30
  commit_interval: 5
```

The env var is already wired into the Deployment via the SOPS-encrypted
`home-assistant-recorder-secret`. HA will NOT start yet — Phase 2
populates the DB first.

---

## Phase 2 — Bootstrap logical replication

### 2.1 On the LEGACY PostgreSQL

Connect as super-user from any pod that can reach `192.0.2.102:5432`
(easiest: `kubectl -n postgres exec -i postgres-1 -c postgres -- psql
"host=$SRC_HOST port=$SRC_PORT user=$SRC_SUPER_USER dbname=$SRC_DB"`
with `PGPASSWORD` set).

```sql
-- Sanity checks
SHOW wal_level;               -- must be 'logical'
SHOW max_replication_slots;   -- >= 4 is fine
SHOW max_wal_senders;         -- >= 4 is fine

-- Every HA recorder table has a PK (id column) so REPLICA IDENTITY
-- DEFAULT is sufficient.
CREATE PUBLICATION ha_migration FOR ALL TABLES;

SELECT pubname, puballtables FROM pg_publication;
```

### 2.2 On the DESTINATION (shared CNPG PG18)

Dump the source schema and restore into the destination DB before the
subscription is created (logical replication does not run DDL):

```bash
# Schema-only dump. Streamed via kubectl exec to avoid needing a local
# psql client (Nix shell has none by default).
kubectl -n postgres exec -i postgres-1 -c postgres -- \
  sh -c "PGPASSWORD='$SRC_APP_PASSWORD' pg_dump \
    -h $SRC_HOST -p $SRC_PORT -U $SRC_APP_USER -d $SRC_DB \
    --schema-only --no-owner --no-privileges" \
  > /tmp/opencode/ha-schema.sql

# Restore into the destination as superuser (uses role=homeassistant so
# every object ends up owned by the app user).
kubectl -n postgres exec -i postgres-1 -c postgres -- \
  psql -U postgres -d homeassistant -v ON_ERROR_STOP=1 --single-transaction \
  < /tmp/opencode/ha-schema.sql
```

Create the subscription (starts initial COPY of ~5.6 Gi immediately):

```bash
kubectl -n postgres exec postgres-1 -c postgres -- \
  psql -U postgres -d homeassistant -c "
    CREATE SUBSCRIPTION ha_migration
      CONNECTION 'host=$SRC_HOST port=$SRC_PORT dbname=$SRC_DB
                  user=$SRC_APP_USER password=$SRC_APP_PASSWORD'
      PUBLICATION ha_migration
      WITH (copy_data = true, create_slot = true, slot_name = 'ha_migration',
            streaming = true, binary = true);"
```

During initial COPY the legacy HA keeps writing to `192.0.2.102` and every
change is queued in the replication slot for streaming after the COPY.

### 2.3 Monitor progress

Source (legacy) — WAL retention on the slot:

```sql
SELECT slot_name, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(),
                                      confirmed_flush_lsn)) AS lag
FROM pg_replication_slots WHERE slot_name = 'ha_migration';
```

Destination — per-table copy state (`i`=init, `d`=data copy, `s`=sync,
`r`=streaming):

```sql
SELECT srsubstate, count(*) AS tables
FROM pg_subscription_rel GROUP BY srsubstate;
```

Fully caught up when every row shows `srsubstate = 'r'` AND the slot
lag is ~0 bytes.

---

## Phase 3 — Cutover (< 15 min downtime)

### 3.1 Stop the legacy Home Assistant

```bash
# On the legacy cluster
kubectl --context=<legacy-ctx> -n home-assistant scale deploy/home-assistant --replicas=0
kubectl --context=<legacy-ctx> -n home-assistant scale deploy/home-assistant-code --replicas=0
```

Record the wall-clock time — any automation firing after this instant
before HA comes up on the new cluster is lost.

### 3.2 Drain the subscription

Wait until:
- Every `pg_subscription_rel.srsubstate = 'r'` on the destination.
- The source slot's `remaining` bytes is `0`.

```sql
-- Source
SELECT slot_name, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(),
                                      confirmed_flush_lsn)) AS remaining
FROM pg_replication_slots WHERE slot_name = 'ha_migration';

-- Destination
SELECT application_name, state,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag
FROM pg_stat_replication WHERE application_name = 'ha_migration';
```

### 3.3 Final rsync of `/config`

```bash
kubectl apply -f /tmp/ha-rsync-job.yaml
kubectl -n home-assistant logs -f job/ha-config-rsync
kubectl -n home-assistant delete job ha-config-rsync
```

Second pass transfers only the delta since Phase 1 (usually a few MB).

### 3.4 Fix sequences and drop the subscription

Logical replication does not advance sequences. Recompute them:

```sql
-- On the DESTINATION
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT n.nspname AS schema, c.relname AS table,
           a.attname AS column, pg_get_serial_sequence(
             format('%I.%I', n.nspname, c.relname), a.attname) AS seq
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid
    WHERE c.relkind = 'r' AND n.nspname = 'public'
      AND pg_get_serial_sequence(
            format('%I.%I', n.nspname, c.relname), a.attname) IS NOT NULL
  LOOP
    EXECUTE format(
      'SELECT setval(%L, COALESCE((SELECT MAX(%I) FROM %I.%I), 1))',
      r.seq, r.column, r.schema, r.table);
  END LOOP;
END $$;

-- Then cancel replication
ALTER SUBSCRIPTION ha_migration DISABLE;
ALTER SUBSCRIPTION ha_migration SET (slot_name = NONE);
DROP SUBSCRIPTION ha_migration;
```

Clean up the source:

```sql
SELECT pg_drop_replication_slot('ha_migration');
DROP PUBLICATION ha_migration;
```

### 3.5 Start Home Assistant on the new cluster

```bash
kubectl -n home-assistant scale deploy/home-assistant --replicas=1
kubectl -n home-assistant rollout status deploy/home-assistant --timeout=300s
kubectl -n home-assistant logs -f deploy/home-assistant
```

HA runs its recorder migration checks and starts on the pre-populated
schema. Expected startup: 1–3 min with many integrations.

### 3.6 Validate

- Open `https://ha.example.com` and check `Settings → System → Repairs`.
- Confirm no recorder errors in `Settings → System → Logs`.
- History graphs should extend back before the cutover moment.
- Trigger a couple of automations (light on/off, sensor read).
- Compare row counts on a heavy table:
  ```sql
  SELECT count(*) FROM states;
  SELECT count(*) FROM events;
  ```
  against the snapshot taken right before cutover.

---

## Phase 4 — Decommission

After **≥ 24 hours** of stable operation:

1. Destroy the Pulumi stack for HA on the legacy cluster.
2. Keep the legacy PostgreSQL running for a few more days as a warm
   fallback; drop the `home-assistant` DB and role once confident.
3. Leave `LEGACY_HA_IP: 192.0.2.105` in `cluster-vars.yaml` for now — some
   IoT device may still probe it. Remove when audit-ready.

---

## Rollback plan

If something fails after 3.5:

1. `kubectl -n home-assistant scale deploy/home-assistant --replicas=0`.
2. Scale the legacy HA back to `replicas=1`.
3. The legacy DB was never written after 3.1, so it resumes cleanly.
4. The destination PVC and DB stay intact for a second attempt.
   If necessary, drop and recreate the `homeassistant` DB via CNPG
   (`kubectl -n postgres delete database homeassistant`; Flux
   reconciles a fresh empty one on the next pass).
