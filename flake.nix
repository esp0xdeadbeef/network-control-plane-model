{
  description = "network-control-plane-model";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-network.url = "github:NixOS/nixpkgs/ac56c456ebe4901c561d3ebf1c98fbd970aea753";

    network-forwarding-model.url = "github:esp0xdeadbeef/network-forwarding-model/0ee8f2b4f84657232865ade4d1dc21d12a18a8de";
    network-forwarding-model.inputs.nixpkgs.follows = "nixpkgs";

    network-labs.url = "github:esp0xdeadbeef/network-labs/main";
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
            , secretPlatformSubstrate ? "nixos"
            ,
            }:
            let
              cpm =
                builtins.addErrorContext
                  "while building network-control-plane-model from forwarding-model input"
                  (
                    buildCPM {
                      forwardingModel = input;
                      inherit inventory validateForwardingModel validateRuntimeModel secretPlatformSubstrate;
                    }
                  );

              result = {
                control_plane_model = cpm;
                deploymentHosts = if inventory ? deployment && inventory.deployment ? hosts then inventory.deployment.hosts else { };
              };
            in
            builtins.seq cpm (exposeHostNetwork result);

          get_CPM =
            { input
            , inventory ? { }
            , validateForwardingModel ? true
            , validateRuntimeModel ? false
            , secretPlatformSubstrate ? "nixos"
            ,
            }:
            buildCPM {
                      forwardingModel = input;
              inherit inventory validateForwardingModel validateRuntimeModel secretPlatformSubstrate;
            };

          getCPM = get_CPM;

          readInput = readValue;

          compileAndBuild =
            { input
            , inventory ? { }
            , validateForwardingModel ? true
            , validateRuntimeModel ? false
            , secretPlatformSubstrate ? "nixos"
            ,
            }:
            build {
              input = forwardingLib.buildFromCompilerInputs { inherit input; };
              inherit inventory validateForwardingModel validateRuntimeModel secretPlatformSubstrate;
            };

          compileAndBuildFromPaths =
            { inputPath
            , inventoryPath ? null
            , validateForwardingModel ? true
            , validateRuntimeModel ? false
            , secretPlatformSubstrate ? "nixos"
            ,
            }:
            compileAndBuild {
              input = readValue inputPath;
              inventory =
                if inventoryPath == null then
                  { }
                else
                  readValue inventoryPath;
              inherit validateForwardingModel validateRuntimeModel secretPlatformSubstrate;
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
            , secretPlatformSubstrate ? "nixos"
            ,
            }:
            pkgs.writeText name (builtins.toJSON (build { inherit input inventory secretPlatformSubstrate; }));

          writeCompileAndBuildJSON =
            { inputPath
            , inventoryPath ? null
            , name ? "output-control-plane-model.json"
            , secretPlatformSubstrate ? "nixos"
            ,
            }:
            pkgs.writeText name (
              builtins.toJSON (
                compileAndBuildFromPaths {
                  inherit
                    inputPath
                    inventoryPath
                    secretPlatformSubstrate
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
          lib = self.libBySystem.${system};

          cpm_nixos_json = pkgs.writeText "cpm-nixos.json"
            (builtins.toJSON (lib.compileAndBuildFromPaths {
              inputPath = "${network-labs}/HAT/emulated-isp-residential-testnet/intent.nix";
              inventoryPath = "${network-labs}/HAT/emulated-isp-residential-testnet/inventory-nixos.nix";
            }));

          cpm_clab_json = pkgs.writeText "cpm-clab.json"
            (builtins.toJSON (lib.compileAndBuildFromPaths {
              inputPath = "${network-labs}/HAT/emulated-isp-residential-testnet/intent.nix";
              inventoryPath = "${network-labs}/HAT/emulated-isp-residential-testnet/inventory-clab.nix";
            }));
        in
        {
          "FS-800-HDS-010-SDS-013-SMS-020" =
            pkgs.runCommand "check-FS-800-HDS-010-SDS-013-SMS-020"
              {
                nativeBuildInputs = [ pkgs.bash pkgs.jq pkgs.nix ];
                CPM_NIXOS_JSON = cpm_nixos_json;
                CPM_CLAB_JSON = cpm_clab_json;
                NETWORK_REPO_DIRECT_TEST_OK = "1";
                NIX_CONFIG = "extra-experimental-features = nix-command flakes";
              }
              ''
                set -euo pipefail
                export HOME="$TMPDIR"
                echo "check: FS-800-HDS-010-SDS-013-SMS-020 construction test"
                test_script="${self}/tests/FS-800-HDS-010-SDS-013-SMS-020-cpm-provider-handoff-fabric-egress.sh"
                echo "  validating test script syntax..."
                bash -n "$test_script"
                echo "  test script: $(wc -l < "$test_script") lines"
                echo "  GAMP-ID header: $(head -3 "$test_script" | grep GAMP-ID || echo 'MISSING')"
                echo ""
                echo "  executing full construction test with pre-built CPM outputs..."
                cd "${self}"
                bash "$test_script"
                touch $out
              '';

          "FS-720-HDS-030-SDS-010-SMS-010-checker" =
            let
              # Pre-build checker results against hand-crafted test data
              helpers = import ./src/cpm/cpm-contract-support.nix { inherit lib; };
              ipam = import ./src/cpm/ipam.nix { inherit lib; };
              common = import ./src/cpm/Site/build-data/common.nix {
                inherit helpers ipam;
                enterpriseRoot = { };
              };
              checkerModule = import ./src/cpm/Site/check/endpoint-assignment-checker.nix {
                inherit helpers common;
              };

              # Test cases: name -> { endpointAssignment, expectedResult }
              happyAssignment = {
                "site-a-client01" = {
                  name = "client01"; tenant = "client"; enterprise = "esp";
                  site = "site-a"; mode = "static"; family = "dual";
                  bridge = "br-client"; owningSubstrate = "s-router-test-clients";
                  namespaceOwner = "site-a-access-client";
                  gampIds = [ "FS-720-HDS-010-SDS-025-SMS-010" "FS-983" ];
                  static = { address = "10.20.20.10"; prefixLength = 24; gateway4 = "10.20.20.1"; };
                };
                "site-a-guest01" = {
                  name = "guest01"; tenant = "guest"; enterprise = "esp";
                  site = "site-a"; mode = "dhcp"; family = "ipv4";
                  bridge = "br-guest"; owningSubstrate = "s-router-test-clients";
                  namespaceOwner = "site-a-access-guest";
                  gampIds = [ "FS-720-HDS-010-SDS-025-SMS-010" "FS-983" ];
                  dhcp = { servedPrefix4 = "10.20.30.1/24"; gw4 = "10.20.30.1"; conflict = "reject-overlap"; };
                };
              };
              happyResultRef = checkerModule { endpointAssignment = happyAssignment; };

              conflictAssignment = {
                "site-a-client01" = {
                  name = "client01"; tenant = "client"; enterprise = "esp";
                  site = "site-a"; mode = "static"; family = "ipv4";
                  bridge = "br-shared"; owningSubstrate = "s-router-test-clients";
                  namespaceOwner = "site-a-access-client";
                  gampIds = [ "FS-720-HDS-010-SDS-025-SMS-010" "FS-983" ];
                  static = { address = "10.20.20.10"; prefixLength = 24; gateway4 = "10.20.20.1"; };
                };
                "site-a-guest01" = {
                  name = "guest01"; tenant = "guest"; enterprise = "esp";
                  site = "site-a"; mode = "dhcp"; family = "ipv4";
                  bridge = "br-shared"; owningSubstrate = "s-router-test-clients";
                  namespaceOwner = "site-a-access-guest";
                  gampIds = [ "FS-720-HDS-010-SDS-025-SMS-010" "FS-983" ];
                  dhcp = { servedPrefix4 = "10.20.20.1/24"; gw4 = "10.20.20.1"; conflict = "reject-overlap"; };
                };
              };
              conflictResultRef = checkerModule { endpointAssignment = conflictAssignment; };

              nullBridgeAssignment = {
                "site-a-client01" = {
                  name = "client01"; tenant = "client"; enterprise = "esp";
                  site = "site-a"; mode = "static"; family = "dual";
                  owningSubstrate = "s-router-test-clients";
                  namespaceOwner = "site-a-access-client";
                  gampIds = [ "FS-720-HDS-010-SDS-025-SMS-010" "FS-983" ];
                  static = { address = "10.20.20.10"; prefixLength = 24; gateway4 = "10.20.20.1"; };
                };
              };
              nullBridgeResultRef = checkerModule { endpointAssignment = nullBridgeAssignment; };

              # Force all results (deepSeq to catch lazy evaluation issues)
              forced = builtins.deepSeq happyResultRef.diagnostics
                (builtins.deepSeq conflictResultRef.diagnostics
                  (builtins.deepSeq nullBridgeResultRef.diagnostics true));

              testData = pkgs.writeText "checker-test-data.json"
                (builtins.toJSON {
                  happy = {
                    result = happyResultRef.result;
                    diagnostics = happyResultRef.diagnostics;
                  };
                  conflict = {
                    result = conflictResultRef.result;
                    diagnostics = conflictResultRef.diagnostics;
                  };
                  nullBridge = {
                    result = nullBridgeResultRef.result;
                    diagnostics = nullBridgeResultRef.diagnostics;
                  };
                });
            in
            pkgs.runCommand "check-FS-720-HDS-030-SDS-010-SMS-010-checker"
              {
                nativeBuildInputs = [ pkgs.bash pkgs.jq ];
                TEST_DATA_JSON = testData;
              }
              ''
                set -euo pipefail
                echo "check: FS-720-HDS-030-SDS-010-SMS-010 Phase 3 checker contract test"
                PASS=0; FAIL=0
                pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
                fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

                echo ""
                echo "=== Test 1: Happy path — clean records ==="
                if [ "$(jq -r '.happy.result' "$TEST_DATA_JSON")" = "PASS" ]; then
                  pass "Happy path: result=PASS"
                else
                  fail "Happy path: result=PASS (got $(jq -r '.happy.result' "$TEST_DATA_JSON"))"
                fi
                diag_count=$(jq '.happy.diagnostics | length' "$TEST_DATA_JSON")
                if [ "$diag_count" -eq 0 ]; then
                  pass "Happy path: 0 diagnostics"
                else
                  fail "Happy path: 0 diagnostics (got $diag_count)"
                fi

                echo ""
                echo "=== Test 2: P6 — DHCP/static conflict on same bridge ==="
                if [ "$(jq -r '.conflict.result' "$TEST_DATA_JSON")" = "FAIL" ]; then
                  pass "P6: result=FAIL (conflict detected)"
                else
                  fail "P6: result=FAIL"
                fi
                if jq -e '.conflict.diagnostics[] | select(.code == "static-dhcp-conflict")' "$TEST_DATA_JSON" >/dev/null 2>&1; then
                  pass "P6: static-dhcp-conflict diagnostic emitted"
                else
                  fail "P6: static-dhcp-conflict diagnostic emitted"
                fi

                echo ""
                echo "=== Test 3: P8 — Null bridge diagnostic ==="
                if [ "$(jq -r '.nullBridge.result' "$TEST_DATA_JSON")" = "FAIL" ]; then
                  pass "P8: result=FAIL (bridge missing detected)"
                else
                  fail "P8: result=FAIL"
                fi
                if jq -e '.nullBridge.diagnostics[] | select(.code == "missing-bridge")' "$TEST_DATA_JSON" >/dev/null 2>&1; then
                  pass "P8: missing-bridge diagnostic emitted"
                else
                  fail "P8: missing-bridge diagnostic emitted"
                fi
                if jq -e '.nullBridge.diagnostics[] | select(.code == "incomplete-record")' "$TEST_DATA_JSON" >/dev/null 2>&1; then
                  pass "P8: incomplete-record diagnostic also emitted"
                else
                  fail "P8: incomplete-record diagnostic also emitted"
                fi

                echo ""
                echo "=== FS-720-HDS-030-SDS-010-SMS-010 CPM Phase 3 Checker (flake) Results ==="
                echo "PASS: $PASS  FAIL: $FAIL"
                if [ "$FAIL" -gt 0 ]; then
                  echo "Some tests FAILED."
                  exit 1
                fi
                echo "All tests PASSED."
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
