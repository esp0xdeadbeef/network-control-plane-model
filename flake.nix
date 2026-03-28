{
  description = "network-control-plane-model";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-network.url = "github:NixOS/nixpkgs/ac56c456ebe4901c561d3ebf1c98fbd970aea753";

    network-forwarding-model.url = "github:esp0xdeadbeef/network-forwarding-model";
    network-forwarding-model.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-network,
      network-forwarding-model,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAll = f: nixpkgs.lib.genAttrs systems f;

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
    in
    {
      lib = forAll (
        system: {
          build = { input, inventory ? { } }:
            import ./src/main.nix {
              inherit input inventory;
              lib = (mkPkgs system).lib;
            };
        }
      );

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
                flake = builtins.getFlake (toString ${self});
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
                INPUT="$INPUT" INVENTORY="$INVENTORY" nix eval --impure --json --expr "$expr"
              )"

              gitRev="$(${pkgs.git}/bin/git rev-parse HEAD 2>/dev/null || echo "unknown")"

              if ${pkgs.git}/bin/git diff --quiet && ${pkgs.git}/bin/git diff --cached --quiet; then
                gitDirty=false
              else
                gitDirty=true
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

              FORWARDING_JSON="$(mktemp --suffix .json)"
              trap 'rm -f "$FORWARDING_JSON"' EXIT

              nix run --no-warn-dirty ${network-forwarding-model}#compile-and-build-forwarding-model -- "$INPUTS_NIX" > "$FORWARDING_JSON"

              if [ -n "$INVENTORY" ]; then
                nix run --no-warn-dirty ${self}#debug -- "$FORWARDING_JSON" "$INVENTORY" "$OUTPUT"
              else
                nix run --no-warn-dirty ${self}#debug -- "$FORWARDING_JSON" "" "$OUTPUT"
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
