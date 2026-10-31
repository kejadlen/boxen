{
  config,
  modulesPath,
  pkgs,
  ...
}:

let
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPgX0tA28NO3djYaV++JxggR0t47xou+R0HQVwVjzj8s"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAmBthfb/WZo/cU1FFPQv8jAICTzkJIrNR1IMngUC3MB"
  ];

  # Fixed so the Caddyfile can trust it; podman assigns subnets on creation otherwise.
  podmanNetwork = "caddy";
  podmanSubnet = "10.89.0.0/24";
in
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";

  # Lish, Linode's out-of-band console, is the first serial port.
  boot.kernelParams = [ "console=ttyS0,19200n8" ];
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    forceInstall = true;
    extraConfig = ''
      serial --speed=19200 --unit=0 --word=8 --parity=no --stop=1
      terminal_input serial
      terminal_output serial
    '';
  };
  boot.loader.timeout = 10;

  networking.hostName = "imperishable-night";
  networking.usePredictableInterfaceNames = false;
  networking.useDHCP = false;
  networking.interfaces.eth0.useDHCP = true;
  networking.firewall = {
    trustedInterfaces = [ "tailscale0" ];
    allowedTCPPorts = [
      80
      443
    ];
    # HTTP/3.
    allowedUDPPorts = [ 443 ];
  };

  services.tailscale = {
    enable = true;
    # Opens the WireGuard port so peers connect directly, not through DERP.
    openFirewall = true;
    # nixos-anywhere's --extra-files writes this at install; it's unused once joined.
    authKeyFile = "/var/lib/tailscale-auth-key";
  };

  # lotus-land-story's linode job discovers the instance and scrapes :9100 over
  # the tailnet; the port stays closed publicly.
  services.prometheus.exporters.node.enable = true;

  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # Containers reach each other by name only on a user-defined network.
  systemd.services."podman-network-${podmanNetwork}" = {
    path = [ config.virtualisation.podman.package ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      podman network exists ${podmanNetwork} ||
        podman network create --subnet ${podmanSubnet} ${podmanNetwork}
    '';
  };

  # sops-nix decrypts with the age key derived from the SSH host key.
  sops.defaultSopsFile = ./secrets.sops.yml;
  sops.secrets."caddy/ts_authkey" = { };
  sops.secrets."caddy/dnsimple_token" = { };
  sops.templates."caddy.env" = {
    content = ''
      TS_AUTHKEY=${config.sops.placeholder."caddy/ts_authkey"}
      DNSIMPLE_API_ACCESS_TOKEN=${config.sops.placeholder."caddy/dnsimple_token"}
    '';
    restartUnits = [ "podman-caddy.service" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/caddy/data 0755 root root -"
    "d /var/lib/caddy/config 0755 root root -"
  ];

  virtualisation.oci-containers.containers.caddy = {
    image = "ghcr.io/kejadlen/caddy-kejadlen:2.11.7-2026.10.07";
    environmentFiles = [ config.sops.templates."caddy.env".path ];
    ports = [
      "80:80"
      "443:443"
      "443:443/udp"
    ];
    volumes = [
      "${
        pkgs.replaceVars ./Caddyfile { trusted_proxies = podmanSubnet; }
      }:/etc/caddy/Caddyfile:ro"
      "/var/lib/caddy/data:/data"
      "/var/lib/caddy/config:/config"
    ];
    networks = [ podmanNetwork ];
    # Unbounded, caddy takes the host down with it. Equal memory-swap denies swap.
    extraOptions = [
      "--memory=1g"
      "--memory-swap=1g"
    ];
  };
  systemd.services.podman-caddy = {
    requires = [ "podman-network-${podmanNetwork}.service" ];
    after = [ "podman-network-${podmanNetwork}.service" ];
  };

  sops.secrets."restic/password" = { };
  sops.secrets."restic/healthcheck" = { };
  sops.templates."restic.env".content = ''
    HEALTHCHECK=https://hc-ping.com/${config.sops.placeholder."restic/healthcheck"}
  '';

  programs.ssh.knownHosts.legacy-of-lunatic-kingdom.publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG/+SIFLbFe3hXp3l0dJSE7J4DpQkEEk//62kMiQsWOZ";

  # Shares lotus-land-story's repository; restic's hostname keeps the snapshots apart.
  services.restic.backups.daily =
    let
      ping = path: ''
        ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 10 \
          --retry 5 --output /dev/null "$HEALTHCHECK${path}" || true
      '';
    in
    {
      repository = "sftp:restic@legacy-of-lunatic-kingdom:/mnt/data/restic";
      passwordFile = config.sops.secrets."restic/password".path;
      environmentFile = config.sops.templates."restic.env".path;
      # lolk's restic user authorizes the host key, so there's no separate client key.
      extraOptions = [
        "sftp.command='ssh restic@legacy-of-lunatic-kingdom -i /etc/ssh/ssh_host_ed25519_key -s sftp'"
      ];
      paths = [ "/var/lib" ];
      exclude = [ "/var/lib/containers" ];
      # Waits out the other host's prune, which locks the shared repository.
      extraBackupArgs = [ "--retry-lock=30m" ];
      pruneOpts = [
        "--retry-lock=30m"
        "--host=imperishable-night"
        "--keep-within-daily=1m"
        "--keep-within-weekly=1y"
        "--keep-within-monthly=100y"
      ];
      timerConfig = {
        OnCalendar = "03:00";
        Persistent = true;
      };
      backupPrepareCommand = ping "/start";
      backupCleanupCommand = ''
        if [ "$SERVICE_RESULT" = success ]; then
          ${ping ""}
        else
          ${ping "/fail"}
        fi
      '';
    };

  # lotus-land-story scrapes :8080 over the tailnet; the port stays closed publicly.
  services.cadvisor = {
    enable = true;
    listenAddress = "0.0.0.0";
    extraOptions = [
      # https://github.com/google/cadvisor/issues/2523#issuecomment-2258042352
      "--housekeeping_interval=30s"
      # Drops raw cgroups only; podman containers come from cadvisor's podman handler.
      "--docker_only=true"
      "--store_container_labels=false"
    ];
  };

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
  };
  security.sudo.wheelNeedsPassword = false;

  # Lets nixos-rebuild --target-host copy closures in as alpha.
  nix.settings.trusted-users = [ "@wheel" ];
}
