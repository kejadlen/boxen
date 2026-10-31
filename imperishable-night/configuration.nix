{ modulesPath, ... }:

let
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPgX0tA28NO3djYaV++JxggR0t47xou+R0HQVwVjzj8s"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAmBthfb/WZo/cU1FFPQv8jAICTzkJIrNR1IMngUC3MB"
  ];
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
