# Homelab Kubernetes Infrastructure

This repository hosts the Infrastructure-as-Code (IaC) and GitOps configuration

## Development Environment

This repository uses [Nix Flakes](https://nixos.wiki/wiki/Flakes) and [direnv](https://direnv.net/) to provide a reproducible, zero-configuration development environment with all required CLI tools.

### Available Tools

When entering the repository with `direnv` enabled, the following binaries are automatically provisioned:

- **Kubernetes & GitOps**: `kubectl`, `k9s`, `helm` (`kubernetes-helm`), `kustomize`, `flux`, `flux9s`
- **Talos Linux**: `talosctl`, `talhelper`
- **Secrets Management**: `sops`, `age`
- **Processing Utilities**: `yq`, `jq`

### Usage

#### With `direnv` (Recommended)
Allow the directory once:
```bash
direnv allow
```
The development shell and tools will automatically load whenever you `cd` into this directory.

#### Manual Nix Shell
If you do not use `direnv`, you can enter the development shell manually:
```bash
nix develop
```
