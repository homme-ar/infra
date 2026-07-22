# WAHA Migration Runbook

Migrates WAHA (WhatsApp HTTP API, `devlikeapro/waha`, WEBJS engine) from the
legacy Pulumi-managed cluster (`homme-ar/infraestructura`, `apps/waha`) to the
new Talos / Flux cluster in this repo.

## Goals

- Preserve `/app/.sessions` (WEBJS WhatsApp session) so the linked WhatsApp
  account keeps working **without scanning the QR code again**.
- Preserve `/app/.media` (downloaded media; `WHATSAPP_FILES_LIFETIME=0` keeps
  files forever).
- Keep the same hostname (`waha-adm.homme.ar`) and the same API key /
  dashboard / swagger credentials — no client changes.
- Short downtime (target: < 10 min).

## Source vs destination

| Aspect           | Legacy (source)                                  | New cluster (destination)                                                      |
|------------------|--------------------------------------------------|--------------------------------------------------------------------------------|
| Manifest tooling | Pulumi (`infraestructura/apps/waha`)             | Flux + Kustomize (`cluster/apps/platform/waha/`)                               |
| Image            | `devlikeapro/waha:arm-2026.5.1` (RPi4, arm64)    | `devlikeapro/waha:latest-2026.5.1` (same version, amd64 build)                 |
| Namespace        | `apps-waha`                                      | `waha`                                                                         |
| Deployment       | `controller-main`                                | `waha`                                                                         |
| Sessions volume  | NFS `10.0.4.1:/k8s/apps-waha-sessions-pvc-…` 10Gi| Longhorn RWO PVC `waha-sessions` (1Gi; actual usage ~150Ki)                    |
| Media volume     | NFS `10.0.4.1:/k8s/apps-waha-media-pvc-…` 100Gi  | Longhorn RWO PVC `waha-media` (5Gi, expandable; actual usage ~4Ki)             |
| Ingress          | Traefik Ingress + authentik forwardAuth          | Gateway API `HTTPRoute` + Authelia ext-authz (all paths, same behavior)        |
| Hostname         | `waha-adm.homme.ar`                              | `waha-adm.${CLUSTER_DOMAIN}` (identical)                                       |

### How traffic cutover works

Same mechanism as the n8n migration (see `docs/N8N-MIGRATION.md`): the
`legacy-fallback` HTTPRoute proxies every unmatched hostname to the legacy
cluster ingress. The new `HTTPRoute` in
`cluster/apps/platform/waha/httproute.yaml` matches `waha-adm.homme.ar`
**explicitly**, and an exact-hostname match wins over the fallback wildcard.
As soon as Flux applies the route, traffic lands on the new cluster — no DNS
change required. Until the Deployment is scaled above 0 the route returns 5xx,
which is why the cutover phases below matter.

### About the WhatsApp session

The WEBJS engine stores its LocalAuth session under `/app/.sessions/webjs/`.
The rsync below copies it verbatim, so the new pod should come up with the
session in `WORKING` state and **no QR re-scan**. The data is
architecture-independent (LevelDB/JSON state), so the arm64 → amd64 move is
safe. If the session ever shows `SCAN_QR_CODE` after cutover, open the
dashboard (`https://waha-adm.homme.ar/dashboard`) and re-scan — the API key
and webhooks configuration survive regardless.

> [!NOTE]
> **Execution outcome (2026-07-22):** the migrated session came up
> `SCAN_QR_CODE`, but the root cause predates the migration: the legacy
> `session-default` profile held only ~150Ki (a live WEBJS LocalAuth
> profile is tens of MB), its files dated from Oct 2025, and the final
> rsync delta was 0 bytes while the legacy pod had been running for days —
> i.e. WhatsApp had already logged the legacy session out months earlier.
> A QR re-scan via the dashboard was required regardless of the move.
> Also note: after the first boot on the new cluster the `default` session
> stayed `STOPPED` and had to be started once via
> `POST /api/sessions/default/start`.

## Prerequisites

- `direnv` loaded (Nix shell → `kubectl`, `flux`, `sops`).
- Kubeconfig at `talos/clusterconfig/kubeconfig` (see `AGENTS.md`).
- kubectl access to the **legacy** cluster (to scale the old WAHA down):

  ```bash
  talosctl --talosconfig <infraestructura>/core/talos/config/talosconfig \
    -n 10.0.10.1 kubeconfig /tmp/opencode/legacy-kubeconfig --force
  export LEGACY_KUBECONFIG=/tmp/opencode/legacy-kubeconfig
  ```

## Environment variables

```bash
export KUBECONFIG="$PWD/talos/clusterconfig/kubeconfig"
export LEGACY_KUBECONFIG=/tmp/opencode/legacy-kubeconfig
```

---

## Phase 0 — Deploy the empty destination

Already committed: `cluster/apps/platform/waha/` (namespace, PVCs, SOPS
secret, Deployment with `replicas: 0`, Service, HTTPRoute) plus the
`waha` entry in `platform/kustomization.yaml` and the `waha` namespace in
the Authelia `reference-grant.yaml`.

1. Trigger reconciliation:

   ```bash
   flux -n flux-system reconcile source git flux-system
   flux -n flux-system reconcile kustomization cluster-apps
   ```

2. Verify the namespace pieces:

   ```bash
   kubectl -n waha get pods,pvc,svc,httproute
   ```

   - `waha-sessions` and `waha-media` PVCs should be `Bound` on `longhorn`.
   - No pods: the Deployment ships with `replicas: 0` so the rsync Job can
     attach the PVCs.

---

## Phase 1 — Copy sessions + media (hot, safe)

Copying while the legacy WAHA runs is safe; a final delta pass happens at
cutover. Actual data is tiny (~150Ki sessions, ~4Ki media), so each pass
takes seconds.

### 1.1 Rsync Job (legacy NFS exports → Longhorn PVCs)

The legacy NFS external-provisioner exports are
`apps-waha-sessions-pvc-51dac6e3-75be-4bf1-aa75-4c5e8a53dc15` and
`apps-waha-media-pvc-eb182008-2c30-495b-8244-73087aa03a74` on `10.0.4.1`.

```yaml
# /tmp/opencode/waha-rsync-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: waha-data-rsync
  namespace: waha
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
                /src-sessions/ /dst-sessions/
              rsync -aHAX --numeric-ids --delete --info=progress2 \
                /src-media/ /dst-media/
          volumeMounts:
            - { name: src-sessions, mountPath: /src-sessions }
            - { name: dst-sessions, mountPath: /dst-sessions }
            - { name: src-media, mountPath: /src-media }
            - { name: dst-media, mountPath: /dst-media }
      volumes:
        - name: src-sessions
          nfs:
            server: 10.0.4.1
            path: /k8s/apps-waha-sessions-pvc-51dac6e3-75be-4bf1-aa75-4c5e8a53dc15
            readOnly: true
        - name: dst-sessions
          persistentVolumeClaim:
            claimName: waha-sessions
        - name: src-media
          nfs:
            server: 10.0.4.1
            path: /k8s/apps-waha-media-pvc-eb182008-2c30-495b-8244-73087aa03a74
            readOnly: true
        - name: dst-media
          persistentVolumeClaim:
            claimName: waha-media
```

Apply and follow (temporary operational Job — allowed alongside GitOps,
same approach as the n8n / Home Assistant migrations):

```bash
kubectl apply -f /tmp/opencode/waha-rsync-job.yaml
kubectl -n waha logs -f job/waha-data-rsync
kubectl -n waha delete job waha-data-rsync
```

`--delete` mirrors the source. Re-running the same Job at cutover time is
idempotent and only transfers the delta.

### 1.2 Verify the session directory arrived

```bash
kubectl -n waha run waha-data-check --rm -it --image=alpine --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"waha-data-check","image":"alpine",
  "stdin":true,"tty":true,"volumeMounts":[{"name":"sessions","mountPath":"/sessions"}]}],
  "volumes":[{"name":"sessions","persistentVolumeClaim":{"claimName":"waha-sessions"}}]}}' \
  -- sh -c 'ls -laR /sessions | head -30'
```

`/sessions/webjs/` must exist and contain the session subdirectory.

---

## Phase 2 — Cutover (< 10 min downtime)

### 2.1 Stop the legacy WAHA

```bash
# Deployment name on the legacy cluster is controller-main
kubectl --kubeconfig="$LEGACY_KUBECONFIG" -n apps-waha \
  scale deploy/controller-main --replicas=0
kubectl --kubeconfig="$LEGACY_KUBECONFIG" -n apps-waha \
  wait --for=delete pod -l app=main --timeout=120s
```

Record the wall-clock time — WhatsApp messages are **not** received or
queued by WAHA from this instant until the new pod is `WORKING` (WhatsApp
Web multi-device re-syncs recent messages once the session reconnects).

### 2.2 Final rsync delta

```bash
kubectl apply -f /tmp/opencode/waha-rsync-job.yaml
kubectl -n waha logs -f job/waha-data-rsync
kubectl -n waha delete job waha-data-rsync
```

### 2.3 Start WAHA on the new cluster

Edit `cluster/apps/platform/waha/deployment.yaml` (`replicas: 0` → `1`),
commit, push, then:

```bash
flux -n flux-system reconcile source git flux-system
flux -n flux-system reconcile kustomization cluster-apps
kubectl -n waha rollout status deploy/waha --timeout=300s
kubectl -n waha logs -f deploy/waha
```

The exact-hostname HTTPRoute immediately takes precedence over the
`legacy-fallback` wildcard, so `https://waha-adm.homme.ar` now terminates
on the new pod. No DNS or route changes needed.

### 2.4 Validate

- Session state (run inside the pod — the public hostname is behind
  Authelia, which blocks bare `X-Api-Key` calls):

  ```bash
  kubectl -n waha exec deploy/waha -- sh -c \
    'wget -q -O- --header="X-Api-Key: $WHATSAPP_API_KEY" \
     http://localhost:3000/api/sessions'
  ```

  Expect `"status": "WORKING"`. `SCAN_QR_CODE` means the session did not
  survive — re-scan via the dashboard (see "About the WhatsApp session").

- Open `https://waha-adm.homme.ar` — Authelia login (2FA) gates the whole
  hostname; swagger and the dashboard at `/dashboard` have **no built-in
  basic auth** (disabled post-migration — SSO-only access). The REST API
  still requires the `X-Api-Key` header.
- Send a test WhatsApp message to the linked number and confirm the
  configured webhook fires into n8n (check n8n execution history).

---

## Phase 3 — Decommission

After **≥ 24 hours** of stable operation:

1. Destroy the Pulumi stack on the legacy cluster
   (`nx run apps-waha:destroy` in `infraestructura`).
2. Remove the legacy NFS export directories
   (`apps-waha-sessions-pvc-*`, `apps-waha-media-pvc-*` on `10.0.4.1:/k8s`)
   once the Longhorn PVC data is verified.

---

## Rollback plan

If something fails after 2.3:

1. `kubectl -n waha scale deploy/waha --replicas=0` (or revert the
   `replicas: 1` commit and reconcile).
2. To fail back cleanly, delete the HTTPRoute
   (`kubectl -n waha delete httproute waha`) so `legacy-fallback` resumes
   proxying — or simply revert the waha kustomization commit.
3. Scale the legacy WAHA back to `replicas=1`.
4. The legacy NFS data was never written after 2.1, so the session resumes
   cleanly (a WhatsApp reconnect may take a minute).
5. The destination PVCs stay intact for a second attempt.
