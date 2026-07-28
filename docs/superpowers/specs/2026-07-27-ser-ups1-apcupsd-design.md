# Design: `ser-ups1` — Raspberry Pi 3 apcupsd host

Date: 2026-07-27
Status: approved (design)

## Goal

Add a third auxiliary NixOS host, `ser-ups1`, running on a Raspberry Pi 3. It
monitors an APC Smart-UPS SRT2200XLI connected via USB using `apcupsd`, and
exposes the daemon's NIS (Network Information Server) on TCP port 3551 so that
Home Assistant (running in the Kubernetes cluster, apcupsd integration) can
consume UPS status. A Prometheus exporter exposes the same metrics for the
cluster observability stack.

## Decisions (from brainstorming)

- **Daemon**: `apcupsd` (nixpkgs `services.apcupsd`), not NUT. User's explicit
  choice; the HA apcupsd integration speaks NIS on port 3551.
- **Networking**: DHCP with a reservation on the router (same as the current
  state of ser-ntp1/ser-dns1). No static-IP block in the host file.
- **Metrics**: `services.prometheus.exporters.apcupsd` enabled (default port
  9162), in addition to the node-exporter already provided by `modules/common`.
- **Firewall**: ports 3551 and 9162 allowed only from `10.0.20.0/24`
  (Kubernetes nodes — HA pod egress is masqueraded to the node IP) and
  `10.0.70.0/24` (office network), via `networking.firewall.extraCommands`,
  matching the existing exporter pattern in `modules/common`.
- **Hardware approach (A)**: parameterize the nixos-hardware module in
  `mkHost`; extract the Pi-4-specific initrd workaround out of
  `modules/common` into a Pi-4-only module.

## Architecture

```
SRT2200XLI --USB--> apcupsd (ser-ups1)
                      |
                      +-- NIS 0.0.0.0:3551 --> Home Assistant (in-cluster)
                      |
                      +-- 127.0.0.1:3551 --> prometheus apcupsd exporter :9162
                                                  --> cluster Prometheus
```

The host is GitOps-managed by comin from this repository, exactly like
ser-ntp1 and ser-dns1. No runtime secrets are required, so `.sops.yaml` and
the sops-nix wiring stay untouched.

## Changes by file

### `nixos/flake.nix`

- `mkHost` gains a `nixosHardwareModule` argument, used in place of the
  currently hardcoded `nixos-hardware.nixosModules.raspberry-pi-4`.
- ser-ntp1 and ser-dns1 pass `nixos-hardware.nixosModules.raspberry-pi-4`.
- New entries:
  - `nixosConfigurations.ser-ups1 = mkHost { hostname = "ser-ups1"; hostModule = ./hosts/ser-ups1; nixosHardwareModule = nixos-hardware.nixosModules.raspberry-pi-3; };`
  - `packages.aarch64-linux.sd-image-ser-ups1 = mkSdImage "ser-ups1";`
- `system` stays `aarch64-linux` (the Pi 3 runs aarch64 NixOS).

### `nixos/modules/common/default.nix`

- Move the Pi-4-specific line
  `boot.initrd.availableKernelModules = lib.mkForce [ "pcie-brcmstb" "reset-raspberrypi" ];`
  (and its explanatory comment) out to `modules/rpi4`. `pcie-brcmstb` does not
  exist on the BCM2837 (Pi 3) and would break its initrd build.
- Everything else (nix settings, firmware/U-Boot flow, locale, SSH, admin
  user, comin, sops-nix keyFile, node-exporter, firewall extraCommands,
  base packages, stateVersion) is hardware-agnostic and stays.

### `nixos/modules/rpi4/default.nix` (new)

- Contains the moved `boot.initrd.availableKernelModules` workaround with its
  comment. Imported only by the Pi 4 hosts.

### `nixos/modules/apcupsd/default.nix` (new)

- `services.apcupsd.enable = true;` with `configText`:

  ```
  UPSCABLE usb
  UPSTYPE usb
  DEVICE
  NISIP 0.0.0.0
  NISPORT 3551
  BATTERYLEVEL 50
  MINUTES 5
  TIMEOUT 0
  ```

  Notes:
  - `NISIP 0.0.0.0` overrides the nixpkgs default (`127.0.0.1`) so HA can
    connect remotely.
  - `DEVICE` empty = USB autodetection (correct for the SRT2200XLI USB HID
    interface).
  - `BATTERYLEVEL 50` / `MINUTES 5` are the nixpkgs defaults; `TIMEOUT 0`
    means the Pi never shuts itself down — it only reports. The UPS feeds
    network gear, not this host's logic.
- `services.prometheus.exporters.apcupsd.enable = true;` (defaults: port
  9162, scrapes `127.0.0.1:3551`).
- `networking.firewall.extraCommands` allowing tcp/3551 and tcp/9162 from
  `10.0.20.0/24` and `10.0.70.0/24` only.

### `nixos/hosts/ser-ups1/default.nix` (new)

- Header comment, `imports = [ ../../modules/apcupsd ];`. No networking
  block (DHCP + router reservation).

### `nixos/hosts/ser-ntp1/default.nix`, `nixos/hosts/ser-dns1/default.nix`

- Add `../../modules/rpi4` to their `imports`.

## Error handling / failure modes

- USB cable unplugged or UPS off: apcupsd reports `COMMLOST`; HA shows the
  integration as unavailable and the exporter exposes the stale/down state —
  visible in both consumers. No host-side remediation needed.
- apcupsd service failure: systemd restarts it (nixpkgs module default).
- No new secrets: nothing to add to `.sops.yaml`; the comin deploy key flow is
  reused as-is for the SD image build.

## Validation

Per the repo's "Testing & Validation" convention (no automated test suite):

1. `nix flake check ./nixos --no-build`
2. `nix eval ./nixos#nixosConfigurations.ser-ups1.config.system.build.toplevel.drvPath`
   — and the same for ser-ntp1 and ser-dns1 to prove the `common` refactor is
   behavior-preserving.
3. SD image build + first boot remain the documented manual runbook steps
   (`NIXOS_COMIN_DEPLOY_KEY=... nix build --impure ... sd-image-ser-ups1`),
   unchanged from the existing hosts.
4. After deployment: `apcaccess status` on the host, HA integration connects
   to `ser-ups1:3551`, and the exporter target is up in Prometheus.

## Out of scope

- Prometheus scrape config / ServiceMonitor for the exporter (cluster-side
  change; can be added later under `cluster/infrastructure/observability`).
- HA integration configuration (done in the HA UI).
- NUT support, UPS-driven shutdown of any host, runtime sops secrets.
