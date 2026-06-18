{
  description = ''
    Reusable NixOS flake for Fleet/Orbit + CMMC v2 compliance.

    Two independent modules — import either or both:

      nixosModules.orbit   — the fleet agent (orbit + fleet-desktop).
                             Builds from fleetdm/fleet source, uses
                             nixpkgs's osquery, applies NixOS-compat
                             patches, runs fleet-desktop as a systemd
                             user service. Toggle on with
                             `services.orbit.enable = true;`.

      nixosModules.cmmc    — CMMC v2 (NIST 800-171) baseline hardening:
                             ClamAV + auditd + nixos-upgrade timer +
                             fail2ban + /etc/issue.net banner +
                             /etc/security/pwquality.conf. Toggle on
                             with `modules.compliance.enable = true;`.

      nixosModules.default — imports BOTH of the above. Enable each
                             via its own option (no auto-enable).
  '';

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    forAllSystems =
      nixpkgs.lib.genAttrs
      [
        "aarch64-linux"
        "i686-linux"
        "x86_64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
  in {
    packages = forAllSystems (
      system:
        import ./pkgs {
          pkgs = nixpkgs.legacyPackages.${system};
        }
    );

    checks = forAllSystems (system: self.packages.${system});

    nixosModules.orbit = import ./modules {
      fleetPackages = self.packages;
    };
    # Back-compat name for existing consumers of the old top-level
    # `fleet-nixos` module path. Identical to nixosModules.orbit.
    nixosModules.fleet-nixos = self.nixosModules.orbit;

    nixosModules.cmmc = import ./modules/compliance.nix;

    nixosModules.default = {
      imports = [
        self.nixosModules.orbit
        self.nixosModules.cmmc
      ];
    };
  };
}
