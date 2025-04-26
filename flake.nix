{
  description = "carbon";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: let
    inherit (nixpkgs) lib;

    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    linuxSystems = builtins.filter (lib.strings.hasSuffix "-linux") systems;
  in {
    devShell = lib.genAttrs lib.systems.flakeExposed (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in pkgs.mkShell {
      buildInputs = [
        pkgs.sops
        pkgs.nushell
      ];
    });

    packages = lib.genAttrs linuxSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in
      {
        carbon = let
          carbonScript = pkgs.stdenv.mkDerivation {
            name = "carbon-script";
            src = ./carbon;

            phases = [ "installPhase" ];

            installPhase = ''
              mkdir -p $out/bin
              cp $src $out/bin/carbon
              chmod +x $out/bin/carbon
            '';
          };
        in pkgs.writeScriptBin "carbon" ''
          #!${pkgs.bash}/bin/bash

          export PATH="${pkgs.sops}/bin:${pkgs.rage}/bin:$PATH"

          exec ${pkgs.nushell}/bin/nu ${carbonScript}/bin/carbon "$@"
        '';
      }
    );
  };
}
