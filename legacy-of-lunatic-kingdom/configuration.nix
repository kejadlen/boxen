{
  config,
  lib,
  pkgs,
  ...
}:

let
  dataDir = "/mnt/data";

  caddyRoot = ../modules/nixos/caddy-root.crt;

  podmanNetwork = "legacy_of_lunatic_kingdom";

  versions.caddy = "2.11.7-2026.10.07";
in
{
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # The eMMC controller, and USB for a keyboard at the console.
  boot.initrd.availableKernelModules = [
    "sdhci_pci"
    "xhci_pci"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;

  networking.hostName = "legacy-of-lunatic-kingdom";
  networking.useDHCP = false;
  networking.interfaces.enp1s0.useDHCP = true;

  # Assembles the existing data array, which holds no part of the OS.
  boot.swraid = {
    enable = true;
    mdadmConf = ''
      ARRAY /dev/md0 metadata=1.2 UUID=2e51b585:1ff8669c:b3568699:18ccde2c
      PROGRAM ${pkgs.writeShellScript "mdadm-event" ''
        exec ${pkgs.util-linux}/bin/logger -t mdadm -- "$@"
      ''}
    '';
  };

  # nofail lets the host boot without the array; services on it require the mount.
  fileSystems.${dataDir} = {
    device = "/dev/disk/by-uuid/cf73c98e-79f7-454f-9c64-3a60a7638452";
    fsType = "ext4";
    options = [
      "noatime"
      "nofail"
    ];
  };

  services.prometheus.exporters.node.extraFlags = [
    "--collector.filesystem.mount-points-exclude=^/(dev|proc|run|sys|media|var/lib/containers/storage/.+)($|/)"
  ];

  # `logs` is a tailnet Caddy site, not a host, so the URL outlives
  # VictoriaLogs moving off lotus-land-story.
  services.journald.upload = {
    enable = true;
    settings.Upload = {
      URL = "https://logs/insert/journald";
      TrustedCertificateFile = "${caddyRoot}";
    };
  };

  # Containers reach each other by name only on a user-defined network.
  systemd.services."podman-network-${podmanNetwork}" = {
    path = [ config.virtualisation.podman.package ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      podman network exists ${podmanNetwork} ||
        podman network create ${podmanNetwork}
    '';
  };

  # sops-nix decrypts with the age key derived from the SSH host key.
  sops.defaultSopsFile = ./secrets.sops.yml;
  sops.secrets."caddy/ts_authkey" = { };
  sops.secrets."caddy/ca_root_key".restartUnits = [ "podman-caddy.service" ];
  sops.templates."caddy.env" = {
    content = ''
      TS_AUTHKEY=${config.sops.placeholder."caddy/ts_authkey"}
    '';
    restartUnits = [ "podman-caddy.service" ];
  };

  virtualisation.oci-containers.containers.caddy = {
    image = "ghcr.io/kejadlen/caddy-kejadlen:${versions.caddy}";
    environmentFiles = [ config.sops.templates."caddy.env".path ];
    # VictoriaMetrics scrapes caddy's metrics endpoint.
    ports = [ "2019:2019" ];
    volumes = [
      "${./Caddyfile}:/etc/caddy/Caddyfile:ro"
      "${caddyRoot}:/etc/caddy/pki/root.crt:ro"
      "${config.sops.secrets."caddy/ca_root_key".path}:/etc/caddy/pki/root.key:ro"
      "${dataDir}/caddy/data:/data"
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
    unitConfig.RequiresMountsFor = [ "${dataDir}/caddy/data" ];
  };

  # Folders, devices, GUI credentials, and disk-free thresholds stay in the
  # config.xml carried over from Debian, so only the GUI address is declared.
  services.syncthing = {
    enable = true;
    # VictoriaMetrics scrapes :8384 over the tailnet.
    guiAddress = "0.0.0.0:8384";
    openDefaultPorts = true;
    overrideDevices = false;
    overrideFolders = false;
  };
  systemd.services.syncthing = {
    unitConfig.RequiresMountsFor = [ "${dataDir}/syncthing" ];
    # .stignore itself never syncs, so each device has to include the
    # patterns from the file that does.
    preStart = ''
      echo '#include .stignore.sync' > ${dataDir}/syncthing/sync/.stignore
    '';
  };

  # Debian allocated these IDs, and the files on the array still carry them.
  # NixOS would assign others (syncthing's module fixes its own at 237), which
  # would lock both services out of their data. mkForce overrides the module.
  users.users.syncthing.uid = lib.mkForce 999;
  users.groups.syncthing.gid = lib.mkForce 988;
  users.users.restic = {
    isSystemUser = true;
    uid = 997;
    group = "restic";
    # restrict also kills forwarding and pty at the auth layer.
    openssh.authorizedKeys.keys = map (key: "restrict ${key}") [
      # lotus-land-story
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILrlVay1GlpCuhYSUup/K/gRYmltycViPBAdZ8t9OKtu"
      # imperishable-night
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO+vpLtHN3CxcPFsp1IWzM9FKWMr1dBnZuPsjqC6d2te"
      # 1Password
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPgX0tA28NO3djYaV++JxggR0t47xou+R0HQVwVjzj8s"
    ];
  };
  users.groups.restic.gid = 986;

  # internal-sftp serves absolute paths, so the repository URL stays
  # sftp:restic@legacy-of-lunatic-kingdom:/mnt/data/restic.
  services.openssh.extraConfig = ''
    Match User restic
        ForceCommand internal-sftp
        AllowTcpForwarding no
        X11Forwarding no
  '';
}
