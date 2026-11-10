# What every NixOS host in the fleet shares.
{
  config,
  dotfiles,
  pkgs,
  ...
}:

let
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPgX0tA28NO3djYaV++JxggR0t47xou+R0HQVwVjzj8s"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAmBthfb/WZo/cU1FFPQv8jAICTzkJIrNR1IMngUC3MB"
  ];
in
{
  imports = [ ./update-metrics.nix ];

  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  # restartUnits via systemctl try-restart, not the restart list NixOS 26.11 removes.
  sops.useSystemdActivation = true;

  services.tailscale = {
    enable = true;
    # Opens the WireGuard port so peers connect directly, not through DERP.
    openFirewall = true;
    # nixos-anywhere's --extra-files writes this at install; it's unused once joined.
    authKeyFile = "/var/lib/tailscale-auth-key";
  };

  # VictoriaMetrics scrapes :9100 over the tailnet; the port stays closed publicly.
  services.prometheus.exporters.node.enable = true;

  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # Tailnet sites on every host are signed by the shared Caddy root.
  security.pki.certificateFiles = [ ./caddy-root.crt ];

  services.openssh = {
    enable = true;
    # SSH is reachable only over the trusted tailscale0.
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.alpha = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = sshKeys;
    packages = [ dotfiles.packages.${pkgs.stdenv.hostPlatform.system}.profile ];
  };

  # Clones once and never pulls, so the checkout is alpha's to manage.
  systemd.services.dotfiles-clone =
    let
      dest = "${config.users.users.alpha.home}/.dotfiles";
    in
    {
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig.ConditionPathExists = "!${dest}";
      path = [ pkgs.git ];
      serviceConfig = {
        Type = "oneshot";
        User = "alpha";
      };
      # A failed clone leaves no dest behind, so the next boot retries.
      script = ''
        rm -rf ${dest}.tmp
        git clone https://github.com/kejadlen/dotfiles.git ${dest}.tmp
        mv ${dest}.tmp ${dest}
      '';
    };
  security.sudo.wheelNeedsPassword = false;

  # Lets nixos-rebuild --target-host copy closures in as alpha.
  nix.settings.trusted-users = [ "@wheel" ];
}
