{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "aarch64-darwin"
        "x86_64-linux"
      ];
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          python = pkgs.python3.withPackages (
            ps: with ps; [
              # ansible is the collection bundle; ansible-core has the binaries.
              ansible
              ansible-core
              netaddr
              psycopg2
            ]
          );
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              age
              ansible-lint
              just
              nixfmt
              nixos-anywhere
              nixos-rebuild
              opentofu
              python
              rumdl
              shellcheck
              sops
              ssh-to-age
            ];

            # Collections come only from the bundle, not ~/.ansible or the
            # second copy that ansible-lint's dependencies put on sys.path.
            ANSIBLE_COLLECTIONS_PATH = "${python}/${python.sitePackages}";
            ANSIBLE_COLLECTIONS_SCAN_SYS_PATH = "False";
          };
        }
      );
    };
}
