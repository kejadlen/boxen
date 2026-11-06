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

    # Its own nixpkgs, so its lock sets alpha's package versions on every machine.
    dotfiles.url = "git+https://github.com/kejadlen/dotfiles.git?shallow=1";
  };

  outputs =
    {
      nixpkgs,
      disko,
      sops-nix,
      dotfiles,
      ...
    }:
    {
      nixosConfigurations.legacy-of-lunatic-kingdom = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit dotfiles; };
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          ../modules/nixos/common.nix
          ./configuration.nix
          ./disk-config.nix
        ];
      };
    };
}
