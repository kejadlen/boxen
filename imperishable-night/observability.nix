{
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
        # lotus-land-story's Caddy signs logs' certificate with the shared local root.
        tls.ca_file = "${../modules/nixos/caddy-root.crt}";
        healthcheck.enabled = false;
      };
    };
  };
}
