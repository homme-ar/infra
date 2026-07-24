{
  description = "NixOS configurations for the Homme auxiliary Raspberry Pi 4 hosts (GitOps-managed by comin)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    nixos-hardware.url = "github:NixOS/nixos-hardware";

    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      comin,
      sops-nix,
    }:
    let
      system = "aarch64-linux";

      # Path to a local, decrypted copy of the comin deploy key. Only read
      # when building SD images (impure evaluation, see below); the
      # nixosConfigurations stay pure so comin deployments are unaffected.
      cominDeployKeyPath = builtins.getEnv "NIXOS_COMIN_DEPLOY_KEY";

      mkHost =
        { hostname, hostModule }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            nixos-hardware.nixosModules.raspberry-pi-4
            comin.nixosModules.comin
            sops-nix.nixosModules.sops
            # The same configuration builds the SD image and runs on the
            # device afterwards, so comin deployments rebuild the very
            # system that is already installed.
            "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
            ./modules/common
            hostModule
            { networking.hostName = hostname; }
          ];
        };

      # Bakes the comin deploy key into the SD image root filesystem. The key
      # material is read from a local file at build time: it never enters the
      # Nix store or this repository in plain text.
      sdImageInjectModule =
        { lib, config, ... }:
        {
          sdImage.populateRootCommands = lib.mkForce ''
            mkdir -p ./files/boot
            ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot
            install -D -m 600 "${cominDeployKeyPath}" ./files/var/lib/comin/deploy_key
          '';
        };

      mkSdImage =
        hostname:
        if cominDeployKeyPath == "" then
          builtins.throw ''
            NIXOS_COMIN_DEPLOY_KEY is not set. Point it to a decrypted copy of
            the comin deploy key, e.g.:
              sops -d --extract '["comin_deploy_key"]' nixos/secrets/secrets.yaml > /tmp/comin_deploy_key
              chmod 644 /tmp/comin_deploy_key
              NIXOS_COMIN_DEPLOY_KEY=/tmp/comin_deploy_key nix build --impure --option sandbox false ./nixos#packages.aarch64-linux.sd-image-${hostname}
              shred -u /tmp/comin_deploy_key
          ''
        else
          (self.nixosConfigurations.${hostname}.extendModules {
            modules = [ sdImageInjectModule ];
          }).config.system.build.sdImage;
    in
    {
      nixosConfigurations = {
        # GPS-disciplined NTP stratum 1 server
        ntp = mkHost {
          hostname = "ntp";
          hostModule = ./hosts/ntp;
        };

        # AdGuard Home DNS server
        dns = mkHost {
          hostname = "dns";
          hostModule = ./hosts/dns;
        };
      };

      # SD card images for the initial provisioning of each host. Each image
      # is baked with the comin deploy key (stored sops-encrypted in
      # nixos/secrets/secrets.yaml), so hosts can pull this private repository
      # from their very first boot. Build example:
      #
      #   sops -d --extract '["comin_deploy_key"]' nixos/secrets/secrets.yaml > /tmp/comin_deploy_key
      #   chmod 644 /tmp/comin_deploy_key  # readable by the Nix build user
      #   NIXOS_COMIN_DEPLOY_KEY=/tmp/comin_deploy_key nix build --impure --option sandbox false ./nixos#packages.aarch64-linux.sd-image-ntp
      #   (the full `packages.aarch64-linux.` path is required on x86_64 build machines)
      #   shred -u /tmp/comin_deploy_key
      #
      # Building an aarch64-linux image on an x86_64 machine also requires a
      # remote aarch64 builder or binfmt emulation (boot.binfmt.emulatedSystems).
      #   zstd -d result/sd-image/*.img.zst -o rpi.img  # then flash it to the SD card
      packages.${system} = {
        sd-image-ntp = mkSdImage "ntp";
        sd-image-dns = mkSdImage "dns";
      };
    };
}
