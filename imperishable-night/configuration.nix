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

  versions = {
    caddy = "2.11.7-2026.10.07";
    homebox = "0.27.1";
    paperless-ngx = "3.4.2";
    redis = "8.10.3";
  };
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
  sops.secrets."caddy/ca_root_key".restartUnits = [ "podman-caddy.service" ];
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
    # homebox's image runs as the distroless nonroot user.
    "d /var/lib/homebox 0755 65532 65532 -"
    # paperless-ngx's image runs as its default USERMAP_UID and USERMAP_GID.
    "d /var/lib/paperless-ngx/consume 0700 1000 1000 -"
    "d /var/lib/paperless-ngx/data 0700 1000 1000 -"
    "d /var/lib/paperless-ngx/export 0700 1000 1000 -"
    "d /var/lib/paperless-ngx/media 0700 1000 1000 -"
  ];

  virtualisation.oci-containers.containers.caddy = {
    image = "ghcr.io/kejadlen/caddy-kejadlen:${versions.caddy}";
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
      "${./caddy-root.crt}:/etc/caddy/pki/root.crt:ro"
      "${config.sops.secrets."caddy/ca_root_key".path}:/etc/caddy/pki/root.key:ro"
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

  sops.secrets."homebox/mailer/username" = { };
  sops.secrets."homebox/mailer/password" = { };
  sops.secrets."homebox/api_key_pepper" = { };
  sops.templates."homebox.env" = {
    content = ''
      HBOX_AUTH_API_KEY_PEPPER=${config.sops.placeholder."homebox/api_key_pepper"}
      HBOX_MAILER_USERNAME=${config.sops.placeholder."homebox/mailer/username"}
      HBOX_MAILER_PASSWORD=${config.sops.placeholder."homebox/mailer/password"}
    '';
    restartUnits = [ "podman-homebox.service" ];
  };

  virtualisation.oci-containers.containers.homebox = {
    image = "ghcr.io/sysadminsmedia/homebox:${versions.homebox}";
    environment = {
      TZ = "America/Los_Angeles";
      HBOX_OPTIONS_ALLOW_ANALYTICS = "false";
      HBOX_OPTIONS_ALLOW_REGISTRATION = "false";
      HBOX_MAILER_HOST = "mail.smtp2go.com";
      HBOX_MAILER_PORT = "2525";
      HBOX_MAILER_FROM = "homebox@kejadlen.dev";
    };
    environmentFiles = [ config.sops.templates."homebox.env".path ];
    volumes = [ "/var/lib/homebox:/data" ];
    networks = [ podmanNetwork ];
  };
  systemd.services.podman-homebox = {
    requires = [ "podman-network-${podmanNetwork}.service" ];
    after = [ "podman-network-${podmanNetwork}.service" ];
  };

  # paperless-ngx's Celery broker; nothing in it is worth persisting.
  virtualisation.oci-containers.containers.redis = {
    image = "docker.io/library/redis:${versions.redis}";
    networks = [ podmanNetwork ];
  };
  systemd.services.podman-redis = {
    requires = [ "podman-network-${podmanNetwork}.service" ];
    after = [ "podman-network-${podmanNetwork}.service" ];
  };

  sops.secrets."paperless_ngx/secret" = { };
  sops.templates."paperless-ngx.env" = {
    content = ''
      PAPERLESS_SECRET_KEY=${config.sops.placeholder."paperless_ngx/secret"}
    '';
    restartUnits = [ "podman-paperless-ngx.service" ];
  };

  # https://github.com/paperless-ngx/paperless-ngx/blob/main/docker/compose/docker-compose.sqlite.yml
  virtualisation.oci-containers.containers.paperless-ngx = {
    image = "ghcr.io/paperless-ngx/paperless-ngx:${versions.paperless-ngx}";
    dependsOn = [ "redis" ];
    environment = {
      PAPERLESS_ENABLE_FLOWER = "true";
      PAPERLESS_ENABLE_HTTP_REMOTE_USER = "true";
      PAPERLESS_OCR_USER_ARGS = ''{"continue_on_soft_render_error": true}'';
      PAPERLESS_REDIS = "redis://redis:6379";
      PAPERLESS_TASK_WORKERS = "1";
      PAPERLESS_THREADS_PER_WORKER = "1";
      PAPERLESS_TIME_ZONE = "America/Los_Angeles";
      # Training exhausted lotus-land-story's memory, so it runs overnight.
      PAPERLESS_TRAIN_TASK_CRON = "5 0 * * *";
      PAPERLESS_URL = "https://docs";
      PAPERLESS_WEBSERVER_WORKERS = "1";
    };
    environmentFiles = [ config.sops.templates."paperless-ngx.env".path ];
    volumes = [
      "/var/lib/paperless-ngx/data:/usr/src/paperless/data"
      "/var/lib/paperless-ngx/media:/usr/src/paperless/media"
      "/var/lib/paperless-ngx/export:/usr/src/paperless/export"
      "/var/lib/paperless-ngx/consume:/usr/src/paperless/consume"
      "${pkgs.writeText "flowerconfig.py" ''
        url_prefix = "/flower/"
      ''}:/usr/src/paperless/src/paperless/flowerconfig.py:ro"
    ];
    networks = [ podmanNetwork ];
  };
  systemd.services.podman-paperless-ngx = {
    requires = [ "podman-network-${podmanNetwork}.service" ];
    after = [ "podman-network-${podmanNetwork}.service" ];
  };

  sops.secrets."restic/password" = { };
  sops.secrets."restic/healthcheck" = { };
  sops.templates."restic.env".content = ''
    HEALTHCHECK=https://hc-ping.com/${config.sops.placeholder."restic/healthcheck"}
  '';

  # Tailnet sites on both hosts are signed by the shared Caddy root.
  security.pki.certificateFiles = [ ./caddy-root.crt ];

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
      extraBackupArgs = [
        "--retry-lock=30m"
        "--tag=long-term"
      ];
      pruneOpts = [
        "--retry-lock=30m"
        "--host=imperishable-night"
        "--tag=long-term"
        "--keep-within-daily=1m"
        "--keep-within-weekly=3m"
        "--keep-within-monthly=2y"
        "--keep-within-yearly=100y"
      ];
      timerConfig = {
        OnCalendar = "03:00";
        Persistent = true;
      };
      backupPrepareCommand = ''
        date +%s > /run/restic-backups-daily/start
        ${ping "/start"}
      '';
      # Pushes the same backup_* series as lotus-land-story's backup.sh.
      backupCleanupCommand = ''
        push() {
          ${pkgs.curl}/bin/curl --fail --silent --show-error --max-time 10 \
            --retry 3 --data-binary "$1" https://metrics/api/v1/import/prometheus || true
        }

        end=$(date +%s)
        start=$(cat /run/restic-backups-daily/start 2>/dev/null || echo "$end")
        ts=''${end}000 # milliseconds
        l='{job="backup",host="imperishable-night"}'
        if [ "$SERVICE_RESULT" = success ]; then
          ${ping ""}
          push "$(printf '%s\n' \
            "backup_success$l 1 $ts" \
            "backup_duration_seconds$l $((end - start)) $ts" \
            "backup_completed_timestamp$l $end $ts")"
        else
          ${ping "/fail"}
          push "backup_success$l 0 $ts"
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

  # Ships container logs, which podman writes to journald, to lotus-land-story's VictoriaLogs.
  services.vector = {
    enable = true;
    journaldAccess = true;
    settings = {
      sources.journald.type = "journald";
      transforms.containers = {
        type = "filter";
        inputs = [ "journald" ];
        condition = "exists(.CONTAINER_NAME)";
      };
      # Matches the fields lotus-land-story's Vector sends, plus host.
      transforms.containers_parsed = {
        type = "remap";
        inputs = [ "containers" ];
        source = ''
          message = string(.message) ?? ""
          event = {
            "_time": .timestamp,
            "_msg": message,
            "host": .host,
            "container_id": .CONTAINER_ID_FULL,
            "container_name": .CONTAINER_NAME,
          }

          if event.container_name == "caddy" {
            # Startup errors and panics go to stderr as plain text.
            parsed, err = parse_json(message)
            if err == null && is_object(parsed) {
              event = merge(event, object!(parsed))
              event._time = del(event.ts)
              event._msg = del(event.msg)
            }
          }

          . = event
        '';
      };
      sinks.victoria_logs = {
        type = "http";
        inputs = [ "containers_parsed" ];
        uri = "https://logs/insert/jsonline?_stream_fields=host,container_id,container_name";
        compression = "gzip";
        encoding.codec = "json";
        framing.method = "newline_delimited";
        # lotus-land-story's Caddy signs logs' certificate with the shared local root.
        tls.ca_file = "${./caddy-root.crt}";
        healthcheck.enabled = false;
      };
    };
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

  # Tailscale Serve stays on Rex's default port, 7297, since caddy holds 443.
  sops.secrets."rex/tailscale_login" = { };
  sops.templates."rex-accounts.jsonc" = {
    content = builtins.toJSON {
      version = 1;
      accounts.alpha.principals = [ "tailscale:${config.sops.placeholder."rex/tailscale_login"}" ];
    };
    reloadUnits = [ "rex-login-server.service" ];
  };
  services.rex.loginServer = {
    enable = true;
    accountsFile = config.sops.templates."rex-accounts.jsonc".path;
    tailscaleServe.enable = true;
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
