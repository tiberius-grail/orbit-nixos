# orbit-nixos

Reusable NixOS flake bundling two independent modules:

1. **`nixosModules.orbit`** — Fleet's agent (orbit + fleet-desktop)
   packaged from fleetdm/fleet source. Uses nixpkgs's osquery instead
   of the bundled binary (no patchelf), applies NixOS-compat patches
   (shebang rewriting in scripts, custom log paths), and runs
   fleet-desktop as a systemd user service.

2. **`nixosModules.cmmc`** — Technical-control baseline for CMMC v2
   (NIST SP 800-171). Wires up ClamAV, auditd, the nixos-upgrade
   timer, fail2ban, /etc/issue.net login banner, and
   /etc/security/pwquality.conf — i.e. what the grail-fleet CMMC
   policies actually check for.

Each module is independently toggleable. `nixosModules.default`
imports both (you still enable each via its own option).

## Install (typical case — both modules)

Add to your flake inputs:

```nix
inputs.orbit-nixos = {
  url = "git+https://code.grail.tiberius.com/tiberius-public/orbit-nixos";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Pass through to your NixOS configuration:

```nix
nixosConfigurations.your-host = nixpkgs.lib.nixosSystem {
  modules = [
    inputs.orbit-nixos.nixosModules.default   # orbit + cmmc
    ./configuration.nix
  ];
};
```

In `configuration.nix`, enable each:

```nix
# Enrolls the host in fleet
services.orbit = {
  enable = true;
  fleetUrl = "https://tiberius-fleet.graildefence.dev";
  enrollSecretPath = "/run/secrets/orbit/enroll_secret";
  hostIdentifier = "uuid";
  enableScripts = true;
};

# Baseline hardening — passes the grail-fleet CMMC policies
modules.compliance.enable = true;
```

## Install (just one)

Agent only:

```nix
modules = [ inputs.orbit-nixos.nixosModules.orbit ];
```

Compliance baseline only (e.g., a host that runs a different agent):

```nix
modules = [ inputs.orbit-nixos.nixosModules.cmmc ];
```

## Heritage

Forked from [adamcik/fleet-nixos](https://github.com/adamcik/fleet-nixos)
(MIT) and extended:

- Switched build source to a Tiberius-pinned fleet revision.
- Added the `nixosModules.cmmc` module (previously a separate
  `tiberius-public/cmmc-nixos` repo, now merged in).
- Repointed default install URL to Forgejo
  (`code.grail.tiberius.com/tiberius-public/orbit-nixos`).
