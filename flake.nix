{
  description = "network-control-plane-model";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-network.url = "github:NixOS/nixpkgs/ac56c456ebe4901c561d3ebf1c98fbd970aea753";

    network-forwarding-model.url = "github:esp0xdeadbeef/network-forwarding-model";
    network-forwarding-model.inputs.nixpkgs.follows = "nixpkgs";

    # Used by test scripts as a flake-locked source of intent/inventory fixtures.
    network-labs.url = "github:esp0xdeadbeef/network-labs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-network,
      network-forwarding-model,
      network-labs,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAll = f: nixpkgs.lib.genAttrs systems f;

      readValue =
        valueOrPath:
        if builtins.isPath valueOrPath then
          readValue (builtins.toString valueOrPath)
        else if builtins.isString valueOrPath then
          if valueOrPath == "" then
            { }
          else if builtins.match ".*\\.json$" valueOrPath != null then
            builtins.fromJSON (builtins.readFile valueOrPath)
          else
            let
              value = import valueOrPath;
            in
            if builtins.isFunction value then value { } else value
        else if builtins.isFunction valueOrPath then
          valueOrPath { }
        else
          valueOrPath;

      mkPkgs =
        system:
        let
          patchedPkgs = import nixpkgs-network { inherit system; };
          patchedNetwork = patchedPkgs.lib.network;
        in
        import nixpkgs {
          inherit system;
          overlays = [
            (final: prev: {
              lib = prev.lib // {
                network = patchedNetwork;
              };
            })
          ];
        };

      mkSystemLib =
        system:
        let
          pkgs = mkPkgs system;
          lib = pkgs.lib;

          buildCPM = import ./src/build-cpm.nix { inherit lib; };

          forwardingLib =
            if network-forwarding-model ? libBySystem then
              network-forwarding-model.libBySystem.${system}
            else
              throw "network-control-plane-model: network-forwarding-model.libBySystem.${system} is required for compileAndBuild";
        in
        rec {
          build =
            {
              input,
              inventory ? { },
            }:
            import ./src/main.nix {
              inherit input inventory lib;
            };

          get_CPM =
            {
              input,
              inventory ? { },
            }:
            buildCPM {
              forwardingModel = input;
              inherit inventory;
            };

          getCPM = get_CPM;

          readInput = readValue;

          compileAndBuild =
            {
              input,
              inventory ? { },
            }:
            build {
              input = forwardingLib.buildFromCompilerInputs { inherit input; };
              inherit inventory;
            };

          compileAndBuildFromPaths =
            {
              inputPath,
              inventoryPath ? null,
            }:
            compileAndBuild {
              input = readValue inputPath;
              inventory =
                if inventoryPath == null then
                  { }
                else
                  readValue inventoryPath;
            };

          writeJSON =
            {
              input,
              inventory ? { },
              name ? "output-control-plane-model.json",
            }:
            pkgs.writeText name (builtins.toJSON (build { inherit input inventory; }));

          writeCompileAndBuildJSON =
            {
              inputPath,
              inventoryPath ? null,
              name ? "output-control-plane-model.json",
            }:
            pkgs.writeText name (
              builtins.toJSON (
                compileAndBuildFromPaths {
                  inherit
                    inputPath
                    inventoryPath
                    ;
                }
              )
            );
        };
    in
    {
      lib = forAll mkSystemLib;

      libBySystem = forAll mkSystemLib;

      packages = forAll (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          debug = pkgs.writeShellApplication {
            name = "network-control-plane-model-debug";

            runtimeInputs = [
              pkgs.jq
              pkgs.git
              pkgs.nix
              pkgs.coreutils
            ];

            text = ''
              set -euo pipefail

              case "$#" in
                1)
                  INPUT="$1"
                  INVENTORY=""
                  OUTPUT="./output-control-plane-model.json"
                  ;;
                2)
                  INPUT="$1"
                  INVENTORY="$2"
                  OUTPUT="./output-control-plane-model.json"
                  ;;
                *)
                  INPUT="$1"
                  INVENTORY="$2"
                  OUTPUT="$3"
                  ;;
              esac

              expr="$(cat <<EOF
              let
                flake = builtins.getFlake (toString ${self.outPath});
                builder = flake.lib.${system}.build;
                readValue =
                  path:
                  if path == "" then
                    {}
                  else if builtins.match ".*\\.json$" path != null then
                    builtins.fromJSON (builtins.readFile path)
                  else
                    import path;
              in
                builder {
                  input = readValue (builtins.getEnv "INPUT");
                  inventory = readValue (builtins.getEnv "INVENTORY");
                }
              EOF
              )"

              json="$(
                INPUT="$INPUT" INVENTORY="$INVENTORY" nix eval --impure --no-write-lock-file --json --expr "$expr"
              )"

              gitRev="$(${pkgs.git}/bin/git rev-parse HEAD 2>/dev/null || echo "unknown")"
              gitDirty=false
              if ${pkgs.git}/bin/git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                if ${pkgs.git}/bin/git diff --quiet >/dev/null 2>&1 && ${pkgs.git}/bin/git diff --cached --quiet >/dev/null 2>&1; then
                  gitDirty=false
                else
                  gitDirty=true
                fi
              fi

              echo "$json" | ${pkgs.jq}/bin/jq -S -c \
                --arg rev "$gitRev" \
                --argjson dirty "$gitDirty" \
                '.control_plane_model.meta = (.control_plane_model.meta // {})
                 | .control_plane_model.meta.networkControlPlaneModel =
                     ((.control_plane_model.meta.networkControlPlaneModel // {})
                      + { name: "network-control-plane-model", gitRev: $rev, gitDirty: $dirty })' \
                | tee "$OUTPUT" \
                | ${pkgs.jq}/bin/jq -S
            '';
          };

          compile-and-build-control-plane-model = pkgs.writeShellApplication {
            name = "compile-and-build-control-plane-model";

            runtimeInputs = [
              pkgs.nix
              pkgs.coreutils
            ];

            text = ''
              set -euo pipefail

              case "$#" in
                1)
                  INPUTS_NIX="$1"
                  INVENTORY=""
                  OUTPUT="./output-control-plane-model.json"
                  ;;
                2)
                  INPUTS_NIX="$1"
                  INVENTORY="$2"
                  OUTPUT="./output-control-plane-model.json"
                  ;;
                *)
                  INPUTS_NIX="$1"
                  INVENTORY="$2"
                  OUTPUT="$3"
                  ;;
              esac

              # Nix path coercion is strict: inventory and input paths must be absolute.
              # Make the wrapper resilient so docs and scripts can use relative paths.
              INPUTS_NIX="$(realpath "$INPUTS_NIX")"
              if [ -n "$INVENTORY" ]; then
                INVENTORY="$(realpath "$INVENTORY")"
              fi

              FORWARDING_JSON="$(mktemp --suffix .json)"
              trap 'rm -f "$FORWARDING_JSON"' EXIT

              nix run --no-warn-dirty --no-write-lock-file ${network-forwarding-model.outPath}#compile-and-build-forwarding-model -- "$INPUTS_NIX" > "$FORWARDING_JSON"

              if [ -n "$INVENTORY" ]; then
                nix run --no-warn-dirty --no-write-lock-file ${self.outPath}#debug -- "$FORWARDING_JSON" "$INVENTORY" "$OUTPUT"
              else
                nix run --no-warn-dirty --no-write-lock-file ${self.outPath}#debug -- "$FORWARDING_JSON" "" "$OUTPUT"
              fi
            '';
          };

          default = self.packages.${system}.debug;
        }
      );

      apps = forAll (system: {
        debug = {
          type = "app";
          program = "${self.packages.${system}.debug}/bin/network-control-plane-model-debug";
        };

        compile-and-build-control-plane-model = {
          type = "app";
          program = "${self.packages.${system}.compile-and-build-control-plane-model}/bin/compile-and-build-control-plane-model";
        };

        default = self.apps.${system}.debug;
      });
    };
}
