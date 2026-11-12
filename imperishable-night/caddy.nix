{
  config,
  lib,
  pkgs,
  ...
}:

let
  subnets = import ./subnets.nix;

  # Each app shares a network only with Caddy, so no other container can
  # reach it and forge the headers that header-trust apps take as a login.
  podmanNetworks = {
    caddy = "--subnet ${subnets.caddy}";
    books = "";
    docs = "";
    homebox = "";
    irc = "";
    ketchup = "";
    quire = "";
    rss = "--subnet ${subnets.rss}";
    # paperless-ngx's other network is its way out, so redis gets none.
    paperless = "--internal";
    pro-tacts = "";
  };

  versions = {
    caddy = "2.11.9-2026.11.06";
    gamja = "caf6e99";
  };

  # Bumping the version needs a new hash.
  gamja = pkgs.fetchzip {
    url = "https://github.com/kejadlen/gamja-build/releases/download/gamja-${versions.gamja}/gamja.tar.gz";
    hash = "sha256-Pv12p9VDkWMAz/qfTEjIXQrNglMVXC3jBn3wLpYXSbQ=";
  };
in
{
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
  ];

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
      "${pkgs.replaceVars ./Caddyfile { trusted_proxies = subnets.caddy; }}:/etc/caddy/Caddyfile:ro"
      "${../modules/nixos/caddy-root.crt}:/etc/caddy/pki/root.crt:ro"
      "${config.sops.secrets."caddy/ca_root_key".path}:/etc/caddy/pki/root.key:ro"
      "/var/lib/caddy/data:/data"
      "/var/lib/caddy/config:/config"
      "${gamja}:/srv/gamja:ro"
    ];
    networks = [
      "caddy"
      "books"
      "docs"
      "homebox"
      "irc"
      "ketchup"
      "pro-tacts"
      "quire"
      "rss"
    ];
    # Unbounded, caddy takes the host down with it. Equal memory-swap denies swap.
    extraOptions = [
      "--memory=1g"
      "--memory-swap=1g"
    ];
  };
}
