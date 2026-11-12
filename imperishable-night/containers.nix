{
  config,
  lib,
  pkgs,
  ...
}:

let
  subnets = import ./subnets.nix;

  versions = {
    calibre-web = "0.6.26-ls383";
    homebox = "0.27.1";
    ketchup = "20260525-e75f249";
    miniflux = "2.3.5";
    paperless-ngx = "3.4.2";
    pro-tacts = "ruby-head-zjit"; # Pin once it's out of active development.
    redis = "8.10.3";
    soju = "0.11.1"; # Bump the docker-soju image first.
  };
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/calibre-web/books 0755 root root -"
    "d /var/lib/calibre-web/config 0755 root root -"
    # homebox's image runs as the distroless nonroot user.
    "d /var/lib/homebox 0755 65532 65532 -"
    "d /var/lib/ketchup 0755 root root -"
    # paperless-ngx's image runs as its default USERMAP_UID and USERMAP_GID.
    "d /var/lib/paperless-ngx/consume 0700 1000 1000 -"
    "d /var/lib/paperless-ngx/data 0700 1000 1000 -"
    "d /var/lib/paperless-ngx/export 0700 1000 1000 -"
    "d /var/lib/paperless-ngx/media 0700 1000 1000 -"
    "d /var/lib/pro-tacts 0755 root root -"
    "d /var/lib/soju 0755 root root -"
    "d /var/lib/quire 0755 quire quire -"
  ];

  # https://github.com/linuxserver/docker-calibre-web
  virtualisation.oci-containers.containers.calibre-web = {
    image = "lscr.io/linuxserver/calibre-web:${versions.calibre-web}";
    environment = {
      PUID = "0";
      PGID = "0";
      TZ = "Etc/UTC";
      DOCKER_MODS = "linuxserver/mods:universal-calibre";
    };
    volumes = [
      "/var/lib/calibre-web/books:/books"
      "/var/lib/calibre-web/config:/config"
    ];
    networks = [ "books" ];
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
    user = "${toString config.users.users.miniflux.uid}:${toString config.users.groups.miniflux.gid}";
    environment = {
      DATABASE_URL = "user=miniflux host=/run/postgresql dbname=miniflux";
      RUN_MIGRATIONS = "1";
      CREATE_ADMIN = "1";
      ADMIN_USERNAME = "alpha";
      AUTH_PROXY_HEADER = "Remote-User";
      AUTH_PROXY_USER_CREATION = "0";
      TRUSTED_REVERSE_PROXY_NETWORKS = subnets.rss;
      BASE_URL = "https://rss/";
      DISABLE_LOCAL_AUTH = "0";
      METRICS_COLLECTOR = "1";
      METRICS_ALLOWED_NETWORKS = subnets.rss;
      LOG_FORMAT = "json";
      LOG_LEVEL = "info";
    };
    environmentFiles = [ config.sops.templates."miniflux.env".path ];
    volumes = [ "/run/postgresql:/run/postgresql" ];
    networks = [ "rss" ];
  };

  # postgresql recreates /run/postgresql when it restarts, which strands
  # the container's bind mount of the old directory.
  systemd.services.podman-miniflux = {
    requires = [ "postgresql.target" ];
    after = [ "postgresql.target" ];
    partOf = [ "postgresql.service" ];
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

  # https://quire.kejadlen.dev/pro-tacts
  virtualisation.oci-containers.containers.pro-tacts = {
    image = "ghcr.io/kejadlen/pro-tacts:${versions.pro-tacts}";
    pull = "always";
    environment = {
      PRO_TACTS_DATA_DIR = "/data";
      PRO_TACTS_DEBUG = "true";
    };
    volumes = [ "/var/lib/pro-tacts:/data" ];
    networks = [ "pro-tacts" ];
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
}
