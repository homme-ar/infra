# n8n Migration Runbook

Migrates n8n from the legacy Pulumi-managed cluster
(`homme-ar/infraestructura`, `apps/n8n`) to the new Talos / Flux cluster
in this repo.

## Goals

- Zero loss of `/home/node/.n8n` (workflows state, the credentials
  **encryption key** in `config`, binary data, settings).
- Zero database loss via `pg_dump` / `pg_restore` at cutover time
  (workflows, credentials, execution history).
- Short downtime (target: < 15 min). n8n is a batch/automation tool, so a
  brief stop is acceptable — no logical replication needed (unlike the
  Home Assistant recorder migration).

## Source vs destination

| Aspect           | Legacy (source)                                        | New cluster (destination)                                                        |
|------------------|--------------------------------------------------------|----------------------------------------------------------------------------------|
| Manifest tooling | Pulumi (`infraestructura/apps/n8n`)                    | Flux + Kustomize (`cluster/apps/platform/n8n/`)                                  |
| Image            | `n8nio/n8n:2.25.5`                                     | Same tag, pinned identically to isolate the infra move from an app upgrade       |
| Namespace        | `apps-n8n`                                             | `n8n`                                                                            |
| Data volume      | NFS `nfs://192.0.2.20/k8s/apps-n8n-data-pvc-…` (50 Gi)   | Longhorn RWO PVC `n8n-data` (20 Gi, expandable; actual usage is far below 50 Gi) |
| Ingress          | Ingress on `n8n-apps.example.com`                         | Gateway API `HTTPRoute` on `n8n-apps.${CLUSTER_DOMAIN}` behind `envoy-gateway`   |
| PostgreSQL       | Bitnami PG on `192.0.2.102:5432`, DB `n8n`, role `n8n`   | Shared CNPG PG18 cluster in `postgres` namespace, DB `n8n`, role `n8n`           |
| Reachable at     | `postgresql://n8n:***@192.0.2.102:5432/n8n`              | `postgresql://n8n:***@postgres-rw.postgres.svc.cluster.local:5432/n8n`           |

### How traffic cutover works

The new cluster's `legacy-fallback` HTTPRoute (`cluster/apps/legacy/proxy`)
forwards every unmatched hostname to the legacy cluster ingress
(`192.0.2.102`-style). Today `n8n-apps.example.com` resolves to the new gateway
and is proxied to the legacy n8n. The new `HTTPRoute` in
`cluster/apps/platform/n8n/httproute.yaml` matches the **same hostname
explicitly**, and Gateway API gives an exact-hostname match precedence over
the fallback wildcard. So as soon as Flux applies the route, traffic lands
on the new cluster — no DNS change required. Until the new Deployment is
scaled above 0 the route returns 5xx, which is why the cutover phases below
matter.

### About the credentials encryption key

The legacy deployment does **not** set `N8N_ENCRYPTION_KEY`; n8n generated a
random key on first boot and stored it in `/home/node/.n8n/config` on the
PVC. That key decrypts every stored credential. The rsync below copies the
whole directory, key included — so credentials keep working on the new pod.
(Decision: keep parity with the legacy setup; the key is **not** extracted
into a SOPS secret. Losing the PVC means losing credential decryptability,
same as before.)

## Prerequisites

- `direnv` loaded (Nix shell → `kubectl`, `flux`, `sops`).
- Kubeconfig at `talos/clusterconfig/kubeconfig` (see `AGENTS.md`).
- kubectl access to the **legacy** cluster (to scale the old n8n down).
- Legacy PG credentials: the `n8n` role password (from
  `pulumi config get n8n-postgresql-password --stack base` in
  `infraestructura/apps/n8n`). The same value is already committed,
  SOPS-encrypted, in both destination secrets.
- SOPS Age key at `$SOPS_AGE_KEY_FILE` for any secret edit.

## Environment variables

```bash
export KUBECONFIG="$PWD/talos/clusterconfig/kubeconfig"
export LEGACY_CTX=<legacy-kube-context>   # context for the old cluster

# Legacy PG (source)
export SRC_HOST=192.0.2.102
export SRC_PORT=5432
export SRC_DB=n8n
export SRC_APP_USER=n8n
export SRC_APP_PASSWORD='...'             # from pulumi (see above)

# Destination (shared CNPG PG18)
export DST_DB=n8n
# The n8n role password is auto-managed by CNPG from the SOPS-encrypted
# n8n-postgres-secret in the `postgres` namespace (same value as legacy).
# Superuser password lives in postgres-superuser-secret (same namespace):
export DST_SUPER_PASSWORD=$(kubectl -n postgres get secret postgres-superuser-secret \
    -o jsonpath='{.data.password}' | base64 -d)
```

---

## Phase 0 — Deploy the empty destination

Already committed: `cluster/apps/platform/n8n/` (namespace, PVC, SOPS
secret, Deployment with `replicas: 0`, Service, HTTPRoute) plus the
shared-cluster additions (`postgres/n8n-secret.yaml`,
`postgres/n8n-database.yaml`, the `n8n` managed role in
`postgres/cluster.yaml`, and both kustomization registrations).

1. Trigger reconciliation:

   ```bash
   flux -n flux-system reconcile source git flux-system
   flux -n flux-system reconcile kustomization cluster-apps
   ```

2. Verify the DB pieces landed inside the shared cluster:

   ```bash
   # Role
   kubectl -n postgres exec postgres-1 -c postgres -- \
     psql -U postgres -tAc "SELECT rolname, rolcanlogin FROM pg_roles WHERE rolname='n8n';"
   # expect: n8n|t

   # Database
   kubectl -n postgres exec postgres-1 -c postgres -- \
     psql -U postgres -tAc "SELECT datname, pg_get_userbyid(datdba) FROM pg_database WHERE datname='n8n';"
   # expect: n8n|n8n
   ```

3. Verify the namespace pieces:

   ```bash
   kubectl -n n8n get pods,pvc,svc,httproute
   ```

   - `n8n-data` PVC should be `Bound` on `longhorn`.
   - No pods: the Deployment ships with `replicas: 0` so the rsync Job can
     attach the PVC.

---

## Phase 1 — Copy the `/home/node/.n8n` directory (hot, safe)

`.n8n` holds the encryption key (`config`), user settings, and binary data.
Copying it while the legacy n8n runs is safe; a final delta pass happens at
cutover. n8n keeps workflow state in PostgreSQL (migrated in Phase 2), so
on-disk churn between passes is minimal.

### 1.1 Find the legacy NFS export path

The legacy NFS external-provisioner names exports
`<namespace>-<pvc-name>-pvc-<uid>`. Either query the legacy cluster:

```bash
kubectl --context="$LEGACY_CTX" -n apps-n8n get pvc data \
  -o jsonpath='{.spec.volumeName}{"\n"}'
```

or list the exports on the NFS server (`192.0.2.20:/k8s`) and look for
`apps-n8n-data-pvc-*`.

### 1.2 Initial rsync from legacy NFS to Longhorn PVC

Run a one-shot Job in the new cluster that mounts the legacy NFS export
read-only and the new Longhorn PVC:

```yaml
# /tmp/opencode/n8n-rsync-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: n8n-data-rsync
  namespace: n8n
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
            # Actual legacy export (found via step 1.1):
            path: /k8s/apps-n8n-data-pvc-2f3b3cfe-8dc4-4ee4-beb8-fe0db44890d8
            readOnly: true
        - name: dst
          persistentVolumeClaim:
            claimName: n8n-data
```

Apply and follow (temporary operational Job — allowed alongside GitOps,
same approach as the Home Assistant migration):

```bash
kubectl apply -f /tmp/opencode/n8n-rsync-job.yaml
kubectl -n n8n logs -f job/n8n-data-rsync
kubectl -n n8n delete job n8n-data-rsync
```

`--delete` mirrors the source. Re-running the same Job at cutover time is
idempotent and only transfers the delta.

### 1.3 Verify the encryption key arrived

```bash
kubectl -n n8n run n8n-data-check --rm -it --image=alpine --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"n8n-data-check","image":"alpine",
  "stdin":true,"tty":true,"volumeMounts":[{"name":"data","mountPath":"/data"}]}],
  "volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"n8n-data"}}]}}' \
  -- sh -c 'ls -la /data && grep -o "\"encryptionKey\": *\"[^\"]*\"" /data/config | head -1'
```

`config` must exist and contain an `encryptionKey` entry.

---

## Phase 2 — Cutover (< 15 min downtime)

### 2.1 Stop the legacy n8n

The legacy cluster (Talos on RPi4, nodes `192.0.2.11-3`) is reachable with
the talosconfig stored in the old repo — no separate kubeconfig needed:

```bash
talosctl --talosconfig <infraestructura>/core/talos/config/talosconfig \
  -n 192.0.2.11 kubeconfig /tmp/opencode/legacy-kubeconfig --force
export LEGACY_KUBECONFIG=/tmp/opencode/legacy-kubeconfig

# Deployment name on the legacy cluster is controller-main
kubectl --kubeconfig="$LEGACY_KUBECONFIG" -n apps-n8n \
  scale deploy/controller-main --replicas=0
kubectl --kubeconfig="$LEGACY_KUBECONFIG" -n apps-n8n \
  wait --for=delete pod -l app=main --timeout=120s
```

Record the wall-clock time — workflow executions, webhooks and schedules
are paused from this instant until the new pod is healthy.

### 2.2 Final rsync delta

```bash
kubectl apply -f /tmp/opencode/n8n-rsync-job.yaml
kubectl -n n8n logs -f job/n8n-data-rsync
kubectl -n n8n delete job n8n-data-rsync
```

Second pass transfers only the delta since Phase 1 (usually a few MB).

### 2.3 Dump the legacy DB and restore into CNPG

Streamed via `kubectl exec` to avoid needing a local psql client (the Nix
shell has none by default). `--clean --if-exists` makes the restore
idempotent against the empty destination DB; `--no-owner --no-privileges`
avoids role-mapping noise (everything runs as superuser, and the `n8n`
role already owns the database).

```bash
# Sanity: destination DB is empty (no n8n tables yet)
kubectl -n postgres exec postgres-1 -c postgres -- \
  psql -U postgres -d n8n -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='public';"
# expect: 0

# Dump legacy -> restore into CNPG in one stream
kubectl -n postgres exec -i postgres-1 -c postgres -- \
  sh -c "PGPASSWORD='$SRC_APP_PASSWORD' pg_dump \
    -h $SRC_HOST -p $SRC_PORT -U $SRC_APP_USER -d $SRC_DB \
    --clean --if-exists --no-owner --no-privileges" \
  | kubectl -n postgres exec -i postgres-1 -c postgres -- \
      psql -U postgres -d n8n -v ON_ERROR_STOP=1 --single-transaction
```

Fix ownership so the `n8n` role fully owns every restored object (n8n runs
schema migrations on boot, which require table ownership). Because the
restore runs as the `postgres` superuser — a pinned role — `REASSIGN OWNED`
is rejected by PostgreSQL ("objects owned by role postgres ... required by
the database system"), so ownership is transferred object by object.
Sequences linked to a table column (serial/identity) cannot be altered
directly; they follow their owning table:

```bash
kubectl -n postgres exec postgres-1 -c postgres -- \
  psql -U postgres -d n8n -v ON_ERROR_STOP=1 -c "
DO \$\$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT c.oid, c.relname, c.relkind FROM pg_class c
           JOIN pg_namespace n ON n.oid=c.relnamespace
           WHERE n.nspname='public' AND c.relkind IN ('r','v','m')
              OR (n.nspname='public' AND c.relkind='S' AND NOT EXISTS
                  (SELECT 1 FROM pg_depend d
                   WHERE d.classid='pg_class'::regclass
                     AND d.objid=c.oid AND d.deptype IN ('a','i')))
           LOOP
    EXECUTE format('ALTER %s %I OWNER TO n8n',
      CASE r.relkind WHEN 'r' THEN 'TABLE' WHEN 'S' THEN 'SEQUENCE'
           WHEN 'v' THEN 'VIEW' ELSE 'MATERIALIZED VIEW' END,
      r.relname);
  END LOOP;
END \$\$;"
```

Verify every object is owned by `n8n` (second query prints nothing):

```bash
kubectl -n postgres exec postgres-1 -c postgres -- \
  psql -U postgres -d n8n -tAc \
  "SELECT distinct tableowner FROM pg_tables WHERE schemaname='public';"
kubectl -n postgres exec postgres-1 -c postgres -- \
  psql -U postgres -d n8n -tAc \
  "SELECT c.relkind, count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relkind IN ('r','S','v','m')
     AND pg_get_userbyid(c.relowner)<>'n8n' GROUP BY c.relkind;"
```

### 2.4 Start n8n on the new cluster

Edit `cluster/apps/platform/n8n/deployment.yaml` (`replicas: 0` → `1`),
commit, push, then:

```bash
flux -n flux-system reconcile source git flux-system
flux -n flux-system reconcile kustomization cluster-apps
kubectl -n n8n rollout status deploy/n8n --timeout=300s
kubectl -n n8n logs -f deploy/n8n
```

The exact-hostname HTTPRoute immediately takes precedence over the
`legacy-fallback` wildcard, so `https://n8n-apps.example.com` now terminates
on the new pod. No DNS or route changes needed.

### 2.5 Validate

- Open `https://n8n-apps.example.com` and log in with the usual owner account.
- Workflows list shows every pre-migration workflow.
- Open a workflow with stored credentials and run it manually — a
  credential that fails to decrypt means `config` (encryption key) did not
  survive the rsync; re-check Phase 1.3 before anything else.
- Fire a webhook-based workflow and confirm the external system receives
  the callback URL `https://n8n-apps.example.com/...` (from `WEBHOOK_URL`).
- Check `Executions` for errors and confirm new executions are recorded
  (DB write path works).
- Compare row counts against the source right before decommission:
  ```sql
  SELECT count(*) FROM workflow_entity;
  SELECT count(*) FROM credentials_entity;
  SELECT count(*) FROM execution_entity;
  ```

---

## Phase 3 — Decommission

After **≥ 24 hours** of stable operation:

1. Destroy the Pulumi stack for n8n on the legacy cluster
   (`nx run apps-n8n:destroy` in `infraestructura`).
2. Keep the legacy PostgreSQL running for a few more days as a warm
   fallback; drop the `n8n` DB and role once confident.
3. Remove the legacy NFS export directory once the PVC data is verified.

---

## Rollback plan

If something fails after 2.4:

1. `kubectl -n n8n scale deploy/n8n --replicas=0` (or revert the
   `replicas: 1` commit and reconcile).
2. With no pod behind the exact-hostname route the gateway still matches
   it; to fail back cleanly, delete the HTTPRoute
   (`kubectl -n n8n delete httproute n8n`) so `legacy-fallback` resumes
   proxying — or simply revert the n8n kustomization commit.
3. Scale the legacy n8n back to `replicas=1`.
4. The legacy DB was never written after 2.1, so it resumes cleanly.
5. The destination PVC and DB stay intact for a second attempt.
   If necessary, drop and recreate the `n8n` DB via CNPG
   (`kubectl -n postgres delete database n8n`; Flux reconciles a fresh
   empty one on the next pass).
