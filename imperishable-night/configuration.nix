{
  config,
  lib,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./caddy.nix
    ./containers.nix
    ./backup.nix
    ./observability.nix
  ];

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
    # Netavark DNATs Caddy's published ports to its address on any of its
    # networks, and the reply can leave by another bridge, which strict drops.
    checkReversePath = "loose";
  };

  # sops-nix decrypts with the age key derived from the SSH host key.
  sops.defaultSopsFile = ./secrets.sops.yml;

  # Socket logins authenticate as their OS user; TCP listens only on localhost.
  services.postgresql.enable = true;
  # Replaces the defaults so each role reaches only its namesake database and
  # nothing logs in over TCP.
  services.postgresql.authentication = lib.mkForce ''
    local all      postgres peer map=postgres
    local sameuser all      peer
  '';

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
