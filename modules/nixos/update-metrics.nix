# Exports how far each host is behind its nixpkgs branch, and whether it
# needs a reboot, for the personal dashboard's update tiles.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  textfileDir = "/var/lib/node-exporter-textfile";

  script = pkgs.writeShellApplication {
    name = "update-metrics";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
    ];
    text = builtins.readFile ./update-metrics.sh;
  };
in
{
  assertions = [
    {
      assertion = config.system.nixos.revision != null;
      message = "update-metrics needs system.nixos.revision, which nixpkgs sets when used as a flake input.";
    }
  ];

  services.prometheus.exporters.node.extraFlags = [
    "--collector.textfile.directory=${textfileDir}"
  ];

  systemd.services.update-metrics = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment = {
      TEXTFILE_DIR = textfileDir;
      BRANCH = "nixos-${config.system.nixos.release}";
      REVISION = config.system.nixos.revision;
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe script;
      StateDirectory = baseNameOf textfileDir;
    };
  };

  # Two calls an hour, well under GitHub's unauthenticated limit of 60.
  systemd.timers.update-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "1h";
    };
  };
}
