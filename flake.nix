{
  description = "Homelab Kubernetes infrastructure development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              # Kubernetes & GitOps
              kubectl
              k9s
              kubernetes-helm
              kustomize
              fluxcd
              flux9s

              # Talos Linux
              talosctl
              talhelper

              # Secrets & Encryption (SOPS + Age)
              sops
              age

              # JSON/YAML & General Utilities
              yq-go
              jq
            ];

            shellHook = ''
              echo "🛠️  Homme K8s development environment!"
              echo "📦 Available binaries: kubectl, talosctl, talhelper, sops, age, flux, flux9s, k9s, helm, kustomize, yq, jq"
            '';
          };
        });
    };
}
