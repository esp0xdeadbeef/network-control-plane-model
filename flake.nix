# ./flake.nix
{
  description = "network-control-plane-model";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/0182a361324364ae3f436a63005877674cf45efb";
    network-solver.url = "github:esp0xdeadbeef/network-forwarding-model";

    network-solver.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, network-solver }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;
      controlPlaneModel = import ./src/main.nix;
    in
    {
      lib.controlPlaneModel = controlPlaneModel;

      formatter = forAllSystems (system:
        nixpkgs.legacyPackages.${system}.nixfmt-rfc-style
      );

      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          solverApp = network-solver.apps.${system}.compile-and-solve.program;
        in
        {
          control-plane-model = pkgs.writeShellApplication {
            name = "control-plane-model";

            runtimeInputs = [
              pkgs.jq
              pkgs.nix
            ];

            text = ''
              set -euo pipefail

              if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
                echo "Usage: $0 <input.nix> [output-control-plane-model.json]" >&2
                exit 1
              fi

              INPUT_NIX="$1"
              OUTPUT_JSON="''${2:-control-plane-model.json}"
              FORWARDING_JSON="$(mktemp)"
              trap 'rm -f "$FORWARDING_JSON"' EXIT

              echo "[*] Running solver..." >&2
              ${solverApp} "$INPUT_NIX" > "$FORWARDING_JSON"

              echo "[*] Validating solver JSON..." >&2
              jq empty "$FORWARDING_JSON"

              echo "[*] Evaluating control-plane model..." >&2
              nix eval \
                --impure \
                --json \
                --expr '
                  let
                    flake = builtins.getFlake (toString ./.);
                    forwardingModel = builtins.fromJSON (builtins.readFile (builtins.getEnv "FORWARDING_JSON"));
                  in
                    flake.lib.controlPlaneModel { input = forwardingModel; }
                ' > "$OUTPUT_JSON"

              echo "[*] Validating control-plane model JSON..." >&2
              jq empty "$OUTPUT_JSON"
            '';
          };

          default = self.packages.${system}.control-plane-model;
        }
      );

      apps = forAllSystems (system: {
        control-plane-model = {
          type = "app";
          program = "${self.packages.${system}.control-plane-model}/bin/control-plane-model";
        };

        default = self.apps.${system}.control-plane-model;
      });

      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          sampleInput = builtins.fromJSON (builtins.readFile ./output-solver-signed.json);
          evaluated = controlPlaneModel { input = sampleInput; };
        in
        {
          passthrough-eval = pkgs.runCommand "network-control-plane-model-passthrough-eval" { } ''
            cat > "$out" <<'EOF'
            ${builtins.toJSON evaluated}
            EOF
          '';

          cli-structure = pkgs.runCommand "network-control-plane-model-cli-structure" { } ''
            test -x ${self.packages.${system}.control-plane-model}/bin/control-plane-model
            touch "$out"
          '';
        });

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.nixfmt-rfc-style
              pkgs.jq
              pkgs.nix
            ];
          };
        });
    };
}
