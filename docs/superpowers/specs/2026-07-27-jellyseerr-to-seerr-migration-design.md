# Design: Migrate Jellyseerr to Seerr

Date: 2026-07-27
Status: Approved (design)

## Context

Jellyseerr and Overseerr merged into the **Seerr** project (`seerr-team/seerr`). The
upstream [migration guide](https://docs.seerr.dev/migration-guide/) states the data
migration runs automatically on the first boot of the Seerr image against an existing
Jellyseerr `/app/config` directory, and mandates a backup before starting.

Current deployment: `cluster/apps/media/jellyseerr/`, image
`docker.io/fallenbagel/jellyseerr:2.7.3`, namespace `jellyseerr`, RWO Longhorn PVC
`jellyseerr-config` (2Gi, backed up to NAS), hostname
`jellyseerr-apps.${CLUSTER_DOMAIN}`, homepage discovery annotations with widget type
`jellyseerr` and key `{{HOMEPAGE_VAR_JELLYSEERR_API_KEY}}`.

## Decisions (from brainstorming)

- **Scope**: full rename to `seerr` (directory, namespace, Service, PVC, hostname).
- **Data**: copy the old volume into a new PVC with a temporary one-shot Job; the old
  volume stays untouched as rollback until the migration is verified.
- **Hostname**: only `seerr-apps.${CLUSTER_DOMAIN}`; the old hostname dies with the old
  namespace. External consumers (JellyWatch app, bookmarks) are updated by the user.
- **Cutover**: staged in 3 commits so Seerr never boots against an empty config dir.
- **Image**: `ghcr.io/seerr-team/seerr:v3.3.0` (latest stable, pinned per repo
  convention; Renovate takes over afterwards).

## New manifests — `cluster/apps/media/seerr/`

Same layout and conventions as the current app (one resource per file, each resource
declares its namespace inline, no top-level `namespace:` in the kustomization):

- `namespace.yaml` — Namespace `seerr`.
- `pvc-config.yaml` — PVC `seerr-config`, 2Gi, `${STORAGE_CLASS}`, labels
  `app.kubernetes.io/name: seerr`, `app.kubernetes.io/component: storage`, and
  `recurring-job-group.longhorn.io/backup: enabled`.
- `deployment.yaml` — Deployment `seerr`, image `ghcr.io/seerr-team/seerr:v3.3.0`,
  `imagePullPolicy: IfNotPresent`, `strategy: Recreate`. The existing pod/container
  securityContext is kept as-is: `runAsUser/runAsGroup/fsGroup 1000` already matches
  the Seerr image's `node` user (UID 1000). Same resources, TZ env, and probes
  (`/api/v1/status` still exists in Seerr).
- `service.yaml` — ClusterIP Service `seerr`, port 80 → `http` (5055).
- `httproute.yaml` — hostname `seerr-apps.${CLUSTER_DOMAIN}` on the `envoy-gateway`;
  homepage annotations renamed: `gethomepage.dev/name: Seerr`,
  `gethomepage.dev/icon: seerr.png`, `gethomepage.dev/widget.type: seerr`,
  `gethomepage.dev/widget.url: http://seerr.seerr`,
  `gethomepage.dev/widget.key: "{{HOMEPAGE_VAR_SEERR_API_KEY}}"`.
- `kustomization.yaml` — lists the five files above.

`cluster/apps/media/kustomization.yaml` gains a `seerr` entry (alphabetical).

## Data migration (manual, outside Flux)

The copy Job is **not committed** to the repo; it is applied from a temporary YAML and
deleted afterwards. Steps:

1. Pre-check: confirm a recent Longhorn backup of the `jellyseerr-config` volume
   exists (recurring job to the QNAP NAS), per the upstream guide's backup mandate.
2. `flux suspend kustomization cluster-apps -n flux-system` — otherwise Flux reverts
   the next step (the Deployment pins `replicas: 1`).
3. `kubectl -n jellyseerr scale deploy/jellyseerr --replicas=0` and wait for the pod
   to terminate (RWO volume must be detached; also avoids SQLite writes mid-copy).
4. Apply the copy Job: alpine image, mounts `jellyseerr-config` read-only at `/old`
   and `seerr-config` at `/new`, runs `cp -a /old/. /new/` and
   `chown -R 1000:1000 /new`.
5. Verify the copy (file listing, `settings.json` present), then delete the Job.

## Cutover — 3 commits

1. **Commit 1** — `cluster/apps/media/seerr/` containing only `namespace.yaml`,
   `pvc-config.yaml`, `kustomization.yaml`, plus the `seerr` entry in
   `cluster/apps/media/kustomization.yaml`. Flux provisions the empty PVC.
2. Manual data-migration steps above.
3. **Commit 2** — add `deployment.yaml`, `service.yaml`, `httproute.yaml` to the seerr
   kustomization; rename `HOMEPAGE_VAR_JELLYSEERR_API_KEY` →
   `HOMEPAGE_VAR_SEERR_API_KEY` in `cluster/apps/platform/homepage/secret.yaml`
   (same value, edited with `sops`; the API key survives the automatic migration);
   update Renovate `cluster/infrastructure/renovate/release.yaml`
   (`matchFileNames: ['cluster/apps/media/seerr/**']`, `groupName`/`groupSlug:
   seerr`); update `docs/MEDIA-STACK.md` and `AGENTS.md` jellyseerr references.
   `flux resume kustomization cluster-apps -n flux-system` and reconcile — Seerr boots
   on the copied data and runs the automatic migration.
4. **Commit 3** (only after verification) — delete `cluster/apps/media/jellyseerr/`
   and its entry in the parent kustomization. Flux prunes the namespace, PVC and the
   old Longhorn volume (reclaim policy Delete).

## Verification

- `kustomize build cluster/apps/media/seerr` renders cleanly before each commit.
- After commit 2: pod Running, first-boot logs show the migration, login and all
  settings intact (Jellyfin, Sonarr/Radarr, users, requests), homepage widget works
  (restart the homepage pod per AGENTS.md after the secret rename),
  `https://seerr-apps.homme.ar` responds.

## Rollback

Any time before commit 3: the old namespace, PVC and volume are untouched. Scale
`jellyseerr` back to 1 (resume Flux) and delete the `seerr` namespace/PVC.

## Out of scope

- Updating external consumers of the old public URL (JellyWatch, bookmarks).
- Reconfiguring Sonarr/Radarr — Seerr connects to them, not the other way around, and
  that config lives in the migrated `/app/config`.
