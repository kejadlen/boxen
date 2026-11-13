{
  config,
  lib,
  pkgs,
  ...
}:

let
  subnets = import ./subnets.nix;

  versions = {
    authelia = "4.39.28";
    calibre-web = "0.6.26-ls383";
    gotosocial = "0.22.3";
    homebox = "0.27.1";
    ketchup = "20260525-e75f249";
    miniflux = "2.3.5";
    paperless-ngx = "3.4.2";
    pro-tacts = "ruby-head-zjit"; # Pin once it's out of active development.
    redis = "8.10.3";
    soju = "0.11.1"; # Bump the docker-soju image first.
  };

  # Secrets come from secrets.yml and the _FILE variables, so none reach the store.
  autheliaConfig = (pkgs.formats.yaml { }).generate "configuration.yml" {
    theme = "auto";
    log = {
      level = "debug";
      format = "json";
    };
    telemetry.metrics.enabled = true;
    authentication_backend = {
      file.path = "/config/users_database.yml";
      password_change.disable = true;
    };
    access_control = {
      default_policy = "deny";
      rules = [
        {
          domain = "*.chislan.family";
          policy = "two_factor";
          subject = [ "group:family" ];
        }
        {
          domain = "*.kejadlen.dev";
          policy = "two_factor";
          subject = [ "user:alpha" ];
        }
      ];
    };
    session.cookies = [
      {
        domain = "kejadlen.dev";
        authelia_url = "https://auth.kejadlen.dev";
      }
      {
        domain = "chislan.family";
        authelia_url = "https://auth.chislan.family";
      }
    ];
    storage.local.path = "/config/db.sqlite3";
    notifier.smtp = {
      address = "smtp://mail.smtp2go.com:2525";
      sender = "authelia@kejadlen.dev";
    };
    # https://www.authelia.com/integration/openid-connect/frequently-asked-questions/#how-do-i-generate-client-secrets
    identity_providers.oidc.clients = [
      {
        client_id = "tailscale";
        client_name = "Tailscale";
        client_secret = "$argon2id$v=19$m=65536,t=3,p=4$RivlSdV1WE/NLfd3Pzrubw$ljSvHj9sb0byolv7fk5G3nL415nS7Ze2RMASwPgfBX0";
        redirect_uris = [ "https://login.tailscale.com/a/oauth_response" ];
        scopes = [
          "openid"
          "email"
          "profile"
        ];
      }
      {
        client_id = "gotosocial";
        client_name = "GoToSocial";
        client_secret = "$argon2id$v=19$m=65536,t=3,p=4$Z3CabXEI+jrC/dfuvvPFsw$fL0qc12TwCi+k65Lt9NXr0bURH6vgEHAPnnWaEv20aU";
        public = false;
        redirect_uris = [ "https://hey.kejadlen.dev/auth/callback" ];
        scopes = [
          "openid"
          "email"
          "profile"
          "groups"
        ];
      }
    ];
  };
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/authelia 0700 root root -"
    "d /var/lib/calibre-web/books 0755 root root -"
    "d /var/lib/calibre-web/config 0755 root root -"
    "d /var/lib/gotosocial 0755 root root -"
    # gotosocial's image runs as 1000:1000.
    "d /var/lib/gotosocial/data 0755 1000 1000 -"
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

  sops.secrets."authelia/jwt_secret".restartUnits = [ "podman-authelia.service" ];
  sops.secrets."authelia/session_secret".restartUnits = [ "podman-authelia.service" ];
  sops.secrets."authelia/storage_encryption_key".restartUnits = [ "podman-authelia.service" ];
  sops.secrets."authelia/smtp_username".restartUnits = [ "podman-authelia.service" ];
  sops.secrets."authelia/smtp_password".restartUnits = [ "podman-authelia.service" ];
  sops.secrets."authelia/oidc_private_key".restartUnits = [ "podman-authelia.service" ];

  # https://www.authelia.com/configuration/prologue/introduction/
  virtualisation.oci-containers.containers.authelia = {
    image = "docker.io/authelia/authelia:${versions.authelia}";
    environment = {
      AUTHENTICATION_GUARD = "remote_user_guard";
      X_AUTHELIA_CONFIG = "/config/configuration.yml,/config/secrets.yml";
      # Lets secrets.yml read the values that have no _FILE variable.
      X_AUTHELIA_CONFIG_FILTERS = "template";
      AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE = "/secrets/jwt_secret";
      AUTHELIA_SESSION_SECRET_FILE = "/secrets/session_secret";
      AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE = "/secrets/storage_encryption_key";
      AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE = "/secrets/smtp_password";
    };
    volumes = [
      "/var/lib/authelia:/config"
      "${autheliaConfig}:/config/configuration.yml:ro"
      "${pkgs.writeText "authelia-secrets.yml" ''
        notifier:
          smtp:
            username: {{ secret "/secrets/smtp_username" | msquote }}
        identity_providers:
          oidc:
            jwks:
              - key: {{ secret "/secrets/oidc_private_key" | mindent 10 "|" | msquote }}
      ''}:/config/secrets.yml:ro"
      "${config.sops.secrets."authelia/jwt_secret".path}:/secrets/jwt_secret:ro"
      "${config.sops.secrets."authelia/session_secret".path}:/secrets/session_secret:ro"
      "${config.sops.secrets."authelia/storage_encryption_key".path}:/secrets/storage_encryption_key:ro"
      "${config.sops.secrets."authelia/smtp_username".path}:/secrets/smtp_username:ro"
      "${config.sops.secrets."authelia/smtp_password".path}:/secrets/smtp_password:ro"
      "${config.sops.secrets."authelia/oidc_private_key".path}:/secrets/oidc_private_key:ro"
    ];
    networks = [ "authelia" ];
  };

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

  # Podman writes container env to disk, and gotosocial has no _FILE variables.
  sops.secrets."gotosocial/oidc_client_secret" = { };
  # https://codeberg.org/superseriousbusiness/gotosocial/src/tag/v0.22.3/example/config.yaml
  sops.templates."gotosocial.yaml" = {
    # gotosocial's image runs as 1000:1000.
    uid = 1000;
    gid = 1000;
    file = (pkgs.formats.yaml { }).generate "gotosocial.yaml" {
      host = "hey.kejadlen.dev";
      trusted-proxies = [ subnets.gotosocial ];
      landing-page-user = "alpha";
      db-type = "sqlite";
      db-address = "/gotosocial/storage/sqlite.db";
      oidc-enabled = true;
      oidc-idp-name = "Authelia";
      oidc-issuer = "https://auth.kejadlen.dev";
      oidc-client-id = "gotosocial";
      oidc-client-secret = config.sops.placeholder."gotosocial/oidc_client_secret";
      oidc-admin-groups = [ "admin" ];
      metrics-enabled = true;
      # Tailscale's default CGNAT range, exempted from rate limiting.
      advanced-rate-limit-exceptions = [ "100.64.0.0/10" ];
      statuses-cleanup-remote-older-than = "1 year";
    };
    restartUnits = [ "podman-gotosocial.service" ];
  };

  # https://docs.gotosocial.org/en/latest/getting_started/installation/container/
  virtualisation.oci-containers.containers.gotosocial = {
    image = "docker.io/superseriousbusiness/gotosocial:${versions.gotosocial}";
    # OpenTelemetry reads only its own env vars, not gotosocial's config.
    environment = {
      GTS_CONFIG_PATH = "/gotosocial/config.yaml";
      OTEL_METRICS_PRODUCERS = "prometheus";
      OTEL_METRICS_EXPORTER = "prometheus";
      OTEL_EXPORTER_PROMETHEUS_HOST = "gotosocial";
      TZ = "UTC";
    };
    volumes = [
      "/var/lib/gotosocial/data:/gotosocial/storage"
      "${config.sops.templates."gotosocial.yaml".path}:/gotosocial/config.yaml:ro"
    ];
    networks = [ "gotosocial" ];
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

  sops.secrets."miniflux/password" = {
    owner = "miniflux";
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
      ADMIN_PASSWORD_FILE = "/etc/miniflux/admin_password";
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
    volumes = [
      "/run/postgresql:/run/postgresql"
      "${config.sops.secrets."miniflux/password".path}:/etc/miniflux/admin_password:ro"
    ];
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
