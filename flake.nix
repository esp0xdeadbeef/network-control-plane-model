{
  description = "network-control-plane-model";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-network.url = "github:NixOS/nixpkgs/ac56c456ebe4901c561d3ebf1c98fbd970aea753";

    network-forwarding-model.url = "github:esp0xdeadbeef/network-forwarding-model";
    network-forwarding-model.inputs.nixpkgs.follows = "nixpkgs";

    network-labs.url = "github:esp0xdeadbeef/network-labs";
  };

  outputs =
    { self
    , nixpkgs
    , nixpkgs-network
    , network-forwarding-model
    , network-labs
    , ...
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

      mkClientFixtures = import ./lib/client-fixtures {
        lib = nixpkgs.lib;
      };

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
          localLib = import ./lib/utils.nix;
          effectiveLib = lib // localLib;

          buildCPM = import ./src/build-cpm.nix { lib = effectiveLib; };

          forwardingLib =
            if network-forwarding-model ? libBySystem then
              network-forwarding-model.libBySystem.${system}
            else
              throw "network-control-plane-model requires network-forwarding-model.libBySystem";

          resolveHostNetwork =
            result:
            let
              controlPlaneModel = result.control_plane_model or result;
            in
            if result ? renderedHostNetwork then
              result.renderedHostNetwork
            else if result ? hostNetwork then
              result.hostNetwork
            else if controlPlaneModel ? renderedHostNetwork then
              controlPlaneModel.renderedHostNetwork
            else
              { };

          exposeHostNetwork =
            result:
            let
              hostNetwork = resolveHostNetwork result;
            in
            result // {
              inherit hostNetwork;
              renderedHostNetwork = hostNetwork;
            };
        in
        rec {
          build =
            { input
            , inventory ? { }
            , validateForwardingModel ? true
            , validateRuntimeModel ? false
            ,
            }:
            let
              cpm =
                builtins.addErrorContext
                  "while building network-control-plane-model from forwarding-model input"
                  (
                    buildCPM {
                      forwardingModel = input;
                      inherit inventory validateForwardingModel validateRuntimeModel;
                    }
                  );

              result = {
                control_plane_model = cpm;
              };
            in
            builtins.seq cpm (exposeHostNetwork result);

          get_CPM =
            { input
            , inventory ? { }
            , validateForwardingModel ? true
            , validateRuntimeModel ? false
            ,
            }:
            buildCPM {
              forwardingModel = input;
              inherit inventory validateForwardingModel validateRuntimeModel;
            };

          getCPM = get_CPM;

          readInput = readValue;

          compileAndBuild =
            { input
            , inventory ? { }
            , validateForwardingModel ? true
            , validateRuntimeModel ? false
            ,
            }:
            build {
              input = forwardingLib.buildFromCompilerInputs { inherit input; };
              inherit inventory validateForwardingModel validateRuntimeModel;
            };

          compileAndBuildFromPaths =
            { inputPath
            , inventoryPath ? null
            , validateForwardingModel ? true
            , validateRuntimeModel ? false
            ,
            }:
            compileAndBuild {
              input = readValue inputPath;
              inventory =
                if inventoryPath == null then
                  { }
                else
                  readValue inventoryPath;
              inherit validateForwardingModel validateRuntimeModel;
            };

          clientFixtures = mkClientFixtures {
            buildFromPaths =
              { intentPath
              , inventoryPath ? null
              , ...
              }:
              compileAndBuildFromPaths {
                inputPath = intentPath;
                inherit inventoryPath;
              };
          };

          writeJSON =
            { input
            , inventory ? { }
            , name ? "output-control-plane-model.json"
            ,
            }:
            pkgs.writeText name (builtins.toJSON (build { inherit input inventory; }));

          writeCompileAndBuildJSON =
            { inputPath
            , inventoryPath ? null
            , name ? "output-control-plane-model.json"
            ,
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

      clientFixtures = mkClientFixtures {
        buildFromPaths =
          { intentPath
          , inventoryPath ? null
          , pkgs ? null
          , system ? if pkgs == null then builtins.currentSystem else pkgs.system
          , ...
          }:
          self.libBySystem.${system}.compileAndBuildFromPaths {
            inputPath = intentPath;
            inherit inventoryPath;
          };
      };

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
                flake = builtins.getFlake "path:${self.outPath}";
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

              gitRev="unknown"
              gitDirty=true
              repoRoot="$(${pkgs.git}/bin/git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
              repoRemote=""
              if [[ -n "$repoRoot" ]]; then
                repoRemote="$(${pkgs.git}/bin/git -C "$repoRoot" config --get remote.origin.url 2>/dev/null || true)"
              fi
              if [[ -n "$repoRoot" && ( "''${repoRoot##*/}" == "network-control-plane-model" || "$repoRemote" == *"network-control-plane-model"* ) ]]; then
                gitRev="$(${pkgs.git}/bin/git -C "$repoRoot" rev-parse HEAD 2>/dev/null || echo "unknown")"
                if ${pkgs.git}/bin/git -C "$repoRoot" diff --quiet >/dev/null 2>&1 && ${pkgs.git}/bin/git -C "$repoRoot" diff --cached --quiet >/dev/null 2>&1; then
                  gitDirty=false
                else
                  gitDirty=true
                fi
              fi
              sourceNarHash="${self.sourceInfo.narHash or ""}"
              sourceLastModified="${toString (self.sourceInfo.lastModified or self.lastModified or 0)}"

              echo "$json" | ${pkgs.jq}/bin/jq -S -c \
                --arg rev "$gitRev" \
                --argjson dirty "$gitDirty" \
                --arg sourceNarHash "$sourceNarHash" \
                --arg sourceLastModified "$sourceLastModified" \
                '.control_plane_model.meta = (.control_plane_model.meta // {})
                 | .control_plane_model.meta.networkControlPlaneModel =
                     ((.control_plane_model.meta.networkControlPlaneModel // {})
                      + {
                        name: "network-control-plane-model",
                        gitRev: $rev,
                        gitDirty: $dirty,
                        sourceNarHash: $sourceNarHash,
                        sourceLastModified: $sourceLastModified
                      })' \
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

              INPUTS_NIX="$(realpath "$INPUTS_NIX")"
              if [ -n "$INVENTORY" ]; then
                INVENTORY="$(realpath "$INVENTORY")"
              fi

              FORWARDING_JSON="$(mktemp --suffix .json)"
              trap 'rm -f "$FORWARDING_JSON"' EXIT

              nix run --no-warn-dirty --no-write-lock-file path:${network-forwarding-model.outPath}#compile-and-build-forwarding-model -- "$INPUTS_NIX" > "$FORWARDING_JSON"

              if [ -n "$INVENTORY" ]; then
                nix run --no-warn-dirty --no-write-lock-file path:${self.outPath}#debug -- "$FORWARDING_JSON" "$INVENTORY" "$OUTPUT"
              else
                nix run --no-warn-dirty --no-write-lock-file path:${self.outPath}#debug -- "$FORWARDING_JSON" "" "$OUTPUT"
              fi
            '';
          };

          default = self.packages.${system}.debug;
        }
      );

      checks = forAll (system:
        let
          pkgs = mkPkgs system;
        in
        {
          "FS-800-HDS-010-SDS-013-SMS-020" =
            let
              testScript = "${self}/tests/test-FS-800-HDS-010-SDS-013-SMS-020-cpm-provider-handoff-fabric-egress.sh";
            in
            pkgs.runCommand "check-FS-800-HDS-010-SDS-013-SMS-020"
              {
                nativeBuildInputs = [ pkgs.bash pkgs.jq ];
              }
              ''
                set -euo pipefail
                echo "check: FS-800-HDS-010-SDS-013-SMS-020 construction test"
                echo "  validating test script syntax..."
                bash -n ${testScript}
                echo "  test script: $(wc -l < ${testScript}) lines, $(wc -c < ${testScript}) bytes"
                echo "  GAMP-ID header: $(head -3 ${testScript} | grep GAMP-ID || echo 'MISSING')"
                echo ""
                echo "  NOTE: full test requires network-labs repo and nix run."
                echo "  Run manually: bash ${testScript}"
                echo ""
                touch $out
              '';
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
