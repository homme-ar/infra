# Jellyseerr → Seerr Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Jellyseerr deployment with Seerr (full rename to `seerr`), migrating the existing config volume, in a staged 3-commit cutover.

**Architecture:** New `cluster/apps/media/seerr/` directory mirrors the current jellyseerr manifests (namespace, PVC, Deployment, Service, HTTPRoute). Data moves via a one-shot copy Job while Flux is suspended; because PVCs are namespace-scoped, the copy Job runs in the old namespace against a temporary PVC, and the resulting Longhorn PV is then rebound (Retain + volumeName) to the GitOps-managed `seerr-config` PVC in the new namespace. Seerr auto-migrates the config on first boot. Old `jellyseerr/` is pruned only after verification.

**Tech Stack:** Kubernetes YAML + Kustomize, FluxCD GitOps, Longhorn storage, SOPS/Age secrets, Gateway API HTTPRoute, homepage discovery annotations.

**Spec:** `docs/superpowers/specs/2026-07-27-jellyseerr-to-seerr-migration-design.md`

## Global Constraints

- Everything (comments, docs, commit messages) in **English only**.
- All cluster commands run inside the Nix dev shell (`nix develop --command ...` or direnv) and use explicit config paths:
  - `export KUBECONFIG="talos/clusterconfig/kubeconfig"`
- No `kubectl apply` for repo-managed resources — the only imperatively-applied objects are the temporary copy Job + tmp PVC and the manual scale/suspend/PV-patch during cutover, exactly as the spec allows.
- Image pinned: `ghcr.io/seerr-team/seerr:v3.3.0`, `imagePullPolicy: IfNotPresent`.
- Every resource declares its own `namespace:` inline; the kustomization does **not** set a top-level `namespace:`.
- The homepage SOPS secret stays comment-free; edit it only with `sops` (never decrypt to disk).
- Repo conventions: two-space indent, one resource per file, labels `app.kubernetes.io/name` + `app.kubernetes.io/component`.
- The Flux Kustomization that reconciles `./cluster/apps` is named `cluster-apps` in namespace `flux-system`.

---

### Task 1: New `seerr` namespace (cutover commit 1)

**Files:**
- Create: `cluster/apps/media/seerr/namespace.yaml`
- Create: `cluster/apps/media/seerr/kustomization.yaml`
- Modify: `cluster/apps/media/kustomization.yaml`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: namespace `seerr`, where the `seerr-config` PVC will be created in Task 3 (bound to the PV migrated in Task 2).

Note: the PVC is deliberately **not** created yet — it must carry `volumeName`, which is only known after the copy in Task 2.

- [ ] **Step 1: Create `cluster/apps/media/seerr/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: seerr
```

- [ ] **Step 2: Create `cluster/apps/media/seerr/kustomization.yaml`**

Only the namespace for now; the rest is added in Task 3.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Do NOT set `namespace:` here — every resource declares its own namespace
# inline (keeps parity with the SOPS-encrypted apps where a top-level
# namespace rewrite would corrupt the MAC).
resources:
  - namespace.yaml
```

- [ ] **Step 3: Add `seerr` to `cluster/apps/media/kustomization.yaml`**

Insert alphabetically (after `sabnzbd`, before `sonarr`):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - bazarr
  - jellyfin
  - jellyseerr
  - lidarr
  - prowlarr
  - radarr
  - sabnzbd
  - seerr
  - sonarr
```

- [ ] **Step 4: Render locally to validate**

Run: `nix develop --command kustomize build cluster/apps/media/seerr`
Expected: renders Namespace `seerr`, no errors.

- [ ] **Step 5: Commit and push**

```bash
git add cluster/apps/media/seerr cluster/apps/media/kustomization.yaml
git commit -m "feat(media): add seerr namespace"
git push
```

- [ ] **Step 6: Reconcile and confirm the namespace exists**

```bash
export KUBECONFIG="talos/clusterconfig/kubeconfig"
flux reconcile kustomization cluster-apps -n flux-system
kubectl get ns seerr
```

Expected: namespace `seerr` Active.

---

### Task 2: Copy config data to a new volume (manual, outside Flux)

**Files:**
- Create (temporary, NOT committed): `/tmp/seerr-copy-job.yaml`

**Interfaces:**
- Consumes: existing PVC `jellyseerr-config` in namespace `jellyseerr`.
- Produces: a Longhorn PV containing the migrated config (owned `1000:1000`), reclaim policy `Retain`, claimRef cleared — its name is recorded as `<PV_NAME>` and consumed by Task 3 Step 1.

- [ ] **Step 1: Verify a recent Longhorn backup of the old volume exists**

```bash
export KUBECONFIG="talos/clusterconfig/kubeconfig"
kubectl -n longhorn-system get backups.longhorn.io | grep -i jellyseerr | tail -5
```

Expected: a recent completed backup (the PVC carries the recurring-job label). If none is recent, trigger one from the Longhorn UI before continuing.

- [ ] **Step 2: Suspend Flux and stop jellyseerr**

```bash
flux suspend kustomization cluster-apps -n flux-system
kubectl -n jellyseerr scale deploy/jellyseerr --replicas=0
kubectl -n jellyseerr wait --for=delete pod -l app.kubernetes.io/name=jellyseerr --timeout=120s
```

Expected: no jellyseerr pods left (RWO volume detached, no SQLite writes mid-copy).

- [ ] **Step 3: Write `/tmp/seerr-copy-job.yaml`**

PVCs are namespace-scoped, so the tmp PVC and the Job both live in namespace `jellyseerr` to mount `jellyseerr-config`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: seerr-config-tmp
  namespace: jellyseerr
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 2Gi
---
apiVersion: batch/v1
kind: Job
metadata:
  name: seerr-config-copy
  namespace: jellyseerr
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: copy
          image: docker.io/library/alpine:3.22
          command:
            - sh
            - -c
            - |
              set -e
              cp -a /old/. /new/
              chown -R 1000:1000 /new
              ls -la /new
          securityContext:
            runAsUser: 0
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
              add:
                - CHOWN
                - FOWNER
                - DAC_OVERRIDE
          volumeMounts:
            - name: old
              mountPath: /old
              readOnly: true
            - name: new
              mountPath: /new
      volumes:
        - name: old
          persistentVolumeClaim:
            claimName: jellyseerr-config
            readOnly: true
        - name: new
          persistentVolumeClaim:
            claimName: seerr-config-tmp
```

- [ ] **Step 4: Run the copy and verify**

```bash
kubectl apply -f /tmp/seerr-copy-job.yaml
kubectl -n jellyseerr wait --for=condition=complete job/seerr-config-copy --timeout=300s
kubectl -n jellyseerr logs job/seerr-config-copy | tail -20
```

Expected: `ls -la /new` output shows the config files (`settings.json`, `db/`, etc.), owned by `1000:1000`.

- [ ] **Step 5: Rebind the new volume for namespace `seerr`**

```bash
PV_NAME=$(kubectl get pvc seerr-config-tmp -n jellyseerr -o jsonpath='{.spec.volumeName}')
echo "$PV_NAME"   # record this — needed in Task 3 Step 1
kubectl patch pv "$PV_NAME" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl -n jellyseerr delete job seerr-config-copy
kubectl -n jellyseerr delete pvc seerr-config-tmp
kubectl patch pv "$PV_NAME" --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
kubectl get pv "$PV_NAME"
```

Expected: PV shows status `Available`, reclaim policy `Retain`, no claimRef.

- [ ] **Step 6: Clean up**

```bash
rm /tmp/seerr-copy-job.yaml
```

State at this point: old jellyseerr Deployment scaled to 0 (Flux still suspended), old PVC/volume untouched, new migrated PV Available.

---

### Task 3: Seerr PVC, Deployment, Service, HTTPRoute + repo touchpoints (cutover commit 2)

**Files:**
- Create: `cluster/apps/media/seerr/pvc-config.yaml`
- Create: `cluster/apps/media/seerr/deployment.yaml`
- Create: `cluster/apps/media/seerr/service.yaml`
- Create: `cluster/apps/media/seerr/httproute.yaml`
- Modify: `cluster/apps/media/seerr/kustomization.yaml`
- Modify: `cluster/apps/platform/homepage/secret.yaml` (via `sops`)
- Modify: `cluster/infrastructure/renovate/release.yaml:90`
- Modify: `docs/MEDIA-STACK.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: `<PV_NAME>` from Task 2 Step 5; existing homepage secret key `HOMEPAGE_VAR_JELLYSEERR_API_KEY` (value unchanged).
- Produces: running Seerr at `seerr-apps.${CLUSTER_DOMAIN}`, Service DNS `seerr.seerr`, homepage widget via `{{HOMEPAGE_VAR_SEERR_API_KEY}}`.

- [ ] **Step 1: Create `cluster/apps/media/seerr/pvc-config.yaml` bound to the migrated PV**

Write the literal `<PV_NAME>` from Task 2 (Flux substitution does not touch `volumeName`):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: seerr-config
  namespace: seerr
  labels:
    app.kubernetes.io/name: seerr
    app.kubernetes.io/component: storage
    # Include this volume in the Longhorn NAS backup jobs (see docs/BACKUPS.md)
    recurring-job-group.longhorn.io/backup: enabled
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS}
  volumeName: <PV_NAME>
  resources:
    requests:
      storage: 2Gi
```

- [ ] **Step 2: Create `cluster/apps/media/seerr/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: seerr
  namespace: seerr
  labels:
    app.kubernetes.io/name: seerr
    app.kubernetes.io/component: server
spec:
  replicas: 1
  # Recreate ensures the RWO Longhorn PVC is released before a new pod
  # attaches it, preventing multi-attach errors and SQLite corruption.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: seerr
  template:
    metadata:
      labels:
        app.kubernetes.io/name: seerr
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: seerr
          image: ghcr.io/seerr-team/seerr:v3.3.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 5055
              protocol: TCP
          env:
            - name: TZ
              value: America/Argentina/Buenos_Aires
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 50m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 1Gi
          livenessProbe:
            httpGet:
              path: /api/v1/status
              port: http
            initialDelaySeconds: 30
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /api/v1/status
              port: http
            initialDelaySeconds: 10
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 3
          volumeMounts:
            - name: config
              mountPath: /app/config
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: seerr-config
```

- [ ] **Step 3: Create `cluster/apps/media/seerr/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: seerr
  namespace: seerr
  labels:
    app.kubernetes.io/name: seerr
    app.kubernetes.io/component: server
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
  selector:
    app.kubernetes.io/name: seerr
```

- [ ] **Step 4: Create `cluster/apps/media/seerr/httproute.yaml`**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: seerr
  namespace: seerr
  annotations:
    gethomepage.dev/enabled: "true"
    gethomepage.dev/href: "https://seerr-apps.${CLUSTER_DOMAIN}"
    gethomepage.dev/group: Media
    gethomepage.dev/weight: "20"
    gethomepage.dev/name: Seerr
    gethomepage.dev/icon: seerr.png
    gethomepage.dev/description: Media requests
    gethomepage.dev/widget.type: "seerr"
    gethomepage.dev/widget.url: "http://seerr.seerr"
    gethomepage.dev/widget.key: "{{HOMEPAGE_VAR_SEERR_API_KEY}}"
spec:
  parentRefs:
    - name: envoy-gateway
      namespace: kube-system
  hostnames:
    - "seerr-apps.${CLUSTER_DOMAIN}"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: seerr
          port: 80
```

- [ ] **Step 5: Update `cluster/apps/media/seerr/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Do NOT set `namespace:` here — every resource declares its own namespace
# inline (keeps parity with the SOPS-encrypted apps where a top-level
# namespace rewrite would corrupt the MAC).
resources:
  - namespace.yaml
  - pvc-config.yaml
  - deployment.yaml
  - service.yaml
  - httproute.yaml
```

- [ ] **Step 6: Rename the homepage secret key**

Run: `sops cluster/apps/platform/homepage/secret.yaml`
In the editor, rename `HOMEPAGE_VAR_JELLYSEERR_API_KEY` → `HOMEPAGE_VAR_SEERR_API_KEY` (value unchanged — the API key survives the Seerr auto-migration). Save and exit. Do not add comments; only `stringData` stays encrypted.

- [ ] **Step 7: Update Renovate grouping**

In `cluster/infrastructure/renovate/release.yaml` (line ~90), replace:

```yaml
            { matchFileNames: ['cluster/apps/media/jellyseerr/**'], groupName: 'jellyseerr', groupSlug: 'jellyseerr' },
```

with:

```yaml
            { matchFileNames: ['cluster/apps/media/seerr/**'], groupName: 'seerr', groupSlug: 'seerr' },
```

- [ ] **Step 8: Update `docs/MEDIA-STACK.md`**

Replace jellyseerr references with seerr (lines ~3, ~20, ~60, ~100): app list entry, the non-root note, the built-in auth note, and the setup bullet (`seerr: connect to Jellyfin, then link sonarr/radarr for request fulfillment.`).

- [ ] **Step 9: Update `AGENTS.md`**

In the homepage-config bullet, replace the `` `JELLYSEERR` `` mention with `` `SEERR` `` in the list of API keys.

- [ ] **Step 10: Render locally to validate**

```bash
nix develop --command kustomize build cluster/apps/media/seerr
nix develop --command kustomize build cluster/apps/media
```

Expected: all five seerr resources render; no errors.

- [ ] **Step 11: Commit and push**

```bash
git add cluster/apps/media/seerr cluster/apps/platform/homepage/secret.yaml cluster/infrastructure/renovate/release.yaml docs/MEDIA-STACK.md AGENTS.md
git commit -m "feat(media): migrate jellyseerr to seerr v3.3.0"
git push
```

- [ ] **Step 12: Resume Flux and reconcile**

```bash
export KUBECONFIG="talos/clusterconfig/kubeconfig"
flux resume kustomization cluster-apps -n flux-system
flux reconcile kustomization cluster-apps -n flux-system
kubectl -n seerr rollout status deploy/seerr --timeout=300s
```

Expected: `seerr` pod Running and Ready on the copied data; PVC `seerr-config` Bound to the migrated PV.

Note: resuming Flux also scales the old jellyseerr Deployment back to 1 (it is still in the repo). That is intentional — it stays as a live rollback on the old hostname until Task 5.

---

### Task 4: Verify the migration

**Files:** none (verification only).

- [ ] **Step 1: Check migration logs**

Run: `kubectl -n seerr logs deploy/seerr | head -50`
Expected: Seerr starts, runs its migrations, no errors about the database or settings.

- [ ] **Step 2: Check the status endpoint**

Run: `kubectl -n seerr exec deploy/seerr -- wget -qO- http://localhost:5055/api/v1/status`
Expected: JSON reporting version `3.3.0`.

- [ ] **Step 3: Verify externally**

Open `https://seerr-apps.homme.ar`: login works, users/requests/settings intact, Jellyfin + Sonarr/Radarr connections still configured.

- [ ] **Step 4: Restart homepage and check the widget**

```bash
kubectl -n homepage rollout restart deploy/homepage
```

Expected: the Seerr widget on the homepage shows data (uses the renamed `HOMEPAGE_VAR_SEERR_API_KEY`).

- [ ] **Step 5: Confirm the old instance is untouched**

Run: `kubectl -n jellyseerr get pvc jellyseerr-config`
Expected: still Bound (rollback intact).

---

### Task 5: Remove Jellyseerr (cutover commit 3)

**Files:**
- Delete: `cluster/apps/media/jellyseerr/` (whole directory)
- Modify: `cluster/apps/media/kustomization.yaml`

- [ ] **Step 1: Remove the directory and the kustomization entry**

```bash
git rm -r cluster/apps/media/jellyseerr
```

Edit `cluster/apps/media/kustomization.yaml` to drop the `- jellyseerr` line:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - bazarr
  - jellyfin
  - lidarr
  - prowlarr
  - radarr
  - sabnzbd
  - seerr
  - sonarr
```

- [ ] **Step 2: Render locally to validate**

Run: `nix develop --command kustomize build cluster/apps/media`
Expected: renders without jellyseerr, no errors.

- [ ] **Step 3: Commit, push, reconcile**

```bash
git add cluster/apps/media/kustomization.yaml
git commit -m "chore(media): remove jellyseerr after seerr migration"
git push
export KUBECONFIG="talos/clusterconfig/kubeconfig"
flux reconcile kustomization cluster-apps -n flux-system
kubectl get ns jellyseerr
```

Expected: namespace `jellyseerr` is pruned (NotFound after deletion); its PVC and Longhorn volume are deleted by the reclaim policy.

- [ ] **Step 4: Final check**

```bash
kubectl -n seerr get pods
flux get kustomizations -A | grep -i apps
```

Expected: seerr Running, `cluster-apps` Ready.

---

## Rollback (any point before Task 5)

Old namespace/PVC/volume are untouched. `flux resume kustomization cluster-apps -n flux-system` brings jellyseerr back at `jellyseerr-apps.homme.ar`; delete the `seerr` namespace and the migrated PV, and revert the git commits.

## Out of scope

- Updating external consumers of the old public URL (JellyWatch, bookmarks) — done by the user.
- Sonarr/Radarr reconfiguration — not needed (Seerr connects to them; config migrated).
