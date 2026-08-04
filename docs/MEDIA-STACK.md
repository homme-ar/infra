# Media Stack Runbook

Operational guide for the media stack: `bazarr`, `jellyfin`, `maintainerr`,
`seerr`, `lidarr`, `prowlarr`, `radarr`, `sabnzbd`, `sonarr` (manifests under
`cluster/apps/media/`).

## Architecture

- **Media library**: lives on the QNAP NAS, mounted over **NFS** (single share, RWX) as
  `/data` in every pod. One static `PersistentVolume` + `PersistentVolumeClaim` (`nas-media`)
  per app namespace, all pointing at the same NFS export (`${NAS_IP}:${NAS_SHARE_PATH}`).
  NFS is used because it is file-level, supports concurrent mounts from all pods, and
  supports hardlinks — which is what makes `*arr` imports instant ("atomic moves").
  SMB (fragile UID mapping, poor hardlink support) and iSCSI (block-level, RWO — a single
  mount point, useless for a shared library) were considered and rejected.
- **App configs / internal databases** (SQLite): Longhorn RWO PVCs (`<app>-config`),
  `strategy: Recreate` to avoid multi-attach errors, same as the other stateful apps.
- **Privilege model**: the LinuxServer images start as root (their s6-overlay init
  requires it) and drop to the unprivileged `abc` user (PUID/PGID 1000) before launching
  the app — do not add `runAsNonRoot` or capability drops to those pods, the init crashes
  without CHOWN/SETUID/SETGID. seerr (non-LSIO image) runs fully non-root.
- **Ingress**: `HTTPRoute` per app on the shared `envoy-gateway`, hostname
  `<app>-apps.${CLUSTER_DOMAIN}` (covered by the existing wildcard DNS + TLS cert).
- **Jellyfin transcode scratch**: `emptyDir` at `/config/data/transcodes` so transient
  segments never touch the Longhorn PVC.

## QNAP one-time setup (manual, outside GitOps)

1. **Control Panel → Network & File Services → Win/Mac/NFS/WebDAV → Linux NFS**: enable
   NFS v4.
2. On the shared folder that holds the media (e.g. `/share/Media`): enable NFS access,
   allow the cluster node IPs (`192.0.2.2`, `192.0.2.3`, `192.0.2.4`), and set the squash
   option to **no_root_squash** (or map all users to a QNAP user with UID/GID 1000).
   All containers run as UID/GID 1000 and the share must allow that user to write.
3. Create the directory layout inside the share (mounted as `/data` in the pods):

   ```
   /data/media/movies
   /data/media/tv
   /data/media/music
   /data/usenet/complete
   /data/usenet/incomplete
   ```

   A single share for media + downloads is deliberate: hardlinks only work within the
   same filesystem, so imports from `usenet/complete` into `media/...` are instant and
   consume no extra space.

4. Set `NAS_IP` and `NAS_SHARE_PATH` in `cluster/cluster-vars.yaml` (they ship as
   `CHANGE_ME` placeholders).

## Authentication (Authelia at the gateway)

`sonarr`, `radarr`, `lidarr`, `prowlarr`, `bazarr` and `sabnzbd` are protected by
**Authelia** via an `ExternalAuth` filter on their HTTPRoutes (same pattern as
headlamp/zigbee2mqtt/waha). Their namespaces are listed in
`cluster/apps/platform/authelia/reference-grant.yaml`. The wildcard access-control rule
(`*.${CLUSTER_DOMAIN}` → `two_factor`) already covers their hostnames, so no Authelia
config change is needed.

`maintainerr` is also protected by Authelia at the gateway (namespace listed in
the same reference grant), but unlike the `*arr` apps it **keeps its built-in
login enabled** — it has no external-auth mode, so after passing Authelia you
still log in with the Maintainerr admin account created on first run.

`jellyfin` and `seerr` keep their own built-in authentication on purpose (they are
user-facing multi-user apps, and Jellyfin clients don't play well with SSO redirects).

### Disabling each app's built-in auth (one-time, in the UI)

The internal login of these apps lives in their config volume (`config.xml` /
`sabnzbd.ini`), which only exists after first boot — so it cannot be seeded from GitOps.
Do this once per app after the first login:

- **sonarr / radarr / lidarr / prowlarr**: Settings → General → Security →
  *Authentication Method* = **External** (the app trusts the gateway for auth and skips
  its own login form).
- **bazarr**: Settings → General → Security → *Authentication* = **Disabled**.
- **sabnzbd**: leave the username/password fields empty (Config → General) — with no
  credentials set, no login is required.

Note: inter-app traffic is unaffected either way — the `*arr` apps talk to each other and
to sabnzbd over in-cluster service URLs (e.g. `http://sonarr.sonarr.svc.cluster.local`),
which never traverse the gateway. Only browser access via `*-apps.${CLUSTER_DOMAIN}` goes
through Authelia. External API clients that hit the public hostnames (mobile apps like
nzb360) would need to authenticate through Authelia's `HeaderAuthorization` strategy
(Basic/Bearer), which is enabled on the ext-authz endpoint.

## Wiring the apps together (post-deploy, in each UI)

Because every pod mounts the same `/data`, **no remote path mappings are needed** anywhere.

- **sabnzbd**: set "Completed Download Folder" to `/data/usenet/complete` and
  "Temporary Download Folder" to `/data/usenet/incomplete`.
- **prowlarr**: add indexers, then use "Sync Apps" to push them to
  sonarr/radarr/lidarr/bazarr (app URLs are the in-cluster services, e.g.
  `http://sonarr.sonarr.svc.cluster.local`).
- **sonarr / radarr / lidarr**:
  - Download client: sabnzbd at `http://sabnzbd.sabnzbd.svc.cluster.local`, category per app.
  - Root folders: `/data/media/tv`, `/data/media/movies`, `/data/media/music` respectively.
  - Enable "Use Hardlinks instead of Copy" (Settings → Media Management) — works because
    downloads and library share one filesystem.
- **bazarr**: point it at sonarr/radarr; subtitle paths follow the same `/data/media/...` roots.
- **jellyfin**: libraries at `/data/media/movies`, `/data/media/tv`, `/data/media/music`.
  Its mount is read-only; metadata is stored in its Longhorn config PVC.
- **seerr**: connect to Jellyfin, then link sonarr/radarr for request fulfillment.
- **maintainerr**: on first login create the admin account, then connect the
  services with their in-cluster URLs — Jellyfin
  (`http://jellyfin.jellyfin.svc.cluster.local`, API key from Jellyfin →
  Dashboard → API Keys), sonarr/radarr (`http://sonarr.sonarr.svc.cluster.local`
  / `http://radarr.radarr.svc.cluster.local`) and optionally seerr
  (`http://seerr.seerr.svc.cluster.local`). It mounts no media share: deletions
  are executed through the sonarr/radarr APIs.

### Verifying hardlinks work

After an import completes, exec into any `*arr` pod and compare inode link counts:

```bash
kubectl exec -n sonarr deploy/sonarr -- ls -li /data/usenet/complete/<release>/
kubectl exec -n sonarr deploy/sonarr -- ls -li /data/media/tv/<series>/
```

Identical inode numbers with a link count > 1 mean the import was a hardlink, not a copy.

## Jellyfin hardware transcoding (NVIDIA NVENC)

Jellyfin transcodes on the RTX A2000 in `ser-msa2cp1`. The pod requests
`nvidia.com/gpu: 1` and runs with `runtimeClassName: nvidia` (driver libraries
are injected by the Talos `nvidia-container-toolkit` extension), and
`NVIDIA_DRIVER_CAPABILITIES=all` exposes the video engines (NVENC/NVDEC) to
ffmpeg. The device plugin is configured with time-slicing (`replicas: 10` in
`cluster/infrastructure/nvidia-device-plugin/release.yaml`), so other GPU
workloads (e.g. subgen) can share the card — there is no VRAM isolation, so
keep the total under the card's 12GB.

One-time setup in the UI (lives in `encoding.xml` on the config PVC, which
Jellyfin rewrites — it cannot be managed from GitOps):

1. Dashboard → Playback → Transcoding → **Hardware acceleration: NVIDIA NVENC**.
2. Enable hardware decoding for H.264, HEVC, VP9 and AV1 (the A2000 decodes AV1;
   it does NOT encode AV1 — AV1 encode requires an Ada Lovelace GPU).
3. Enable HEVC encoding.
4. Enable hardware tone mapping (HDR → SDR) — runs entirely on-GPU.

Verify: start a playback that requires transcoding — the Dashboard shows the
stream transcoding via NVENC, and `nvidia-smi` inside the pod (available because
of the injected driver utilities) lists the ffmpeg process:

```bash
kubectl exec -n jellyfin deploy/jellyfin -- nvidia-smi
```

## Upgrade procedure

Images are pinned (e.g. `lscr.io/linuxserver/sonarr:4.0.19`). To upgrade: bump the tag in
`cluster/apps/media/<app>/deployment.yaml`, commit, push, and reconcile:

```bash
flux --kubeconfig=talos/clusterconfig/kubeconfig reconcile kustomization cluster-apps -n flux-system
```

## Future work (deliberately out of scope)

- **subgen** (whisper-based subtitle generation): should request
  `nvidia.com/gpu: 1` and set `runtimeClassName: nvidia` — the device plugin
  time-slices the A2000 across up to 10 pods.
