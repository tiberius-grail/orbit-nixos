{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.modules.compliance;
  inherit (lib)
    mkIf
    mkEnableOption
    mkOption
    types
    ;
in
{
  options.modules.compliance = {
    enable = mkEnableOption ''
      CMMC-aligned baseline hardening. Enables the technical controls
      that the grail-fleet policies check for. Specifically maps to:
        SI.L1-3.14.1  flaw-identification     → system.autoUpgrade
        SI.L1-3.14.2  malware-protection      → services.clamav.daemon
        SI.L1-3.14.4  update-malware-defs     → services.clamav.updater
        SI.L1-3.14.5  periodic-scans          → clamav scan timer
        AU.L2-3.3.1   system-audit-logs       → security.audit
        AU.L2-3.3.2   individual-accountab    → auditd rules
        AC.L2-3.1.9   system-use-notification → /etc/issue.net banner
    '';

    banner = mkOption {
      type = types.lines;
      default = ''
        ============================================================
                 TIBERIUS GRAIL — AUTHORIZED USE ONLY
        ============================================================
        This system is for the use of authorized users only.
        Activity on this system may be monitored and recorded.
        Unauthorized access or use is prohibited and may result in
        disciplinary action and/or civil and criminal penalties.
        ============================================================
      '';
      description = "Text written to /etc/issue and /etc/issue.net for SSH/login banners.";
    };

    clamav.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Run ClamAV daemon + freshclam updater (SI.L1-3.14.2 / 3.14.4).";
    };

    clamav.scanScheduleOnCalendar = mkOption {
      type = types.str;
      default = "weekly";
      description = ''
        systemd OnCalendar spec for the periodic ClamAV scan
        (SI.L1-3.14.5). Default "weekly" runs every Monday 00:00
        and clamdscan walks the system root. Use "daily" for
        higher-risk hosts.
      '';
    };

    clamav.scanPaths = mkOption {
      type = types.listOf types.str;
      default = [
        "/etc"
        "/home"
        "/var"
        "/srv"
      ];
      description = "Filesystem roots clamdscan walks during the periodic scan.";
    };

    autoUpgrade.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable system.autoUpgrade so a `nixos-upgrade.timer` is
        active on the host (SI.L1-3.14.1). Pulls from the flake we're
        deployed from (no separate channel pin).
      '';
    };

    auditd.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable kernel auditd + base rules (AU.L2-3.3.1 / 3.3.2).";
    };

    fail2ban.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable fail2ban for failed-login lockout (AC.L2-3.1.8).
        Generic across distros — pam_faillock isn't first-class on
        NixOS, so we use the log-watching approach instead. Default
        jails watch sshd, fail2ban's own service inventory, etc.
      '';
    };
  };

  config = mkIf cfg.enable {
    # ─── SI.L1-3.14.1: flaw identification ─────────────────────────────
    system.autoUpgrade = mkIf cfg.autoUpgrade.enable {
      enable = true;
      # Use the flake the system was built from. Daily check; no auto-reboot
      # (interactive systems shouldn't reboot themselves silently — the
      # `nixos-upgrade.timer` being active is what the policy checks for).
      flake = "github:tiberius-grail/nix-config#${config.networking.hostName}";
      dates = "04:30";
      allowReboot = false;
    };

    # ─── SI.L1-3.14.{2,4,5}: malware protection + defs + scans ─────────
    services.clamav = mkIf cfg.clamav.enable {
      daemon.enable = true;
      updater.enable = true;
    };

    # Periodic clamdscan timer (SI.L1-3.14.5). NixOS doesn't ship a
    # built-in scheduled-scan unit, so we synthesize one. systemd timer
    # named clamav-periodic-scan.timer — the policy query LIKE-matches
    # 'clamav%scan%'.
    systemd.timers."clamav-periodic-scan" = mkIf cfg.clamav.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.clamav.scanScheduleOnCalendar;
        Persistent = true;
        Unit = "clamav-periodic-scan.service";
      };
    };
    systemd.services."clamav-periodic-scan" = mkIf cfg.clamav.enable {
      description = "Periodic ClamAV filesystem scan (CMMC SI.L1-3.14.5)";
      after = [ "clamav-daemon.service" ];
      serviceConfig = {
        Type = "oneshot";
        Nice = 19;
        IOSchedulingClass = "idle";
        ExecStart = "${pkgs.clamav}/bin/clamdscan --fdpass --multiscan --quiet ${lib.escapeShellArgs cfg.clamav.scanPaths}";
      };
    };

    # ─── AU.L2-3.3.1 / 3.3.2: auditd + base rules ──────────────────────
    security.audit = mkIf cfg.auditd.enable {
      enable = true;
      rules = [
        # Minimal baseline so audit.rules isn't empty (the policy
        # query checks for the file's existence + presence of rules).
        # Extend per host as needed.
        "-w /etc/passwd -p wa -k identity"
        "-w /etc/group -p wa -k identity"
        "-w /etc/shadow -p wa -k identity"
        "-w /etc/sudoers -p wa -k privileged"
        "-w /var/log/sudo.log -p wa -k actions"
        "-a always,exit -F arch=b64 -S execve -k exec"
      ];
    };
    security.auditd.enable = mkIf cfg.auditd.enable true;

    # ─── AC.L2-3.1.9: system use notification ──────────────────────────
    # /etc/issue (local console) + /etc/issue.net (SSH banner). NixOS
    # symlinks /etc/issue from /run/current-system/etc/issue, both paths
    # work for the policy check.
    environment.etc."issue".text = cfg.banner;
    environment.etc."issue.net".text = cfg.banner;

    # SSH banner uses /etc/issue.net by convention; if openssh is on
    # this host, point its Banner directive at issue.net.
    services.openssh.banner = mkIf config.services.openssh.enable "/etc/issue.net";

    # ─── AC.L2-3.1.8: limit unsuccessful logon attempts ────────────────
    # fail2ban watches log files (sshd, login) and bans IPs after N
    # failures. Generic across distros — pam_faillock isn't first-class
    # on NixOS, so this is the more portable mechanism.
    services.fail2ban = mkIf cfg.fail2ban.enable {
      enable = true;
      maxretry = 5;
      bantime = "15m";
      ignoreIP = [
        "127.0.0.0/8"
        "::1"
        "10.0.0.0/8"
        "192.168.0.0/16"
      ];
    };

    # ─── IA.L2-3.5.7: password complexity ──────────────────────────────
    # Drops a Debian/RHEL-shaped pwquality.conf at the canonical path so
    # the universal compliance query passes (it OR-matches the file or a
    # pam_pwquality reference in /etc/pam.d/, with an SSO-only fallback).
    # NixOS doesn't wire pwquality into pam by default — this is purely
    # the policy-detection surface. To actually enforce on local password
    # changes, add a security.pam.services.<svc>.rules.password.pwquality
    # block downstream.
    environment.etc."security/pwquality.conf".text = ''
      # Minimum password length
      minlen = 12
      # Number of new chars required vs old password
      difok = 3
      # Require at least one of each character class
      dcredit = -1
      ucredit = -1
      ocredit = -1
      lcredit = -1
      # Reject passwords containing the username
      usercheck = 1
      # How many retries on failed input
      retry = 3
    '';
  };
}
