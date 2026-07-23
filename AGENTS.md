# AI Agent & Developer Guidelines (agents.md)

Welcome to the **Homme Kubernetes Infrastructure** (`homme-ar/infra`) repository. 
This document specifies **critical mandatory rules and operational standards** for all AI agents, assistants, and developers contributing to this project. Any automated or manual modification to this codebase MUST strictly adhere to these guidelines.

---

## 1. Language Requirements: English Only

- **All Documentation & Comments**: Every comment (`#`, `//`), docstring, commit message, pull request description, and markdown document MUST be written strictly in **English**.
- **No Local Languages**: Do not use Spanish or any other language in code files, configuration files, or documentation.

---

## 2. Public Repository Security & SOPS Encryption

> [!CAUTION]
> **This repository is public on GitHub.** Exposing plain-text secrets, API tokens, passwords, or private keys is a critical security violation.

- **Never Commit Plain-Text Secrets**: Before creating or modifying any file containing sensitive data (passwords, certificates, keys, webhooks, or tokens), verify that it is properly encrypted using **SOPS** (`sops`) with **Age** (`age`).
  - **SOPS Configuration (`.sops.yaml`) Rules**:
  - **Talos Secrets**: Files matching `.*\.sops\.yaml$` (such as `talos/talsecret.sops.yaml`) are encrypted using the Age key defined in `.sops.yaml`.
  - **Kubernetes / Flux Secrets**: Files inside `cluster/` **MUST** match the pattern `cluster/.*secret.*\.yaml$` to be recognized and encrypted by SOPS (e.g., `cluster/infrastructure/security/cert-manager/secret.yaml` or `my-app-secret.yaml`). Ensure your secret file names include `secret` and end in `.yaml`.
  - **NixOS Host Secrets**: Files inside `nixos/secrets/` matching `nixos/secrets/.*\.yaml$` (e.g., the comin GitHub deploy key in `secrets.yaml`). Per-host Age keys are added as recipients when host-consumed (sops-nix) secrets are introduced.
- **Age Key Location**: As configured in `.envrc`, the local SOPS Age private key path is set via `export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt`.

---

## 3. Nix & Direnv Development Environment

This repository uses **Nix Flakes** (`flake.nix`) and **direnv** (`.envrc`) to guarantee a reproducible environment with pinned tool versions (`kubectl`, `talosctl`, `talhelper`, `sops`, `age`, `fluxcd`, `k9s`, `kubernetes-helm`, `kustomize`, `yq`, `jq`).

- **Execute Commands Within Nix**: All CLI commands MUST be executed using the tools provided by the Nix environment.
  - If `direnv` is loaded and active in your shell session, the binaries are directly in your `$PATH`.
  - If running outside of an active `direnv` shell or when executing background subshells, ensure commands run within the Nix environment using `nix develop --command <command>` (or verify the Nix `$PATH` is preserved).
- **Do Not Rely on System Binaries**: Avoid using global system-installed tools that might differ in version or behavior from the dependencies defined in `flake.nix`.

---

## 4. Cluster & Talos Access Configuration

When running commands to interact with the live cluster or nodes, you **MUST explicitly reference the cluster configuration files** stored in the repository:

### Kubernetes Cluster Access (`kubeconfig`)
To interact with Kubernetes using `kubectl`, `helm`, `flux`, or `k9s`, always point to:
```bash
talos/clusterconfig/kubeconfig
```
**Examples:**
```bash
# Export environment variable
export KUBECONFIG="talos/clusterconfig/kubeconfig"
kubectl get nodes

# Or pass explicitly via CLI flag
kubectl --kubeconfig=talos/clusterconfig/kubeconfig get pods -A
```

### Talos Linux Node Administration (`talosconfig`)
To administer Talos Linux nodes using `talosctl`, always point to:
```bash
talos/clusterconfig/talosconfig
```
**Examples:**
```bash
# Export environment variable
export TALOSCONFIG="talos/clusterconfig/talosconfig"
talosctl health

# Or pass explicitly via CLI flag
talosctl --talosconfig=talos/clusterconfig/talosconfig get nodes
```

---

## 5. GitOps & FluxCD Enforcement (No Direct Applications)

> [!IMPORTANT]
> **Strict GitOps Workflow**: This cluster is fully managed by **FluxCD**. Direct imperative mutations to the cluster state are forbidden.

- **No Imperative Cluster Mutations (`kubectl apply`)**: Agents and developers MUST NEVER apply manifests or Helm charts directly to the cluster (e.g., `kubectl apply -f ...`, `kubectl create ...`, `kubectl edit ...`, `kubectl patch ...`, `helm install ...`, `helm upgrade ...`) unless explicitly instructed by the user for temporary/emergency debugging.
- **Declarative Changes via GitOps**: All Kubernetes resources, configurations, and application deployments MUST be modified declaratively inside the `cluster/` directory (`cluster/core`, `cluster/apps`, `cluster/base`).
- **Triggering & Testing Changes via Flux Reconcile**: To apply or sync changes to the live cluster after modifying manifests or pushing commits to Git, agents MUST use FluxCD reconciliation commands (`flux reconcile`):
  ```bash
  # Reconcile Git source repository
  flux --kubeconfig=talos/clusterconfig/kubeconfig reconcile source git flux-system -n flux-system

  # Reconcile specific Kustomization
  flux --kubeconfig=talos/clusterconfig/kubeconfig reconcile kustomization <kustomization-name> -n <namespace>

  # Reconcile specific HelmRelease
  flux --kubeconfig=talos/clusterconfig/kubeconfig reconcile helmrelease <release-name> -n <namespace>
  ```

---

## 6. Repository Structure Overview

- **`talos/`**: Contains the Talos Linux base node configuration (`talconfig.yaml`, `talsecret.sops.yaml`) processed by `talhelper`.
  - **`clusterconfig/`**: Generated cluster access artifacts (`kubeconfig` and `talosconfig`).
- **`cluster/`**: Contains GitOps definitions managed by **FluxCD**, utilizing Kustomize and Helm releases.
  - **`flux-system/`**: Flux bootstrap components and sync configuration.
  - **`infrastructure/`**: Core cluster infrastructure (`networking/`, `security/`, `storage/`).
  - **`apps/`**: Application workloads (`platform/`, `legacy/`).
- **`nixos/`**: Contains a standalone Nix Flake with NixOS configurations for the auxiliary Raspberry Pi 4 hosts, deployed via **comin** (pull-based GitOps: each host polls this repository and switches to the `nixosConfigurations` output matching its hostname). The flake lives in this subdirectory, referenced by comin through `services.comin.repositorySubdir = "nixos"`. While the repository is private, comin authenticates with a shared read-only GitHub deploy key stored sops-encrypted in `nixos/secrets/secrets.yaml` and baked into the SD images at build time (impure build, never committed in plain text); the GitHub SSH host key is pinned declaratively in `nixos/modules/common`.
  - **`hosts/`**: Per-host entry points (`ntp` for the GPS-disciplined NTP stratum 1 server, `dns` for the AdGuard Home DNS server).
  - **`modules/`**: Shared and per-service modules (`common`, `chrony-gps`, `adguard`).
  - **`secrets/`**: SOPS-encrypted host secrets (comin deploy key, future sops-nix secrets).
  - SD card images for initial provisioning: `nix build ./nixos#sd-image-<hostname>` (requires an aarch64 builder or binfmt emulation, plus `--impure` with `NIXOS_COMIN_DEPLOY_KEY` pointing to the decrypted deploy key — see the comments in `nixos/flake.nix`).
  - Host secrets use **sops-nix** with a per-host Age key stored on each device at `/var/lib/sops-nix/key.txt`; host public keys must be added as recipients in the root `.sops.yaml`.

---

## Summary Checklist for Agents Before Executing Tasks

1. [ ] Are all newly added comments, docstrings, and docs in **English**?
2. [ ] Is any sensitive data or secret file properly named and encrypted with **SOPS/Age**?
3. [ ] Are CLI commands (`kubectl`, `sops`, `talosctl`) executed within the **Nix** environment?
4. [ ] Are explicit `--kubeconfig` or `--talosconfig` paths provided when connecting to the cluster?
5. [ ] Are cluster changes managed declaratively via **GitOps / FluxCD (`flux reconcile`)** rather than direct `kubectl apply` commands?
