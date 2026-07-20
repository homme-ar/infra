# PostgreSQL Major Upgrade: `postgres` Cluster PG17 → PG18

Migrates the shared CNPG `postgres` cluster (namespace `postgres`) from
PostgreSQL **17** to PostgreSQL **18**, preserving the `authelia` database
(WebAuthn passkeys, TOTP secrets, sessions, users) and the `app` database
created by initdb.

## Why an offline dump/restore

CloudNativePG explicitly **forbids in-place major version upgrades**: the
[`imageName`](https://cloudnative-pg.io/documentation/current/cluster_conf/#image-catalog)
field of a `Cluster` cannot be bumped across major versions because
PostgreSQL's on-disk format changes. The two supported paths are:

1. **Offline import** via `bootstrap.initdb.import` on a new Cluster
   (creates the new cluster, does `pg_dump | pg_restore` inside it, and
   promotes it). Cleanest but requires either a temporary parallel Cluster
   or destroying the current one first.
2. **Manual pg_dump / pg_restore** into a freshly-recreated Cluster of the
   same name. This runbook uses this path because we want to keep the
   name `postgres` (Authelia points at `postgres-rw.postgres.svc`) and we
   accept ~10 minutes of downtime.

## Preconditions

- Flux is healthy and reconciling from `main`.
- SOPS Age key is available (`$SOPS_AGE_KEY_FILE`).
- Direnv is loaded (`kubectl`, `flux`, `sops` from Nix).
- Kubeconfig: `talos/clusterconfig/kubeconfig`.
- No new commits touching `cluster/apps/platform/postgres/` are in flight.

The manifest change (`cluster.yaml`: `postgresql:17` → `postgresql:18`) is
already committed in this branch. **Do NOT push it until you are at
Step 5** — otherwise Flux will try to recreate the cluster with PG18 while
the PG17 data is still on the PVCs, which fails.

## Environment

```bash
export KUBECONFIG="$PWD/talos/clusterconfig/kubeconfig"
export NS=postgres

# Path where the intermediate dump will live. Sized for a small (< 1 GB)
# Authelia + app dataset; adjust if the databases grow substantially.
export DUMP_DIR=/tmp/pg17-dump
mkdir -p "$DUMP_DIR"
```

The superuser password is stored in the SOPS secret
`cluster/apps/platform/postgres/secret.yaml` (key `password`). Decrypt it
once:

```bash
export PGPASSWORD=$(
  sops -d cluster/apps/platform/postgres/secret.yaml \
    | yq -r '.stringData.password'
)
```

---

## Step 1 — Pre-flight

Confirm the current state:

```bash
kubectl -n $NS get cluster postgres \
  -o jsonpath='{.spec.imageName}{"\n"}'
# expect: ghcr.io/cloudnative-pg/postgresql:17

kubectl -n $NS get pods -l cnpg.io/cluster=postgres
# expect: postgres-1 (primary) + postgres-2 (standby), both Running

kubectl -n $NS get pvc
# expect: postgres-1 and postgres-2 PVCs on longhorn-singlenode
```

List databases (sanity check):

```bash
kubectl -n $NS exec -it postgres-1 -c postgres -- \
  psql -U postgres -l
# expect at least: app, authelia, postgres, template0, template1
```

## Step 2 — Suspend consumers (Authelia)

Scale Authelia down so no new writes hit PG17 while we dump. Any user
mid-session will see a brief 502 until Step 6.

```bash
kubectl -n authelia scale deploy/authelia --replicas=0
kubectl -n authelia wait --for=delete pod -l app.kubernetes.io/name=authelia --timeout=60s
```

Also pause any Flux reconciliation on the postgres kustomization to
prevent it from re-creating the resource we are about to delete:

```bash
flux -n flux-system suspend kustomization cluster-apps
```

> `cluster-apps` covers everything under `cluster/apps/` — we suspend the
> whole tree because the postgres cluster does not have its own
> Kustomization. We will resume it in Step 5.

## Step 3 — Take a full logical dump of PG17

Dump using `--format=custom` (compressed, parallel-restore friendly) plus
`pg_dumpall --globals-only` to preserve roles and grants that live outside
individual databases (the `authelia` role managed by CNPG in particular).

```bash
# Port-forward to the current primary so we can run pg_dump locally.
# Using the -rw service ensures we always talk to the primary.
kubectl -n $NS port-forward svc/postgres-rw 15432:5432 >/tmp/pf.log 2>&1 &
PF_PID=$!
sleep 2

# Globals (roles, tablespaces, DB-level ACLs)
pg_dumpall -h 127.0.0.1 -p 15432 -U postgres \
  --globals-only --no-role-passwords \
  > "$DUMP_DIR/globals.sql"

# Per-database logical dumps in custom format
for DB in app authelia; do
  pg_dump -h 127.0.0.1 -p 15432 -U postgres \
    --format=custom --compress=6 --no-owner --no-privileges \
    --file "$DUMP_DIR/${DB}.dump" \
    "$DB"
done

kill $PF_PID
wait $PF_PID 2>/dev/null || true

ls -lh "$DUMP_DIR"
```

Verify the dumps are readable:

```bash
pg_restore --list "$DUMP_DIR/authelia.dump" | head
pg_restore --list "$DUMP_DIR/app.dump"      | head
```

> `--no-role-passwords` on `pg_dumpall` writes placeholder passwords for
> roles. CNPG will re-apply the correct passwords from the SOPS secrets
> (`postgres-superuser-secret`, `authelia-postgres-secret`) via its
> `managed.roles` mechanism in Step 5, so the placeholders never matter.

## Step 4 — Destroy the old Cluster (keep the PVCs as a snapshot)

The Longhorn StorageClass `longhorn-singlenode` uses
`reclaimPolicy: Retain`, so deleting the Cluster (and its PVCs) will
**not** delete the underlying Longhorn volumes. They stay around as an
emergency rollback surface.

```bash
# Delete the CNPG Cluster — this also removes its Pods and PDBs.
kubectl -n $NS delete cluster postgres --wait=true

# Delete the PVCs so that the new PG18 Cluster can create fresh ones.
# The Longhorn PVs remain in Released state (Retain policy).
kubectl -n $NS delete pvc -l cnpg.io/cluster=postgres --wait=true

# Confirm the underlying PVs are still present.
kubectl get pv | grep postgres
# expect: Released status, RECLAIM POLICY = Retain
```

If you want to reclaim them later, `kubectl delete pv <name>` once you are
sure the migration is stable.

## Step 5 — Deploy the PG18 Cluster via Flux

Now that the old cluster is gone, resume the Kustomization and force a
reconciliation. Flux will apply the already-committed manifest with
`imageName: ghcr.io/cloudnative-pg/postgresql:18`.

```bash
# Commit + push the imageName change if not already on main.
git status cluster/apps/platform/postgres/
# git add cluster/apps/platform/postgres/cluster.yaml docs/POSTGRES-PG18-UPGRADE.md
# git commit -m "postgres: upgrade shared CNPG cluster to PostgreSQL 18"
# git push

flux -n flux-system resume kustomization cluster-apps
flux -n flux-system reconcile source git flux-system
flux -n flux-system reconcile kustomization cluster-apps --with-source

# Watch the new Cluster come up (initdb bootstrap creates the `app` DB).
kubectl -n $NS get cluster postgres -w
# Ready → 1/1 primary + 1/1 standby, imageName ends in ":18"
```

Sanity check the new version:

```bash
kubectl -n $NS exec -it postgres-1 -c postgres -- \
  psql -U postgres -c 'SELECT version();'
# expect: PostgreSQL 18.x
```

At this point CNPG has:

- Created a fresh `app` DB (owner `app`) via `bootstrap.initdb`.
- Applied `managed.roles` → the `authelia` login role exists again with
  the password from `authelia-postgres-secret`.
- **Not** created the `authelia` DB yet; the `Database` CR
  `cluster/apps/platform/postgres/authelia-database.yaml` triggers that.

Confirm the `authelia` DB exists and is empty:

```bash
kubectl -n $NS exec -it postgres-1 -c postgres -- \
  psql -U postgres -c '\l authelia'
kubectl -n $NS exec -it postgres-1 -c postgres -- \
  psql -U postgres -d authelia -c '\dt'
# expect: no relations (empty schema)
```

## Step 6 — Restore the dumps into PG18

Port-forward again:

```bash
kubectl -n $NS port-forward svc/postgres-rw 15432:5432 >/tmp/pf.log 2>&1 &
PF_PID=$!
sleep 2
```

Restore globals **except** role definitions (CNPG owns those now):

```bash
# Strip CREATE ROLE / ALTER ROLE lines to avoid clashing with the
# CNPG-managed superuser and authelia roles. We only care about GRANTs
# and tablespace definitions from globals.sql.
grep -Ev '^(CREATE ROLE|ALTER ROLE|DROP ROLE)' "$DUMP_DIR/globals.sql" \
  > "$DUMP_DIR/globals-safe.sql"

psql -h 127.0.0.1 -p 15432 -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -f "$DUMP_DIR/globals-safe.sql"
```

Restore `app` (drops the empty CNPG-provisioned schema first):

```bash
psql -h 127.0.0.1 -p 15432 -U postgres -d postgres \
  -c 'DROP DATABASE app;'
psql -h 127.0.0.1 -p 15432 -U postgres -d postgres \
  -c 'CREATE DATABASE app OWNER app;'

pg_restore -h 127.0.0.1 -p 15432 -U postgres -d app \
  --no-owner --role=app --jobs=4 --exit-on-error \
  "$DUMP_DIR/app.dump"
```

Restore `authelia` into the empty DB provisioned by the `Database` CR:

```bash
# Ensure the target is empty (CNPG might have created default extensions).
psql -h 127.0.0.1 -p 15432 -U postgres -d authelia \
  -c 'DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public AUTHORIZATION authelia;'

pg_restore -h 127.0.0.1 -p 15432 -U postgres -d authelia \
  --no-owner --role=authelia --jobs=4 --exit-on-error \
  "$DUMP_DIR/authelia.dump"
```

Clean up the port-forward:

```bash
kill $PF_PID
```

## Step 7 — Bring Authelia back up

```bash
kubectl -n authelia scale deploy/authelia --replicas=1
kubectl -n authelia rollout status deploy/authelia --timeout=180s
kubectl -n authelia logs -f deploy/authelia
```

Look for the schema-check log line and the absence of migration errors.
Authelia's Go migrator sees the tables already at the correct schema
version and skips migrations.

## Step 8 — Validate

1. Log in at `https://auth.homme.ar` using an existing WebAuthn passkey
   or TOTP code (proves the encrypted `webauthn_credentials` and
   `totp_configurations` rows survived).
2. Trigger a protected route (e.g. `https://longhorn-adm.homme.ar`) and
   confirm the Authelia session cookie is accepted without a fresh
   enrollment.
3. Inspect row counts:

   ```sql
   -- Run inside postgres-1
   \c authelia
   SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY relname;
   ```

   Compare with the pre-migration counts captured in Step 1 (optional).

## Step 9 — Reclaim old PVs

After **at least 24 hours** of stable Authelia operation:

```bash
# Identify the PVs previously bound to postgres-1 / postgres-2 (Released state).
kubectl get pv | awk '/postgres/ && /Released/ {print $1}'

# Delete once you are confident. This also frees the Longhorn volume.
kubectl delete pv <released-pv-1> <released-pv-2>
```

## Rollback plan

If Step 5 or Step 6 fail beyond recovery:

1. Revert the manifest to `imageName: ghcr.io/cloudnative-pg/postgresql:17`
   and push (or `git revert` the upgrade commit).
2. `flux reconcile kustomization cluster-apps --with-source`.
3. Delete the failed PG18 Cluster and its fresh PVCs
   (`kubectl -n $NS delete cluster postgres` +
   `kubectl -n $NS delete pvc -l cnpg.io/cluster=postgres`).
4. The Retained PG17 PVs are still there. Re-bind them by creating PVCs
   with matching names and `spec.volumeName` pointing at the released PV,
   then `flux reconcile` — CNPG will pick them up on the next
   reconciliation and start PG17 back up.
5. If PV re-binding is too fragile, the dumps in `$DUMP_DIR` can be
   restored into a fresh PG17 Cluster instead.

## Notes

- The upgrade does not touch `home-assistant-db` — that Cluster was
  already provisioned on PG18 from day one and is unaffected.
- After this upgrade, both CNPG Clusters in the fleet (`postgres` and
  `home-assistant-db`) run PG18, matching the legacy source and unblocking
  logical replication for future migrations.
