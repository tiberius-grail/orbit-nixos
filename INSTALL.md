# Install — admin guide

For IT admins enrolling a NixOS host into tiberius-fleet. Step-by-step,
copy-paste friendly. Estimated time: 10 minutes.

## Prerequisites

- The host runs **NixOS** managed by a flake-based `nix-config`. If it
  isn't, this guide doesn't apply — install fleetd via the appropriate
  package manager instead (`apt`/`dnf`/`pacman`).
- You can edit the flake repo and run `nixos-rebuild switch` (or `rb`).
- You have admin access to **tiberius-fleet** at
  https://tiberius-fleet.graildefence.dev.
- The host has `sops-nix` already enabled (so we can store the enroll
  secret without committing it as plain text). If not, set that up
  separately first — see https://github.com/Mic92/sops-nix.

## Step 1 — Get the enroll secret from fleet

The enroll secret authenticates the host to fleet. Two ways to grab it:

**Option A (via UI):** Log in to https://tiberius-fleet.graildefence.dev
→ **Hosts** → **Add hosts** → **Linux** tab → look for the value of
`FLEET_ENROLL_SECRET` in the displayed `fleetctl package` command. Copy
just that string.

**Option B (via fleetctl, if you have it set up):**

```sh
fleetctl get enroll_secret
```

Whichever way, **don't paste the secret into chat/IM/email**. Put it
in a temp file on the host (mode 600):

```sh
echo -n 'PASTE_THE_SECRET_HERE' > /tmp/orbit-enroll.txt
chmod 600 /tmp/orbit-enroll.txt
```

## Step 2 — Add the flake input

In your `nix-config/flake.nix`, add:

```nix
inputs.orbit-nixos = {
  url = "git+https://code.grail.tiberius.com/tiberius-public/orbit-nixos";
  # NOT following local nixpkgs: orbit-nixos needs Go ≥ 1.26.3, which
  # nixos-unstable has but pinned releases may not.
};
```

Pass through to the host's `nixosSystem` modules list:

```nix
modules = [
  inputs.orbit-nixos.nixosModules.default   # bundles orbit + cmmc
  inputs.sops-nix.nixosModules.sops
  # ...your other modules
  ./hosts/THIS_HOST/configuration.nix
];
```

## Step 3 — Store the enroll secret in sops

If your sops setup uses `secrets/secrets.yaml`, add a key for orbit:

```sh
sops secrets/secrets.yaml
```

Add (or update) the `orbit:` block:

```yaml
orbit:
  enroll_secret: PASTE_FROM_/tmp/orbit-enroll.txt_HERE
```

Save + close. sops re-encrypts automatically.

Then remove the temp file:

```sh
shred -u /tmp/orbit-enroll.txt
```

## Step 4 — Enable orbit + compliance on the host

In your `hosts/THIS_HOST/configuration.nix`:

```nix
# Decrypt the enroll secret to a file the orbit module reads
sops.secrets."orbit/enroll_secret" = {
  owner = "root";
  group = "root";
  mode  = "0400";
};

# Enroll the host in fleet
services.orbit = {
  enable           = true;
  fleetUrl         = "https://tiberius-fleet.graildefence.dev";
  enrollSecretPath = "/run/secrets/orbit/enroll_secret";
  hostIdentifier   = "uuid";
  enableScripts    = true;   # lets fleet run scripts on this host
};

# Baseline hardening — closes the grail-fleet CMMC compliance policies
modules.compliance.enable = true;
```

## Step 5 — Rebuild + activate

From the nix-config repo on the host:

```sh
sudo nixos-rebuild switch --flake .#$(hostname)
```

Or if you use the `nh`-based shortcuts in your config:

```sh
rb
```

Expected on success: systemd starts `orbit.service` (and several
compliance services — `clamav-daemon`, `auditd`, `fail2ban`,
`nixos-upgrade.timer`, `clamav-periodic-scan.timer`). First boot also
provisions `/etc/issue.net` (login banner) and
`/etc/security/pwquality.conf`.

## Step 6 — Verify in fleet

In tiberius-fleet's UI, the new host appears within ~30s under
**Hosts**. Click in:

- **Details** tab — confirms OS = NixOS, hardware fingerprint, last
  seen.
- **Policies** tab — should see ~42 policies; technical ones pass
  immediately, the procedural ones stay marked failing (manual
  attestation needed in OSCAL, not in fleet).

If you also enabled `services.osquery-nix-tables.enable = true` (via
the separate `osquery-nix-tables` flake), the **Software** tab gains
visibility into installed Nix packages.

## Troubleshooting

### `osquery-nix-tables.service: Failed (status=1)` then auto-restart

Orbit's socket path needs write access. Confirm the systemd service
has `ReadWritePaths=/var/lib/orbit` — older flake revisions missed
this. Bump the orbit-nixos input.

### `orbit.service` flapping with TLS error

Confirm `fleetUrl` points at the **public** URL with `https://`. Orbit
doesn't accept HTTP. If you're behind a corporate proxy, also set
`networking.proxy.default = "http://...";` in configuration.nix.

### Host doesn't appear in fleet after 5 min

Check that the host can resolve and reach tiberius-fleet.graildefence.dev:443.
From the host:

```sh
curl -sS https://tiberius-fleet.graildefence.dev/api/v1/fleet/me \
  -H 'Authorization: Bearer XXX'   # any string, we just need a 401
```

A 401 means networking works (fleet rejected the bogus token). A
timeout means the host can't reach fleet.

### Enroll secret got rotated

Update the value in `secrets/secrets.yaml` with `sops secrets/secrets.yaml`,
then `rb`. The orbit systemd service restarts automatically when the
mounted secret changes (sops-nix triggers it).
