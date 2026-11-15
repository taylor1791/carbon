{
  description = "carbon";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: let
    inherit (nixpkgs) lib;

    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    linuxSystems = builtins.filter (lib.strings.hasSuffix "-linux") systems;

    # bats finds its helper libraries through BATS_LIB_PATH rather than a
    # lockfile, so every consumer of the test suite has to build the same list.
    batsLibraries = pkgs: with pkgs.bats.libraries; [
      bats-support
      bats-assert
      bats-file
    ];

    batsLibPath = pkgs:
      lib.concatMapStringsSep ":" (l: "${l}/share/bats") (batsLibraries pkgs);

    # Everything the suite shells out to: carbon's own dependencies plus git,
    # because each test builds a throwaway repo to run against.
    testInputs = pkgs: with pkgs; [
      bats
      parallel # bats --jobs shells out to GNU parallel
      nushell
      sops
      rage
      git
      jq
      coreutils
    ] ++ batsLibraries pkgs;
  in {
    devShell = lib.genAttrs lib.systems.flakeExposed (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in pkgs.mkShell {
      buildInputs = testInputs pkgs;

      BATS_LIB_PATH = batsLibPath pkgs;

      shellHook = ''
        echo "carbon dev shell. run the tests with: bats --jobs 8 test/"
      '';
    });

    checks = lib.genAttrs linuxSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      tests = pkgs.runCommand "carbon-tests" {
        nativeBuildInputs = testInputs pkgs;
        BATS_LIB_PATH = batsLibPath pkgs;
      } ''
        cp -r ${self} source
        chmod -R u+w source
        cd source

        # git and rage both want a writable home.
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"

        # The wrapper tier needs `nix build`, which cannot run inside this
        # sandbox. CI covers it separately with CARBON_TEST_WRAPPER=1.
        bats --jobs 4 test/

        touch $out
      '';
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

          export PATH="${lib.makeBinPath [ pkgs.git pkgs.rage pkgs.sops ]}:$PATH"

          exec ${pkgs.nushell}/bin/nu ${carbonScript}/bin/carbon "$@"
        '';
      }
    );
  };
}
