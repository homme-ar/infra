# Shared baseline for all auxiliary Raspberry Pi 4 hosts.
{ lib, pkgs, ... }:

{
  # --- Nix ---
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # The Raspberry Pi GPU boot firmware and wireless firmware are
  # unfree-redistributable packages.
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "raspberrypifw"
      "raspberrypi-wireless-firmware"
    ];

  # --- Raspberry Pi 4 boot flow ---
  # GPU firmware -> config.txt -> U-Boot -> extlinux.conf -> NixOS generation.
  # `firmware.enable` keeps /boot/firmware (GPU boot code, config.txt, U-Boot)
  # in sync on every `nixos-rebuild switch`, including comin deployments.
  hardware.raspberry-pi.firmware.enable = true;
  hardware.raspberry-pi.firmware.uboot.enable = true;

  # The SD image marks /boot/firmware as `noauto`, but the firmware activation
  # script above only updates the partition when it is mounted.
  fileSystems."/boot/firmware".options = lib.mkForce [ "nofail" ];

  # The generic SD image profile enables `hardware.enableAllHardware`, which
  # adds initrd modules for many ARM SoCs (Rockchip, Allwinner, ...) that do
  # not exist in the Raspberry Pi kernel, breaking the initrd build
  # ("modprobe: FATAL: Module dw-hdmi not found in directory ..."). Restrict
  # the initrd module list to what the RPi 4 kernel actually ships (this
  # mirrors nixos-hardware's raspberry-pi-4 module).
  boot.initrd.availableKernelModules = lib.mkForce [
    "pcie-brcmstb" # required for the PCIe bus (and thus USB) to work
    "reset-raspberrypi" # required for the VL805 USB firmware to load
  ];

  # No ZFS pools are used on these hosts (silences an upstream warning).
  boot.zfs.forceImportRoot = false;

  # --- Locale & time zone ---
  time.timeZone = "America/Argentina/Buenos_Aires";
  i18n.defaultLocale = "en_US.UTF-8";

  # --- Networking ---
  # DHCP is used by default. These hosts provide network services (NTP/DNS),
  # so give each one a static address in its file under nixos/hosts/.
  # On Raspberry Pi 4 the onboard Ethernet interface is named `end0`.

  # --- Remote access ---
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.admin = {
    isNormalUser = true;
    description = "Administrative user";
    extraGroups = [ "wheel" ];
    # TODO: replace with your own SSH public key before provisioning.
    openssh.authorizedKeys.keys = [
      "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBH6E72Ri4/T+D5K6eA6Gzq70UCGUhUUoaBumY3E1RhBAlJXiwqLGebFn1dtQqT2ebJE+8Xkv2T6tOW1iS7DmTvMAAAAbc3NoOmNhdHJpZWxtdWxsZXJAZ21haWwuY29t catrielmuller@ofcpc1"
    ];
  };

  # Headless hosts accessed with SSH keys only: allow passwordless sudo.
  security.sudo.wheelNeedsPassword = false;

  # --- GitOps agent (comin) ---
  # Polls this repository and switches to the nixosConfiguration matching the
  # host name. The flake lives in the `nixos/` subdirectory of the repository.
  #
  # The repository is private: comin authenticates with a shared, read-only
  # GitHub deploy key. The private key is stored sops-encrypted in
  # nixos/secrets/secrets.yaml (comin_deploy_key) and baked into the SD image
  # at build time (see nixos/flake.nix), so hosts can pull from their very
  # first boot. The public key (comin_deploy_key_pub) must be added once as a
  # read-only Deploy Key in the GitHub repository settings.
  # To rotate: generate a new keypair, update the sops secret, replace the
  # deploy key on GitHub, then install the new private key at
  # /var/lib/comin/deploy_key on each host (or rebuild the images).
  services.comin = {
    enable = true;
    repositorySubdir = "nixos";
    remotes = [
      {
        name = "origin";
        url = "git@github.com:homme-ar/infra.git";
        # GitHub's SSH endpoint requires the `git` user; the comin module
        # defaults to `comin`, which GitHub rejects (that default is only
        # valid for HTTPS token auth).
        auth.username = "git";
        auth.ssh_deploy_key_path = "/var/lib/comin/deploy_key";
        branches.main.name = "main";
      }
    ];
    # Prometheus metrics on :4243 (comin deployment status).
    exporter.openFirewall = true;
  };

  # GitHub SSH host key, pinned so comin can verify the remote
  # (comin reads /etc/ssh/ssh_known_hosts by default).
  # Source: https://api.github.com/meta
  programs.ssh.knownHosts."github.com".publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

  # --- Secrets (sops-nix) ---
  # Each host needs its own Age private key, generated on the device after the
  # first boot:
  #   install -d -m 700 /var/lib/sops-nix
  #   age-keygen -o /var/lib/sops-nix/key.txt
  # Add the resulting public key as a recipient in the root .sops.yaml and
  # store encrypted secrets under nixos/secrets/. Then declare the secrets
  # here (sops.secrets.<name>) and wire them into services as needed.
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  # sops.defaultSopsFile = ../../secrets/secrets.yaml;

  # --- Monitoring ---
  # Node metrics on :9100, scraped by the cluster Prometheus.
  services.prometheus.exporters.node = {
    enable = true;
    openFirewall = true;
  };

  # --- Base tooling ---
  environment.systemPackages = with pkgs; [
    htop
    jq
    vim
    git
    usbutils
  ];

  system.stateVersion = "26.05";
}
