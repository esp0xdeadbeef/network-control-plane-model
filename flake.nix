     1|{
     2|  description = "network-control-plane-model";
     3|
     4|  inputs = {
     5|    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
     6|    nixpkgs-network.url = "github:NixOS/nixpkgs/ac56c456ebe4901c561d3ebf1c98fbd970aea753";
     7|
     8|    network-forwarding-model.url = "github:esp0xdeadbeef/network-forwarding-model/9579ffc72731a2a8480eda94d4259ac371e3a273";
     9|    network-forwarding-model.inputs.nixpkgs.follows = "nixpkgs";
    10|
    11|    network-labs.url = "github:esp0xdeadbeef/network-labs/3d07f800ca847b8796c6c85ca7318fbd8f42647b";
    12|  };
    13|
    14|  outputs =
    15|    { self
    16|    , nixpkgs
    17|    , nixpkgs-network
    18|    , network-forwarding-model
    19|    , network-labs
    20|    , ...
    21|    }:
    22|    let
    23|      systems = [
    24|        "x86_64-linux"
    25|        "aarch64-linux"
    26|      ];
    27|
    28|      forAll = f: nixpkgs.lib.genAttrs systems f;
    29|
    30|      readValue =
    31|        valueOrPath:
    32|        if builtins.isPath valueOrPath then
    33|          readValue (builtins.toString valueOrPath)
    34|        else if builtins.isString valueOrPath then
    35|          if valueOrPath == "" then
    36|            { }
    37|          else if builtins.match ".*\\.json$" valueOrPath != null then
    38|            builtins.fromJSON (builtins.readFile valueOrPath)
    39|          else
    40|            let
    41|              value = import valueOrPath;
    42|            in
    43|            if builtins.isFunction value then value { } else value
    44|        else if builtins.isFunction valueOrPath then
    45|          valueOrPath { }
    46|        else
    47|          valueOrPath;
    48|
    49|      mkClientFixtures = import ./lib/client-fixtures {
    50|        lib = nixpkgs.lib;
    51|      };
    52|
    53|      mkPkgs =
    54|        system:
    55|        let
    56|          patchedPkgs = import nixpkgs-network { inherit system; };
    57|          patchedNetwork = patchedPkgs.lib.network;
    58|        in
    59|        import nixpkgs {
    60|          inherit system;
    61|          overlays = [
    62|            (final: prev: {
    63|              lib = prev.lib // {
    64|                network = patchedNetwork;
    65|              };
    66|            })
    67|          ];
    68|        };
    69|
    70|      mkSystemLib =
    71|        system:
    72|        let
    73|          pkgs = mkPkgs system;
    74|          lib = pkgs.lib;
    75|          localLib = import ./lib/utils.nix;
    76|          effectiveLib = lib // localLib;
    77|
    78|          buildCPM = import ./src/build-cpm.nix { lib = effectiveLib; };
    79|
    80|          forwardingLib =
    81|            if network-forwarding-model ? libBySystem then
    82|              network-forwarding-model.libBySystem.${system}
    83|            else
    84|              throw "network-control-plane-model requires network-forwarding-model.libBySystem";
    85|
    86|          resolveHostNetwork =
    87|            result:
    88|            let
    89|              controlPlaneModel = result.control_plane_model or result;
    90|            in
    91|            if result ? renderedHostNetwork then
    92|              result.renderedHostNetwork
    93|            else if result ? hostNetwork then
    94|              result.hostNetwork
    95|            else if controlPlaneModel ? renderedHostNetwork then
    96|              controlPlaneModel.renderedHostNetwork
    97|            else
    98|              { };
    99|
   100|          exposeHostNetwork =
   101|            result:
   102|            let
   103|              hostNetwork = resolveHostNetwork result;
   104|            in
   105|            result // {
   106|              inherit hostNetwork;
   107|              renderedHostNetwork = hostNetwork;
   108|            };
   109|        in
   110|        rec {
   111|          build =
   112|            { input
   113|            , inventory ? { }
   114|            , validateForwardingModel ? true
   115|            , validateRuntimeModel ? false
   116|    , emulationSubnets ? [ ]
   117|            , secretPlatformSubstrate ? "nixos"
   118|            ,
   119|            }:
   120|            let
   121|              cpm =
   122|                builtins.addErrorContext
   123|                  "while building network-control-plane-model from forwarding-model input"
   124|                  (
   125|                    buildCPM {
   126|                      forwardingModel = input;
   127|                      inherit inventory validateForwardingModel validateRuntimeModel emulationSubnets secretPlatformSubstrate;
   128|                    }
   129|                  );
   130|
   131|              result = {
   132|                control_plane_model = cpm;
   133|                deploymentHosts = if inventory ? deployment && inventory.deployment ? hosts then inventory.deployment.hosts else { };
   134|              };
   135|            in
   136|            builtins.seq cpm (exposeHostNetwork result);
   137|
   138|          get_CPM =
   139|            { input
   140|            , inventory ? { }
   141|            , validateForwardingModel ? true
   142|            , validateRuntimeModel ? false
   143|    , emulationSubnets ? [ ]
   144|            , secretPlatformSubstrate ? "nixos"
   145|            ,
   146|            }:
   147|            buildCPM {
   148|                      forwardingModel = input;
   149|              inherit inventory validateForwardingModel validateRuntimeModel emulationSubnets secretPlatformSubstrate;
   150|            };
   151|
   152|          getCPM = get_CPM;
   153|
   154|          readInput = readValue;
   155|
   156|          compileAndBuild =
   157|            { input
   158|            , inventory ? { }
   159|            , validateForwardingModel ? true
   160|            , validateRuntimeModel ? false
   161|    , emulationSubnets ? [ ]
   162|            , secretPlatformSubstrate ? "nixos"
   163|            ,
   164|            }:
   165|            build {
   166|              input = forwardingLib.buildFromCompilerInputs { inherit input; };
   167|              inherit inventory validateForwardingModel validateRuntimeModel emulationSubnets secretPlatformSubstrate;
   168|            };
   169|
   170|          compileAndBuildFromPaths =
   171|            { inputPath
   172|            , inventoryPath ? null
   173|            , validateForwardingModel ? true
   174|            , validateRuntimeModel ? false
   175|    , emulationSubnets ? [ ]
   176|            , secretPlatformSubstrate ? "nixos"
   177|            ,
   178|            }:
   179|            compileAndBuild {
   180|              input = readValue inputPath;
   181|              inventory =
   182|                if inventoryPath == null then
   183|                  { }
   184|                else
   185|                  readValue inventoryPath;
   186|              inherit validateForwardingModel validateRuntimeModel secretPlatformSubstrate;
   187|            };
   188|
   189|          clientFixtures = mkClientFixtures {
   190|            buildFromPaths =
   191|              { intentPath
   192|              , inventoryPath ? null
   193|              , ...
   194|              }:
   195|              compileAndBuildFromPaths {
   196|                inputPath = intentPath;
   197|                inherit inventoryPath;
   198|              };
   199|          };
   200|
   201|          writeJSON =
   202|            { input
   203|            , inventory ? { }
   204|            , name ? "output-control-plane-model.json"
   205|            , secretPlatformSubstrate ? "nixos"
   206|            ,
   207|            }:
   208|            pkgs.writeText name (builtins.toJSON (build { inherit input inventory secretPlatformSubstrate; }));
   209|
   210|          writeCompileAndBuildJSON =
   211|            { inputPath
   212|            , inventoryPath ? null
   213|            , name ? "output-control-plane-model.json"
   214|            , secretPlatformSubstrate ? "nixos"
   215|            ,
   216|            }:
   217|            pkgs.writeText name (
   218|              builtins.toJSON (
   219|                compileAndBuildFromPaths {
   220|                  inherit
   221|                    inputPath
   222|                    inventoryPath
   223|                    secretPlatformSubstrate
   224|                    ;
   225|                }
   226|              )
   227|            );
   228|        };
   229|    in
   230|    {
   231|      lib = forAll mkSystemLib;
   232|
   233|      libBySystem = forAll mkSystemLib;
   234|
   235|      clientFixtures = mkClientFixtures {
   236|        buildFromPaths =
   237|          { intentPath
   238|          , inventoryPath ? null
   239|          , pkgs ? null
   240|          , system ? if pkgs == null then builtins.currentSystem else pkgs.system
   241|          , ...
   242|          }:
   243|          self.libBySystem.${system}.compileAndBuildFromPaths {
   244|            inputPath = intentPath;
   245|            inherit inventoryPath;
   246|          };
   247|      };
   248|
   249|      packages = forAll (
   250|        system:
   251|        let
   252|          pkgs = mkPkgs system;
   253|        in
   254|        {
   255|          debug = pkgs.writeShellApplication {
   256|            name = "network-control-plane-model-debug";
   257|
   258|            runtimeInputs = [
   259|              pkgs.jq
   260|              pkgs.git
   261|              pkgs.nix
   262|              pkgs.coreutils
   263|            ];
   264|
   265|            text = ''
   266|              set -euo pipefail
   267|
   268|              case "$#" in
   269|                1)
   270|                  INPUT="$1"
   271|                  INVENTORY=""
   272|                  OUTPUT="./output-control-plane-model.json"
   273|                  ;;
   274|                2)
   275|                  INPUT="$1"
   276|                  INVENTORY="$2"
   277|                  OUTPUT="./output-control-plane-model.json"
   278|                  ;;
   279|                *)
   280|                  INPUT="$1"
   281|                  INVENTORY="$2"
   282|                  OUTPUT="$3"
   283|                  ;;
   284|              esac
   285|
   286|              expr="$(cat <<EOF
   287|              let
   288|                flake = builtins.getFlake "path:${self.outPath}";
   289|                builder = flake.lib.${system}.build;
   290|                readValue =
   291|                  path:
   292|                  if path == "" then
   293|                    {}
   294|                  else if builtins.match ".*\\.json$" path != null then
   295|                    builtins.fromJSON (builtins.readFile path)
   296|                  else
   297|                    import path;
   298|              in
   299|                builder {
   300|                  input = readValue (builtins.getEnv "INPUT");
   301|                  inventory = readValue (builtins.getEnv "INVENTORY");
   302|                }
   303|              EOF
   304|              )"
   305|
   306|              json="$(
   307|                INPUT="$INPUT" INVENTORY="$INVENTORY" nix eval --impure --no-write-lock-file --json --expr "$expr"
   308|              )"
   309|
   310|              gitRev="unknown"
   311|              gitDirty=true
   312|              repoRoot="$(${pkgs.git}/bin/git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
   313|              repoRemote=""
   314|              if [[ -n "$repoRoot" ]]; then
   315|                repoRemote="$(${pkgs.git}/bin/git -C "$repoRoot" config --get remote.origin.url 2>/dev/null || true)"
   316|              fi
   317|              if [[ -n "$repoRoot" && ( "''${repoRoot##*/}" == "network-control-plane-model" || "$repoRemote" == *"network-control-plane-model"* ) ]]; then
   318|                gitRev="$(${pkgs.git}/bin/git -C "$repoRoot" rev-parse HEAD 2>/dev/null || echo "unknown")"
   319|                if ${pkgs.git}/bin/git -C "$repoRoot" diff --quiet >/dev/null 2>&1 && ${pkgs.git}/bin/git -C "$repoRoot" diff --cached --quiet >/dev/null 2>&1; then
   320|                  gitDirty=false
   321|                else
   322|                  gitDirty=true
   323|                fi
   324|              fi
   325|              sourceNarHash="${self.sourceInfo.narHash or ""}"
   326|              sourceLastModified="${toString (self.sourceInfo.lastModified or self.lastModified or 0)}"
   327|
   328|              echo "$json" | ${pkgs.jq}/bin/jq -S -c \
   329|                --arg rev "$gitRev" \
   330|                --argjson dirty "$gitDirty" \
   331|                --arg sourceNarHash "$sourceNarHash" \
   332|                --arg sourceLastModified "$sourceLastModified" \
   333|                '.control_plane_model.meta = (.control_plane_model.meta // {})
   334|                 | .control_plane_model.meta.networkControlPlaneModel =
   335|                     ((.control_plane_model.meta.networkControlPlaneModel // {})
   336|                      + {
   337|                        name: "network-control-plane-model",
   338|                        gitRev: $rev,
   339|                        gitDirty: $dirty,
   340|                        sourceNarHash: $sourceNarHash,
   341|                        sourceLastModified: $sourceLastModified
   342|                      })' \
   343|                | tee "$OUTPUT" \
   344|                | ${pkgs.jq}/bin/jq -S
   345|            '';
   346|          };
   347|
   348|          compile-and-build-control-plane-model = pkgs.writeShellApplication {
   349|            name = "compile-and-build-control-plane-model";
   350|
   351|            runtimeInputs = [
   352|              pkgs.nix
   353|              pkgs.coreutils
   354|            ];
   355|
   356|            text = ''
   357|              set -euo pipefail
   358|
   359|              case "$#" in
   360|                1)
   361|                  INPUTS_NIX="$1"
   362|                  INVENTORY=""
   363|                  OUTPUT="./output-control-plane-model.json"
   364|                  ;;
   365|                2)
   366|                  INPUTS_NIX="$1"
   367|                  INVENTORY="$2"
   368|                  OUTPUT="./output-control-plane-model.json"
   369|                  ;;
   370|                *)
   371|                  INPUTS_NIX="$1"
   372|                  INVENTORY="$2"
   373|                  OUTPUT="$3"
   374|                  ;;
   375|              esac
   376|
   377|              INPUTS_NIX="$(realpath "$INPUTS_NIX")"
   378|              if [ -n "$INVENTORY" ]; then
   379|                INVENTORY="$(realpath "$INVENTORY")"
   380|              fi
   381|
   382|              FORWARDING_JSON="$(mktemp --suffix .json)"
   383|              trap 'rm -f "$FORWARDING_JSON"' EXIT
   384|
   385|              nix run --no-warn-dirty --no-write-lock-file path:${network-forwarding-model.outPath}#compile-and-build-forwarding-model -- "$INPUTS_NIX" > "$FORWARDING_JSON"
   386|
   387|              if [ -n "$INVENTORY" ]; then
   388|                nix run --no-warn-dirty --no-write-lock-file path:${self.outPath}#debug -- "$FORWARDING_JSON" "$INVENTORY" "$OUTPUT"
   389|              else
   390|                nix run --no-warn-dirty --no-write-lock-file path:${self.outPath}#debug -- "$FORWARDING_JSON" "" "$OUTPUT"
   391|              fi
   392|            '';
   393|          };
   394|
   395|          default = self.packages.${system}.debug;
   396|        }
   397|      );
   398|
   399|      checks = forAll (system:
   400|        let
   401|          pkgs = mkPkgs system;
   402|          lib = self.libBySystem.${system};
   403|
   404|          cpm_nixos_json = pkgs.writeText "cpm-nixos.json"
   405|            (builtins.toJSON (lib.compileAndBuildFromPaths {
   406|              inputPath = "${network-labs}/HAT/emulated-isp-residential-testnet/intent.nix";
   407|              inventoryPath = "${network-labs}/HAT/emulated-isp-residential-testnet/inventory-nixos.nix";
   408|            }));
   409|
   410|          cpm_clab_json = pkgs.writeText "cpm-clab.json"
   411|            (builtins.toJSON (lib.compileAndBuildFromPaths {
   412|              inputPath = "${network-labs}/HAT/emulated-isp-residential-testnet/intent.nix";
   413|              inventoryPath = "${network-labs}/HAT/emulated-isp-residential-testnet/inventory-clab.nix";
   414|            }));
   415|        in
   416|        {
   417|          "FS-800-HDS-010-SDS-020-SMS-040" =
   418|            pkgs.runCommand "check-FS-800-HDS-010-SDS-020-SMS-040"
   419|              {
   420|                nativeBuildInputs = [ pkgs.bash pkgs.jq pkgs.nix ];
   421|                CPM_NIXOS_JSON = cpm_nixos_json;
   422|                CPM_CLAB_JSON = cpm_clab_json;
   423|                NETWORK_REPO_DIRECT_TEST_OK = "1";
   424|                NIX_CONFIG = "extra-experimental-features = nix-command flakes";
   425|              }
   426|              ''
   427|                set -euo pipefail
   428|                export HOME="$TMPDIR"
   429|                echo "check: FS-800-HDS-010-SDS-020-SMS-040 construction test"
   430|                test_script="${self}/tests/test-FS-800-HDS-010-SDS-020-SMS-040-cpm-provider-handoff-fabric-egress.sh"
   431|                echo "  validating test script syntax..."
   432|                bash -n "$test_script"
   433|                echo "  test script: $(wc -l < "$test_script") lines"
   434|                echo "  GAMP-ID header: $(head -3 "$test_script" | grep GAMP-ID || echo 'MISSING')"
   435|                echo ""
   436|                echo "  executing full construction test with pre-built CPM outputs..."
   437|                cd "${self}"
   438|                bash "$test_script"
   439|                touch $out
   440|              '';
   441|
   442|          "FS-720-HDS-010-SDS-025-SMS-010-checker" =
   443|            let
   444|              # Pre-build checker results against hand-crafted test data
   445|              helpers = import ./src/cpm/cpm-contract-support.nix { inherit lib; };
   446|              ipam = import ./src/cpm/ipam.nix { inherit lib; };
   447|              common = import ./src/cpm/Site/build-data/common.nix {
   448|                inherit helpers ipam;
   449|                enterpriseRoot = { };
   450|              };
   451|              checkerModule = import ./src/cpm/Site/check/endpoint-assignment-checker.nix {
   452|                inherit helpers common;
   453|              };
   454|
   455|              # Test cases: name -> { endpointAssignment, expectedResult }
   456|              happyAssignment = {
   457|                "site-a-client01" = {
   458|                  name = "client01"; tenant = "client"; enterprise = "esp";
   459|                  site = "site-a"; mode = "static"; family = "dual";
   460|                  bridge = "br-client"; owningSubstrate = "s-router-test-clients";
   461|                  namespaceOwner = "site-a-access-client";
   462|                  gampIds = [ "FS-720-HDS-010-SDS-025-SMS-010" "FS-983" ];
   463|                  static = { address = "10.20.20.10"; prefixLength = 24; gateway4 = "10.20.20.1"; };
   464|                };
   465|                "site-a-guest01" = {
   466|                  name = "guest01"; tenant = "guest"; enterprise = "esp";
   467|                  site = "site-a"; mode = "dhcp"; family = "ipv4";
   468|                  bridge = "br-guest"; owningSubstrate = "s-router-test-clients";
   469|                  namespaceOwner = "site-a-access-guest";
   470|                  gampIds = [ "FS-720-HDS-010-SDS-025-SMS-010" "FS-983" ];
   471|                  dhcp = { servedPrefix4 = "10.20.30.1/24"; gw4 = "10.20.30.1"; conflict = "reject-overlap"; };
   472|                };
   473|              };
   474|              happyResultRef = checkerModule { endpointAssignment = happyAssignment; };
   475|
   476|              conflictAssignment = {
   477|                "site-a-client01" = {
   478|                  name = "client01"; tenant = "client"; enterprise = "esp";
   479|                  site = "site-a"; mode = "static"; family = "ipv4";
   480|                  bridge = "br-shared"; owningSubstrate = "s-router-test-clients";
   481|                  namespaceOwner = "site-a-access-client";
   482|                  gampIds = [ "FS-720-HDS-010-SDS-025-SMS-010" "FS-983" ];
   483|                  static = { address = "10.20.20.10"; prefixLength = 24; gateway4 = "10.20.20.1"; };
   484|                };
   485|                "site-a-guest01" = {
   486|                  name = "guest01"; tenant = "guest"; enterprise = "esp";
   487|                  site = "site-a"; mode = "dhcp"; family = "ipv4";
   488|                  bridge = "br-shared"; owningSubstrate = "s-router-test-clients";
   489|                  namespaceOwner = "site-a-access-guest";
   490|                  gampIds = [ "FS-720-HDS-010-SDS-025-SMS-010" "FS-983" ];
   491|                  dhcp = { servedPrefix4 = "10.20.20.1/24"; gw4 = "10.20.20.1"; conflict = "reject-overlap"; };
   492|                };
   493|              };
   494|              conflictResultRef = checkerModule { endpointAssignment = conflictAssignment; };
   495|
   496|              nullBridgeAssignment = {
   497|                "site-a-client01" = {
   498|                  name = "client01"; tenant = "client"; enterprise = "esp";
   499|                  site = "site-a"; mode = "static"; family = "dual";
   500|                  owningSubstrate = "s-router-test-clients";
   501|