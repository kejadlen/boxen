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
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  services.tailscale = {
    enable = true;
    # Opens the WireGuard port so peers connect directly, not through DERP.
    openFirewall = true;
  };

  services.openssh = {
    enable = true;
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
