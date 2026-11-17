{
  config,
  pkgs,
  ...
}:

let
  subnets = import ./subnets.nix;

  caddyRoot = ../modules/nixos/caddy-root.crt;

  versions = {
    grafana = "12.4.3";
    victoria-logs = "v1.44.0";
    victoria-metrics = "v1.155.0";
    victoria-traces = "v0.9.0";
  };

  # The image runs as grafana's uid, with root's group.
  grafanaUid = 472;

  grafanaIni = (pkgs.formats.ini { }).generate "grafana.ini" {
    metrics = {
      enabled = true;
      disable_total_stats = false;
    };
    server = {
      domain = "grafana";
      http_addr = "0.0.0.0";
      root_url = "https://grafana";
    };
    # https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/auth-proxy/
    auth.disable_signout_menu = true;
    "auth.proxy" = {
      enabled = true;
      header_name = "X-WEBAUTH-USER";
      header_property = "email";
      auto_sign_up = false;
      whitelist = subnets.grafana;
    };
    smtp = {
      enabled = true;
      host = "smtp.sendgrid.net:465";
      user = "apikey";
      password = "$__file{/secrets/smtp_password}";
      from_address = "grafana@kejadlen.dev";
    };
    plugins.plugin_admin_enabled = true;
  };

  grafanaDatasources = (pkgs.formats.yaml { }).generate "datasources.yml" {
    apiVersion = 1;
    datasources = [
      {
        name = "VictoriaLogs";
        type = "victoriametrics-logs-datasource";
        access = "proxy";
        url = "http://victoria-logs:9428";
      }
      {
        name = "VictoriaMetrics";
        type = "victoriametrics-metrics-datasource";
        access = "proxy";
        url = "http://victoria-metrics:8428";
        isDefault = true;
      }
      # Jaeger rather than Tempo: VictoriaTraces' Tempo API needs v0.9.4+.
      {
        name = "VictoriaTraces";
        type = "jaeger";
        access = "proxy";
        url = "http://victoria-traces:10428/select/jaeger";
      }
    ];
  };

  # allowUiUpdates is false so the repository stays the source of truth.
  grafanaDashboards = (pkgs.formats.yaml { }).generate "dashboards.yml" {
    apiVersion = 1;
    providers = [
      {
        name = "default";
        type = "file";
        allowUiUpdates = false;
        updateIntervalSeconds = 30;
        options.path = "/etc/grafana/dashboards";
      }
    ];
  };

  scrapeSecrets = [
    "home_assistant/access_token"
    "linode/api_token"
    "syncthing/legacy_of_lunatic_kingdom/api_key"
  ];
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/grafana 0755 ${toString grafanaUid} 0 -"
    "d /var/lib/victoria-logs 0755 root root -"
    "d /var/lib/victoria-metrics 0755 root root -"
    "d /var/lib/victoria-traces 0755 root root -"
  ];

  sops.secrets = {
    "grafana/smtp_password" = {
      uid = grafanaUid;
      restartUnits = [ "podman-grafana.service" ];
    };
  }
  // builtins.listToAttrs (
    map (name: {
      inherit name;
      value.restartUnits = [ "podman-victoria-metrics.service" ];
    }) scrapeSecrets
  );

  virtualisation.oci-containers.containers.grafana = {
    image = "docker.io/grafana/grafana:${versions.grafana}";
    environment.GF_PLUGINS_PREINSTALL = "victoriametrics-logs-datasource, victoriametrics-metrics-datasource";
    volumes = [
      "${grafanaIni}:/etc/grafana/grafana.ini:ro"
      "${grafanaDatasources}:/etc/grafana/provisioning/datasources/datasources.yml:ro"
      "${grafanaDashboards}:/etc/grafana/provisioning/dashboards/dashboards.yml:ro"
      "${./dashboards}:/etc/grafana/dashboards:ro"
      "${config.sops.secrets."grafana/smtp_password".path}:/secrets/smtp_password:ro"
      "/var/lib/grafana:/var/lib/grafana"
    ];
    networks = [
      "grafana"
      "observability"
    ];
  };

  virtualisation.oci-containers.containers.victoria-metrics = {
    image = "quay.io/victoriametrics/victoria-metrics:${versions.victoria-metrics}";
    cmd = [
      "-selfScrapeInterval=5s"
      # Keeps a year of deploy markers, rather than the default month.
      "-retentionPeriod=1y"
      "-storageDataPath=/victoria-metrics-data"
      "-promscrape.config=/scrape.yml"
    ];
    volumes = [
      "/var/lib/victoria-metrics:/victoria-metrics-data"
      "${./scrape.yml}:/scrape.yml:ro"
      "${caddyRoot}:/caddy-root.crt:ro"
    ]
    ++ map (
      name:
      "${config.sops.secrets.${name}.path}:/secrets/${builtins.replaceStrings [ "/" ] [ "_" ] name}:ro"
    ) scrapeSecrets;
    networks = [
      "metrics"
      "observability"
    ];
    # The host's /etc/hosts, podman's default base, maps imperishable-night to 127.0.0.2.
    extraOptions = [ "--hosts-file=none" ];
  };

  virtualisation.oci-containers.containers.victoria-logs = {
    image = "quay.io/victoriametrics/victoria-logs:${versions.victoria-logs}";
    cmd = [ "-storageDataPath=/data" ];
    volumes = [ "/var/lib/victoria-logs:/data" ];
    networks = [
      "logs"
      "observability"
    ];
  };

  virtualisation.oci-containers.containers.victoria-traces = {
    image = "quay.io/victoriametrics/victoria-traces:${versions.victoria-traces}";
    cmd = [ "-storageDataPath=/data" ];
    volumes = [ "/var/lib/victoria-traces:/data" ];
    networks = [
      "traces"
      "observability"
    ];
  };

  # VictoriaMetrics' scrapes of the host's tailnet name arrive on the metrics
  # bridge, not tailscale0.
  networking.firewall.interfaces.podman-metrics.allowedTCPPorts = [
    8080 # cadvisor
    9100 # node-exporter
  ];

  # VictoriaMetrics scrapes :8080 over the tailnet; the port stays closed publicly.
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

  # Ships container logs, which podman writes to journald, to VictoriaLogs.
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

          if includes(["authelia", "caddy", "miniflux"], event.container_name) {
            # Startup errors and panics go to stderr as plain text.
            parsed, err = parse_json(message)
            if err == null && is_object(parsed) {
              event = merge(event, object!(parsed))
              if event.container_name == "caddy" {
                event._time = del(event.ts)
              }
              event._msg = del(event.msg)
            }
          } else if event.container_name == "gotosocial" {
            # Panics are plain text, which parse_key_value would split into junk fields.
            parsed, err = parse_key_value(message)
            if err == null && exists(parsed.timestamp) {
              event = merge(event, parsed)
              event._time = parse_timestamp(del(event.timestamp), format: "%d/%m/%Y %H:%M:%S%.3f", timezone: "UTC") ?? event._time
              event._msg = string(del(event.msg)) ?? message
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
        # Caddy signs logs' certificate with the shared local root.
        tls.ca_file = "${../modules/nixos/caddy-root.crt}";
        healthcheck.enabled = false;
      };
    };
  };
}
