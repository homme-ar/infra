# AGENTS.md — Homme Kubernetes Infrastructure (`homme-ar/infra`)

This file is the entry point for AI coding agents working in this repository. It assumes no prior knowledge of the project.

## Project Overview

This is **not an application codebase** — it is an Infrastructure-as-Code / GitOps repository for a homelab. There is no compiled code, no test suite, and no package manifest (`package.json`, `pyproject.toml`, etc.). The "build" is configuration generation (Nix, talhelper, Kustomize) and the "deployment" is reconciliation by FluxCD.

The repository manages three distinct things:

1. **A 3-node Kubernetes cluster** running on Talos Linux (`homme-cluster`), defined in `talos/` and `cluster/`.
2. **Two auxiliary NixOS hosts** (Raspberry Pi 4: an NTP server and a DNS server), defined as a standalone Nix flake in `nixos/`.
3. **A reproducible dev environment** (Nix flake + direnv) providing all CLI tools, defined in the root `flake.nix`.

### Hardware & topology

- **Kubernetes nodes**: 3 × Minisforum MS-A2 (`ser-msa2cp1` `10.0.20.2`, `ser-msa2cp2` `10.0.20.3`, `ser-msa2cp3` `10.0.20.4`), all control-plane, with a shared VIP `10.0.20.1` (API endpoint `https://10.0.20.1:6443`). Scheduling on control planes is allowed.
- **Versions**: Talos `v1.13.6`, Kubernetes `v1.36.0` (pinned in `talos/talconfig.yaml`).
- **Auxiliary hosts**: `ser-ntp1` (GPS-disciplined NTP stratum 1 via chrony) and `ser-dns1` (AdGuard Home), both Raspberry Pi 4 running NixOS (see `nixos/`).

## Repository Layout

```
├── flake.nix              # Root dev-shell flake (dev tools only, NOT the NixOS configs)
├── .envrc                 # direnv: `use flake` + SOPS_AGE_KEY_FILE
├── .sops.yaml             # SOPS encryption rules (Age recipients per path pattern)
├── talos/                 # Talos Linux cluster definition (talhelper)
│   ├── talconfig.yaml     #   Main cluster config: nodes, VIP, patches, versions
│   ├── talsecret.sops.yaml#   SOPS-encrypted cluster PKI/secrets
│   ├── patches/           #   Talos machine patches (global/, nodes/)
│   └── clusterconfig/     #   Generated: kubeconfig, talosconfig, node manifests
├── cluster/               # FluxCD GitOps state (the live cluster reconciles from here)
│   ├── flux-system/       #   Flux bootstrap + Kustomizations that drive everything
│   ├── cluster-vars.yaml  #   ConfigMap for Flux post-build variable substitution
│   ├── infrastructure/    #   networking/, security/, storage/, observability/
│   └── apps/              #   platform/, iot/, media/
├── nixos/                 # Standalone Nix flake: NixOS configs for the RPi4 hosts
│   ├── flake.nix          #   Own inputs (nixpkgs nixos-26.05, comin, sops-nix, ...)
│   ├── hosts/             #   Per-host entry points: ser-ntp1/, ser-dns1/
│   ├── modules/           #   Shared modules: common/, chrony-gps/, adguard/
│   ├── pkgs/              #   Custom packages not in nixpkgs (gpsd-prometheus-exporter)
│   └── secrets/           #   SOPS-encrypted host secrets (comin deploy key, ...)
├── scripts/               # Helper CLI scripts (added to PATH by the dev shell)
│   ├── wireguard-config   #   Print a WireGuard peer config from the cluster secret
│   └── wireguard-qrcode   #   Render a peer config as a QR code
└── docs/                  # Operational runbooks (bootstrap, backups, migrations, upgrades)
```

## Technology Stack

- **Node OS**: Talos Linux, configured via `talhelper` from `talos/talconfig.yaml`. CNI is disabled in Talos (`cniConfig.name: none`) and kube-proxy is disabled; Cilium replaces both.
- **GitOps engine**: FluxCD. The cluster syncs from `ssh://git@github.com/homme-ar/infra.git` branch `main` (see `cluster/flux-system/gotk-sync.yaml`). This is a **public repository** — see Security.
- **CNI / networking**: Cilium (HelmRelease, kube-proxy replacement, L2 announcements, Hubble) + Gateway API (`gatewayClassName: cilium`, central `Gateway` named `envoy-gateway` in `kube-system`, TLS terminated with the `${CLUSTER_DOMAIN_SLUG}-tls` cert). Apps expose HTTP via `HTTPRoute` resources, not Ingress.
- **Storage**: Longhorn (default `${STORAGE_CLASS}` = `longhorn`; `longhorn-singlenode` single-replica class for databases). A dedicated Kingston NVMe disk per node is reserved for Longhorn (see `talos/patches/global/storage.yaml`).
- **Databases**: CloudNativePG (CNPG) operator; per-app `Cluster`/database manifests live in `cluster/apps/platform/postgres/`.
- **Secrets**: SOPS + Age. Flux decrypts at reconcile time via the `sops-age` secret (`decryption.provider: sops` on the Kustomizations).
- **TLS**: cert-manager with Let's Encrypt (Cloudflare DNS-01), issuers in `cluster/infrastructure/security/cert-manager-config/`.
- **Observability**: kube-prometheus-stack, metrics-server, node-feature-discovery, Gatus (`observability/gatus`, status page at `status.${CLUSTER_DOMAIN}`, alerts to the in-cluster NTFY `uptime` topic — token in the SOPS-encrypted `gatus-ntfy` secret, interpolated into the Gatus config as `${NTFY_TOKEN}`; the placeholder lives in the `gatus-values` secret consumed via `valuesFrom` because Flux post-build substitution runs in strict mode and would fail on it inline), a Prometheus Pushgateway (`observability/pushgateway`) that receives `renovate-metrics` from the Renovate CronJob (its logs are piped through the binary via an initContainer/shared volume), plus ServiceMonitors for cilium/cnpg/flux/longhorn/adguard/pushgateway.
- **VPN**: WireGuard via the wireguard-operator (CRs in `cluster/infrastructure/networking/wireguard/instance/`, one `WireguardPeer` per device).
- **Dependency updates**: Renovate self-hosted (CronJob via the official Helm chart in `cluster/infrastructure/renovate/`, hourly) opens PRs against `main` with Helm chart and container image updates. Authenticates to GitHub with a fine-grained PAT (in the SOPS-encrypted `renovate-github-token` secret). Updates are grouped into one PR per project (leaf directory) via `packageRules` in the HelmRelease values — when adding a new app/component directory, add a matching `matchFileNames` rule there.
- **Auxiliary hosts**: NixOS (aarch64) managed by **comin** (pull-based GitOps — each host polls this repo and switches to the `nixosConfigurations` output matching its hostname).

## Build & Run Commands

All CLI tools come from the Nix dev shell. **Always run commands inside it**: either with direnv active (`direnv allow` once, then tools are on `PATH`) or via `nix develop --command <cmd>`. Do not rely on system-installed versions of `kubectl`, `talosctl`, `flux`, `sops`, etc. The dev shell also prepends `scripts/` to `PATH`.

### Cluster access (always pass explicit config paths)

```bash
export KUBECONFIG="talos/clusterconfig/kubeconfig"    # kubectl / helm / flux / k9s
export TALOSCONFIG="talos/clusterconfig/talosconfig"  # talosctl
kubectl get nodes
talosctl health
```

### Talos (node-level) workflow

```bash
# Regenerate node manifests + talosconfig after editing talconfig.yaml
talhelper genconfig                 # decrypts talsecret.sops.yaml in memory

# Regenerate cluster secrets (only when rotating/bootstrapping anew)
talhelper gensecret | sops --encrypt --filename-override talsecret.sops.yaml /dev/stdin > talos/talsecret.sops.yaml

# Apply config to a node / bootstrap etcd (see docs/BOOTSTRAP.md for the full runbook)
talosctl apply-config --insecure --nodes <node-ip> --file talos/clusterconfig/homme-cluster-<hostname>.yaml
talosctl bootstrap --nodes 10.0.20.2 --endpoints 10.0.20.2
```

### GitOps workflow (the ONLY way to change cluster state)

**Never** use `kubectl apply/create/edit/patch` or `helm install/upgrade` against the cluster. All changes are made declaratively under `cluster/` and committed to git; Flux reconciles them. To force a sync after pushing:

```bash
flux --kubeconfig=talos/clusterconfig/kubeconfig reconcile source git flux-system -n flux-system
flux --kubeconfig=talos/clusterconfig/kubeconfig reconcile kustomization <name> -n <namespace>
flux --kubeconfig=talos/clusterconfig/kubeconfig reconcile helmrelease <name> -n <namespace>
```

To validate manifests locally before committing, render them with Kustomize (client-side only):

```bash
kustomize build cluster/apps/platform/n8n
```

### NixOS auxiliary hosts (`nixos/` flake)

```bash
# Build an SD image for initial provisioning (impure; needs the decrypted comin
# deploy key and an aarch64 builder or binfmt emulation)
sops -d --extract '["comin_deploy_key"]' nixos/secrets/secrets.yaml > /tmp/comin_deploy_key
chmod 644 /tmp/comin_deploy_key
NIXOS_COMIN_DEPLOY_KEY=/tmp/comin_deploy_key nix build --impure --option sandbox false ./nixos#packages.aarch64-linux.sd-image-ser-ntp1   # or sd-image-ser-dns1
# (the full `packages.aarch64-linux.` path is required on x86_64 build machines)
shred -u /tmp/comin_deploy_key
zstd -d result/sd-image/*.img.zst -o rpi.img   # then flash to SD

# Check the flake evaluates (fast sanity check for Nix edits)
nix flake check ./nixos --no-build   # or: nix eval ./nixos#nixosConfigurations.ser-ntp1.config.system.build.toplevel.drvPath
```

After first boot, hosts self-update via comin — changes are deployed by committing to this repo, not by SSHing in.

### WireGuard helpers

```bash
wireguard-config <peer>        # print a peer's config (from the vpn-peer-configs secret)
wireguard-qrcode <peer>        # same, rendered as a QR code
```

## Testing & Validation

There is **no automated test suite**. Validation is:

1. **Render locally**: `kustomize build <dir>` for Kubernetes manifests; `nix flake check`/`nix eval` for the `nixos/` flake.
2. **Secret hygiene**: before committing, confirm new secret files match a `.sops.yaml` pattern and are actually encrypted (`sops` metadata present in the file).
3. **Reconcile and observe**: after pushing, `flux reconcile ...` then check `flux get kustomizations -A`, `kubectl get pods -A`, and the app's HTTPRoute/Gateway status.

## Code & Config Conventions

- **Language**: everything (comments, docs, commit messages) is in **English only**.
- **Manifest style**: plain YAML, two-space indent, one resource per file named after the kind (`deployment.yaml`, `service.yaml`, `httproute.yaml`, `pvc-<name>.yaml`, `namespace.yaml`, `kustomization.yaml`). Each app is a directory with its own namespace and a `kustomization.yaml` listing its files; parent directories aggregate children the same way.
- **Labels**: `app.kubernetes.io/name` (plus `app.kubernetes.io/component` where useful).
- **Images**: pinned to explicit versions (e.g. `n8nio/n8n:2.25.5`), `imagePullPolicy: IfNotPresent`.
- **Pods**: non-root `securityContext`, dropped capabilities, resource requests/limits, liveness/readiness probes. Stateful apps use `strategy: Recreate` with RWO Longhorn PVCs to avoid multi-attach errors.
- **Helm apps**: a `repository.yaml` (HelmRepository) + `release.yaml` (HelmRelease) pair per component; plain-manifest apps use Deployments directly.
- **Variable substitution**: cluster-wide values (domain `homme.ar`, LB IPs, storage classes) live in `cluster/cluster-vars.yaml` and are referenced as `${VARIABLE_NAME}`; every Flux Kustomization has `postBuild.substituteFrom` pointing at that ConfigMap. Use these variables instead of hardcoding IPs/domains.
- **Flux ordering**: `gotk-sync.yaml` defines dedicated Kustomizations with `dependsOn`/`healthChecks` where CRDs must exist first (cert-manager-config after cert-manager, CNPG clusters after the operator, WireGuard CRs after wireguard-operator, ServiceMonitors after kube-prometheus-stack, all apps after infrastructure). When adding an operator + its CRs, follow this same two-phase pattern.
- **Backups**: the full policy lives in `docs/BACKUPS.md`. Longhorn volumes are backed up to the QNAP NAS **only if their PVC carries the label `recurring-job-group.longhorn.io/backup: enabled`** — add it to every new app PVC that should be backed up (exceptions: CNPG volumes, which use CNPG `barmanObjectStore` backups via the in-cluster Versity Gateway, and regenerable caches). etcd snapshots are taken daily by the `etcd-backup` CronJob (namespace `backup`).
- **Homepage config**: the dashboard (`cluster/apps/platform/homepage/`) mounts its ConfigMap files via `subPath`, so Flux updates do **not** hot-reload. After changing anything in `configmap.yaml` (settings, widgets, bookmarks, discovery mode), restart the pod once the sync lands: `kubectl -n homepage rollout restart deploy/homepage`. Widget credentials live in the SOPS-encrypted `secret.yaml` (edit with `sops`), injected via `envFrom` and referenced as `{{HOMEPAGE_VAR_*}}` — env substitution works both in `services.yaml` and in `gethomepage.dev/widget.*` discovery annotations. Two rules for that secret: keep it **comment-free** (sops 3.13 encrypts YAML comments and Flux cannot decrypt `type:comment` entries) and encrypt **only `stringData`** (`sops --encrypt --encrypted-regex '^(data|stringData)$'` — the `namespace:` field in the kustomization makes kyaml re-serialize the doc and mangle fully-encrypted metadata). Where to get each key: `JELLYFIN` (Dashboard → API Keys), `SEERR`/`SONARR`/`RADARR`/`LIDARR`/`BAZARR`/`PROWLARR`/`SABNZBD` (Settings → General → API Key), `HA_TOKEN` (HA profile → Long-lived access tokens), `UNIFI` (local read-only admin account), `ADGUARD` (web UI login), `QNAP` (QTS user), `GRAFANA_USERNAME`/`GRAFANA_PASSWORD` (copied from the `grafana-admin` secret in the `observability` namespace; the grafana widget uses basic auth, not a token).
- **Docs**: operational procedures go in `docs/` as Markdown runbooks (see `BOOTSTRAP.md`, `BACKUPS.md`, `MEDIA-STACK.md`).

## Security Considerations

- **This repository is public on GitHub.** Never commit plain-text secrets, tokens, private keys, or certs.
- **SOPS + Age rules** (`.sops.yaml`) — a secret file must match one of these patterns or it will NOT be encrypted:
  - `.*\.sops\.yaml$` — Talos secrets (e.g. `talos/talsecret.sops.yaml`)
  - `cluster/.*secret.*\.yaml$` — any Kubernetes/Flux secret under `cluster/` (filename must contain `secret` and end in `.yaml`, e.g. `secret.yaml`, `grafana-admin-secret.sops.yaml`)
  - `nixos/secrets/.*\.yaml$` — NixOS host secrets (comin deploy key; per-host Age keys are added as recipients when sops-nix host secrets are introduced)
- The local Age private key is expected at `$HOME/.config/sops/age/keys.txt` (exported by `.envrc`). Edit encrypted files with `sops <file>`; encrypt new ones with `sops --encrypt --in-place <file>`.
- The comin GitHub deploy key is read from a local decrypted file only during impure SD-image builds (`NIXOS_COMIN_DEPLOY_KEY`); it never enters the Nix store or the repo in plain text. Delete the decrypted copy with `shred -u` after building.
- `.gitignore` already excludes `*.key`, `*.pem`, `*.decrypted.*` — keep it that way.

## Agent Checklist Before Executing a Task

1. All comments/docs in **English**.
2. New secret files match a `.sops.yaml` pattern and are SOPS-encrypted.
3. Commands run inside the **Nix dev shell** (`direnv` or `nix develop --command`).
4. Cluster commands use explicit `--kubeconfig talos/clusterconfig/kubeconfig` / `--talosconfig talos/clusterconfig/talosconfig`.
5. Cluster changes are **declarative in `cluster/` + Flux reconcile** — never imperative `kubectl apply`/`helm install` (except explicitly authorized emergency debugging).
6. New manifests use `${VARIABLES}` from `cluster/cluster-vars.yaml` where applicable and follow the one-resource-per-file + kustomization convention.
