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
  - **Talos Secrets**: Files matching `.*\.sops\.yaml$` (such as `infrastructure/kubernetes/talsecret.sops.yaml`) are encrypted using the Age key defined in `.sops.yaml`.
  - **Kubernetes / Flux Secrets**: Files inside `cluster/` **MUST** match the pattern `cluster/.*secret.*\.yaml$` to be recognized and encrypted by SOPS (e.g., `cluster/core/cilium/secret.yaml` or `my-app-secret.yaml`). Ensure your secret file names include `secret` and end in `.yaml`.
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
infrastructure/kubernetes/clusterconfig/kubeconfig
```
**Examples:**
```bash
# Export environment variable
export KUBECONFIG="infrastructure/kubernetes/clusterconfig/kubeconfig"
kubectl get nodes

# Or pass explicitly via CLI flag
kubectl --kubeconfig=infrastructure/kubernetes/clusterconfig/kubeconfig get pods -A
```

### Talos Linux Node Administration (`talosconfig`)
To administer Talos Linux nodes using `talosctl`, always point to:
```bash
infrastructure/kubernetes/clusterconfig/talosconfig
```
**Examples:**
```bash
# Export environment variable
export TALOSCONFIG="infrastructure/kubernetes/clusterconfig/talosconfig"
talosctl health

# Or pass explicitly via CLI flag
talosctl --talosconfig=infrastructure/kubernetes/clusterconfig/talosconfig get nodes
```

---

## 5. Repository Structure Overview

- **`infrastructure/kubernetes/`**: Contains the Talos Linux base node configuration (`talconfig.yaml`, `talsecret.sops.yaml`) processed by `talhelper`.
  - **`clusterconfig/`**: Generated cluster access artifacts (`kubeconfig` and `talosconfig`).
- **`cluster/`**: Contains GitOps definitions managed by **FluxCD** (`cluster/core`, `cluster/apps`, `cluster/base`), utilizing Kustomize and Helm releases.

---

## Summary Checklist for Agents Before Executing Tasks

1. [ ] Are all newly added comments, docstrings, and docs in **English**?
2. [ ] Is any sensitive data or secret file properly named and encrypted with **SOPS/Age**?
3. [ ] Are CLI commands (`kubectl`, `sops`, `talosctl`) executed within the **Nix** environment?
4. [ ] Are explicit `--kubeconfig` or `--talosconfig` paths provided when connecting to the cluster?
