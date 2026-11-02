{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    rex = {
      url = "https://pkgs.superlogical.com/rex/nix/preview.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      disko,
      sops-nix,
      rex,
      ...
    }:
    {
      nixosConfigurations.imperishable-night = nixpkgs.lib.nixosSystem {
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          rex.nixosModules.default
          ./configuration.nix
          ./disk-config.nix
        ];
      };
    };
}
