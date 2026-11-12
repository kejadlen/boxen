{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:

let
  caddyRoot = ../modules/nixos/caddy-root.crt;

  # Fixed so the Caddyfile can trust it; podman assigns subnets on creation otherwise.
  caddySubnet = "10.89.0.0/24";
  # Fixed so miniflux can trust Caddy's address on it. Podman assigns from the
  # bottom of 10.89.0.0/16, so the top stays clear.
  rssSubnet = "10.89.255.0/24";

  # Each app shares a network only with Caddy, so no other container can
  # reach it and forge the headers that header-trust apps take as a login.
  podmanNetworks = {
    # Caddy gets a default route from every network it joins, all at metric 100,
    # and replies to published ports dropped when one left by another bridge.
    caddy = "--subnet ${caddySubnet} --opt metric=50";
    docs = "";
    homebox = "";
    irc = "";
    ketchup = "";
    quire = "";
    rss = "--subnet ${rssSubnet}";
    # paperless-ngx's other network is its way out, so redis gets none.
    paperless = "--internal";
  };

  versions = {
    caddy = "2.11.9-2026.11.06";
    gamja = "caf6e99";
    homebox = "0.27.1";
    ketchup = "20260525-e75f249";
    miniflux = "2.3.5";
    paperless-ngx = "3.4.2";
    redis = "8.10.3";
    soju = "0.11.1"; # Bump the docker-soju image first.
  };

  # Bumping the version needs a new hash.
  gamja = pkgs.fetchzip {
    url = "https://github.com/kejadlen/gamja-build/releases/download/gamja-${versions.gamja}/gamja.tar.gz";
    hash = "sha256-Pv12p9VDkWMAz/qfTEjIXQrNglMVXC3jBn3wLpYXSbQ=";
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
    allowedTCPPorts = [
      80
      443
    ];
    # HTTP/3.
    allowedUDPPorts = [ 443 ];
  };

  # Containers reach each other by name only on a user-defined network.
  systemd.services = lib.mkMerge [
    (lib.mapAttrs' (
      name: args:
      lib.nameValuePair "podman-network-${name}" {
        path = [ config.virtualisation.podman.package ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          podman network exists ${name} ||
            podman network create ${args} ${name}
        '';
      }
    ) podmanNetworks)
    (lib.mapAttrs' (
      name: container:
      let
        units = map (network: "podman-network-${network}.service") container.networks;
      in
      lib.nameValuePair "podman-${name}" {
        requires = units;
        after = units;
      }
    ) config.virtualisation.oci-containers.containers)
    {
      # postgresql recreates /run/postgresql when it restarts, which strands
      # the container's bind mount of the old directory.
      podman-miniflux = {
        requires = [ "postgresql.target" ];
        after = [ "postgresql.target" ];
        partOf = [ "postgresql.service" ];
      };
    }
  ];

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
    "d /var/lib/ketchup 0755 root root -"
    # paperless-ngx's image runs as its default USERMAP_UID and USERMAP_GID.
    "d /var/lib/paperless-ngx/consume 0700 1000 1000 -"
    "d /var/lib/paperless-ngx/data 0700 1000 1000 -"
    "d /var/lib/paperless-ngx/export 0700 1000 1000 -"
    "d /var/lib/paperless-ngx/media 0700 1000 1000 -"
    "d /var/lib/postgresql-dump 0700 root root -"
    "d /var/lib/soju 0755 root root -"
    "d /var/lib/quire 0755 quire quire -"
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
        pkgs.replaceVars ./Caddyfile { trusted_proxies = caddySubnet; }
      }:/etc/caddy/Caddyfile:ro"
      "${caddyRoot}:/etc/caddy/pki/root.crt:ro"
      "${config.sops.secrets."caddy/ca_root_key".path}:/etc/caddy/pki/root.key:ro"
      "/var/lib/caddy/data:/data"
      "/var/lib/caddy/config:/config"
      "${gamja}:/srv/gamja:ro"
    ];
    networks = [
      "caddy"
      "docs"
      "homebox"
      "irc"
      "ketchup"
      "quire"
      "rss"
    ];
    # Unbounded, caddy takes the host down with it. Equal memory-swap denies swap.
    extraOptions = [
      "--memory=1g"
      "--memory-swap=1g"
    ];
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
    networks = [ "homebox" ];
  };

  sops.secrets."ketchup/session_secret" = { };
  sops.secrets."ketchup/otel_exporter_otlp_headers" = { };
  sops.templates."ketchup.env" = {
    content = ''
      SESSION_SECRET=${config.sops.placeholder."ketchup/session_secret"}
      OTEL_EXPORTER_OTLP_HEADERS=${config.sops.placeholder."ketchup/otel_exporter_otlp_headers"}
    '';
    restartUnits = [ "podman-ketchup.service" ];
  };

  virtualisation.oci-containers.containers.ketchup = {
    image = "ghcr.io/kejadlen/ketchup:${versions.ketchup}";
    environment = {
      AUTH_HEADER = "Tailscale-User-Login";
      DATABASE_URL = "/data/ketchup.db";
      OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf";
      OTEL_EXPORTER_OTLP_ENDPOINT = "https://api.honeycomb.io";
      TZ = "America/Los_Angeles";
    };
    environmentFiles = [ config.sops.templates."ketchup.env".path ];
    volumes = [ "/var/lib/ketchup:/data" ];
    networks = [ "ketchup" ];
  };

  # Peer auth maps the container's uid to the miniflux role, so the role has no password.
  users.groups.miniflux.gid = 399;
  users.users.miniflux = {
    isSystemUser = true;
    uid = 399;
    group = "miniflux";
  };

  services.postgresql = {
    ensureDatabases = [ "miniflux" ];
    ensureUsers = [
      {
        name = "miniflux";
        ensureDBOwnership = true;
      }
    ];
  };

  sops.secrets."miniflux/password" = { };
  sops.templates."miniflux.env" = {
    content = ''
      ADMIN_PASSWORD=${config.sops.placeholder."miniflux/password"}
    '';
    restartUnits = [ "podman-miniflux.service" ];
  };

  # https://miniflux.app/docs/configuration.html
  virtualisation.oci-containers.containers.miniflux = {
    image = "docker.io/miniflux/miniflux:${versions.miniflux}";
    # Stays stopped until its database is restored from lotus-land-story.
    autoStart = false;
    user = "${toString config.users.users.miniflux.uid}:${toString config.users.groups.miniflux.gid}";
    environment = {
      DATABASE_URL = "user=miniflux host=/run/postgresql dbname=miniflux";
      RUN_MIGRATIONS = "1";
      CREATE_ADMIN = "1";
      ADMIN_USERNAME = "alpha";
      AUTH_PROXY_HEADER = "Remote-User";
      AUTH_PROXY_USER_CREATION = "0";
      TRUSTED_REVERSE_PROXY_NETWORKS = rssSubnet;
      BASE_URL = "https://rss/";
      DISABLE_LOCAL_AUTH = "0";
      METRICS_COLLECTOR = "1";
      METRICS_ALLOWED_NETWORKS = rssSubnet;
      LOG_FORMAT = "json";
      LOG_LEVEL = "info";
    };
    environmentFiles = [ config.sops.templates."miniflux.env".path ];
    volumes = [ "/run/postgresql:/run/postgresql" ];
    networks = [ "rss" ];
  };

  # paperless-ngx's Celery broker; nothing in it is worth persisting.
  virtualisation.oci-containers.containers.redis = {
    image = "docker.io/library/redis:${versions.redis}";
    networks = [ "paperless" ];
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
    networks = [
      "docs"
      "paperless"
    ];
  };

  # gamja reaches soju through Caddy's /socket, so neither listener is published.
  virtualisation.oci-containers.containers.soju = {
    image = "ghcr.io/kejadlen/soju:${versions.soju}";
    volumes = [
      "/var/lib/soju:/soju"
      "${pkgs.writeText "soju.conf" ''
        listen irc+insecure://0.0.0.0:6697
        listen ws+insecure://0.0.0.0:3030
        listen http+prometheus://localhost:9090

        db sqlite3 /soju/soju.db
      ''}:/soju/soju.conf:ro"
    ];
    networks = [ "irc" ];
  };

  # The container runs as quire's uid so the repositories' ownership matches
  # inside and out, and sshd dispatches the quire user's git commands into it.
  users.groups.quire.gid = 1001;
  users.users.quire = {
    isNormalUser = true;
    uid = 1001;
    group = "quire";
    # Reaches the root podman socket for the ForceCommand's podman exec.
    extraGroups = [ "podman" ];
    openssh.authorizedKeys.keys = config.users.users.alpha.openssh.authorizedKeys.keys;
  };

  services.openssh = {
    # Public so the work laptop, which isn't on the tailnet, can push to quire.
    openFirewall = lib.mkForce true;
    settings.AllowUsers = [
      "quire"
      "alpha@100.64.0.0/10"
      "alpha@fd7a:115c:a1e0::/48"
    ];
    # NixOS writes extraConfig through an unquoted heredoc, which would expand
    # $SSH_ORIGINAL_COMMAND at build time, so a script reads it instead.
    extraConfig = ''
      Match User quire
          ForceCommand ${pkgs.writeShellScript "quire-ssh" ''
            exec ${config.virtualisation.podman.package}/bin/podman --remote --url unix:///run/podman/podman.sock \
              exec --interactive quire quire exec "$SSH_ORIGINAL_COMMAND"
          ''}
          # Unlike AllowTcpForwarding, also blocks forwarding to the podman socket.
          DisableForwarding yes
          PermitTTY no
    '';
  };

  sops.secrets."quire/github_mirror" = {
    owner = "quire";
    restartUnits = [ "podman-quire.service" ];
  };
  sops.secrets."quire/github_auth_header" = {
    owner = "quire";
    restartUnits = [ "podman-quire.service" ];
  };
  sops.secrets."quire/sentry_dsn" = { };
  sops.templates."quire-config.fnl" = {
    owner = "quire";
    content = ''
      {:host "quire.kejadlen.dev"
       :secrets {:github_auth_header {:file "/var/quire/secrets/github_auth_header"}
                 :github-mirror {:file "/var/quire/secrets/github_mirror"}}
       :sentry {:dsn "${config.sops.placeholder."quire/sentry_dsn"}"}}
    '';
    restartUnits = [ "podman-quire.service" ];
  };

  virtualisation.oci-containers.containers.quire = {
    image = "ghcr.io/kejadlen/quire:latest";
    pull = "always";
    user = "${toString config.users.users.quire.uid}:${toString config.users.groups.quire.gid}";
    environment.QUIRE_LOG = "INFO";
    volumes = [
      "/var/lib/quire:/var/quire"
      "${config.sops.templates."quire-config.fnl".path}:/var/quire/config.fnl:ro"
      "${config.sops.secrets."quire/github_mirror".path}:/var/quire/secrets/github_mirror:ro"
      "${config.sops.secrets."quire/github_auth_header".path}:/var/quire/secrets/github_auth_header:ro"
    ];
    networks = [ "quire" ];
  };

  # Socket logins authenticate as their OS user; TCP listens only on localhost.
  services.postgresql.enable = true;

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
      # A file-level copy of the running cluster isn't restorable; the dump is.
      exclude = [
        "/var/lib/containers"
        "/var/lib/postgresql"
      ];
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
      # Last, so a failed dump fails the run. The rename keeps the previous dump if it does.
      backupPrepareCommand = ''
        date +%s > /run/restic-backups-daily/start
        ${ping "/start"}
        ${pkgs.util-linux}/bin/runuser -u postgres -- ${config.services.postgresql.package}/bin/pg_dumpall \
          > /var/lib/postgresql-dump/pg_dumpall.sql.tmp &&
          mv /var/lib/postgresql-dump/pg_dumpall.sql.tmp /var/lib/postgresql-dump/pg_dumpall.sql
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

          if includes(["caddy", "miniflux"], event.container_name) {
            # Startup errors and panics go to stderr as plain text.
            parsed, err = parse_json(message)
            if err == null && is_object(parsed) {
              event = merge(event, object!(parsed))
              if event.container_name == "caddy" {
                event._time = del(event.ts)
              }
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
        tls.ca_file = "${caddyRoot}";
        healthcheck.enabled = false;
      };
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
}
