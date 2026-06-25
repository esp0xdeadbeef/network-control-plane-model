#!/usr/bin/env bash
# GAMP-ID: FS-190-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-190-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-190-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

archive_json="$(mktemp)"
baseline_json="$(mktemp)"
missing_endpoint_inventory="$(mktemp)"
missing_endpoint_json="$(mktemp)"
no_exposure_intent="$(mktemp)"
no_exposure_json="$(mktemp)"
missing_scope_intent="$(mktemp)"
missing_scope_json="$(mktemp)"
missing_scope_stderr="$(mktemp)"
ambiguous_scope_intent="$(mktemp)"
ambiguous_scope_json="$(mktemp)"
ambiguous_scope_stderr="$(mktemp)"
reachability_separation_json="$(mktemp)"
trap 'rm -f "$archive_json" "$baseline_json" "$missing_endpoint_inventory" "$missing_endpoint_json" "$no_exposure_intent" "$no_exposure_json" "$missing_scope_intent" "$missing_scope_json" "$missing_scope_stderr" "$ambiguous_scope_intent" "$ambiguous_scope_json" "$ambiguous_scope_stderr" "$reachability_separation_json"' EXIT

nix flake archive --json "path:${repo_root}" > "$archive_json"

labs_path="$(
  ARCHIVE_JSON="$archive_json" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
      labsPath = if labs == null then null else labs.path or null;
    in
      if labsPath == null then
        throw "tests: missing archived network-labs input path"
      else
        labsPath
  '
)"

eval_service() {
  local intent_path="$1"
  local inventory_path="$2"
  local output_path="$3"

  REPO_ROOT="$repo_root" \
  INTENT_PATH="$intent_path" \
  INVENTORY_PATH="$inventory_path" \
    nix eval \
      --extra-experimental-features 'nix-command flakes' \
      --impure --json --expr '
        let
          flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
          out = flake.lib.x86_64-linux.compileAndBuildFromPaths {
            inputPath = builtins.getEnv "INTENT_PATH";
            inventoryPath = builtins.getEnv "INVENTORY_PATH";
            validateForwardingModel = false;
          };
          site = out.control_plane_model.data.esp0xdeadbeef."site-c";
          service =
            builtins.head (builtins.filter (item: (item.name or null) == "dmz-nebula") site.services);
          target = site.runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector" or { };
          realization = target.effectiveRuntimeRealization or { };
          interfaces = realization.interfaces or { };
          iface = interfaces."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-wan" or { };
          routes = (iface.routes or { }).ipv4 or [ ];
          hasProviderEndpointRoute =
            builtins.any (route: (route.dst or null) == "10.90.10.100") routes;
        in
        {
          inherit service hasProviderEndpointRoute;
        }
      ' > "$output_path"
}

eval_service_scope_binding_fixture() {
  local relation_path="$1"
  local output_path="$2"

  REPO_ROOT="$repo_root" \
  RELATION_PATH="$relation_path" \
    nix eval \
      --extra-experimental-features 'nix-command flakes' \
      --impure --json --expr '
        let
          repoRoot = builtins.getEnv "REPO_ROOT";
          localLib = import (repoRoot + "/lib/utils.nix");
          helpers = import (repoRoot + "/lib/contract.nix") { lib = localLib; };
          relation = import (builtins.getEnv "RELATION_PATH");
          lib = {
            concatMap = f: list: builtins.concatLists (map f list);
          };
          common = {
            failForwarding = path: message:
              throw "forwarding-model update required: ${path}: ${message}";
          };
          uniqueStrings = values:
            helpers.sortedNames (
              builtins.listToAttrs (
                map
                  (value: { name = value; value = true; })
                  (builtins.filter helpers.isNonEmptyString values)
              )
            );
          services = import (repoRoot + "/src/cpm/Site/build-data/services.nix") {
            inherit lib helpers common uniqueStrings;
            sitePath = "forwardingModel.enterprise.esp0xdeadbeef.site.site-c";
            policyEndpointBindings = {
              externals = {
                wan = {
                  uplinks = [ "wan" ];
                  runtimeBindings = [ ];
                };
              };
              services = {
                dmz-nebula = {
                  providers = [ "c-router-lighthouse" ];
                  trafficType = "nebula";
                };
              };
              relations = [ relation ];
            };
            providerEndpointForServiceProvider = providerName: null;
            providerTenantsForServiceProvider = providerName: [ "dmz" ];
            preferredDnsUplinksForService = serviceName: [ ];
            preferredDnsUplinksByRelationForService = serviceName: { };
          };
        in
          builtins.head services
      ' > "$output_path"
}

eval_reachability_separation_fixture() {
  local output_path="$1"

  REPO_ROOT="$repo_root" \
    nix eval \
      --extra-experimental-features 'nix-command flakes' \
      --impure --json --expr '
        let
          repoRoot = builtins.getEnv "REPO_ROOT";
          localLib = import (repoRoot + "/lib/utils.nix");
          helpers = import (repoRoot + "/lib/contract.nix") { lib = localLib; };
          lib = import <nixpkgs/lib>;
          common = import (repoRoot + "/src/cpm/ControlModule/lib/common.nix") { inherit helpers; };
          ipam = import (repoRoot + "/src/cpm/ipam.nix") { inherit lib; };
          uniqueStrings = values:
            helpers.sortedNames (
              builtins.listToAttrs (
                map
                  (value: { name = value; value = true; })
                  (builtins.filter helpers.isNonEmptyString values)
              )
            );
          relation = {
            action = "allow";
            from = {
              kind = "external";
              uplinks = [ "wan" ];
            };
            id = "allow-public-dmz-nebula";
            to = {
              kind = "service";
              name = "dmz-nebula";
            };
            trafficType = "nebula";
          };
          firewallRule = {
            action = "accept";
            relationId = "allow-public-dmz-nebula";
            from = relation.from;
            to = relation.to;
            trafficType = relation.trafficType;
          };
          services = import (repoRoot + "/src/cpm/Site/build-data/services.nix") {
            inherit lib helpers common uniqueStrings;
            sitePath = "forwardingModel.enterprise.esp0xdeadbeef.site.site-c";
            policyEndpointBindings = {
              externals.wan = {
                uplinks = [ "wan" ];
                runtimeBindings = [ ];
              };
              services.dmz-nebula = {
                providers = [ "c-router-lighthouse" ];
                trafficType = "nebula";
              };
              relations = [ relation ];
            };
            providerEndpointForServiceProvider = providerName: {
              name = providerName;
              node = "c-router-lighthouse";
              ipv4 = [ "10.90.10.100" ];
              runtimeTarget = "esp0xdeadbeef-site-c-c-router-access-dmz";
            };
            providerTenantsForServiceProvider = providerName: [ "dmz" ];
            preferredDnsUplinksForService = serviceName: [ ];
            preferredDnsUplinksByRelationForService = serviceName: { };
          };
          routeModule = import (repoRoot + "/src/cpm/ControlModule/runtime-targets/service-endpoint-routes.nix") {
            inherit lib common ipam;
            hasP2PPrefixLength = dst:
              builtins.isString dst
              && (builtins.match ".*/3[12]" dst != null || builtins.match ".*/12[78]" dst != null);
            routeIntent = route: common.attrsOrEmpty (route.intent or null);
          };
          service = builtins.head services;
          noPathRoutes = routeModule.endpointRoutes 4 firewallRule service {
            routes.ipv4 = [ ];
          };
          routedPathRoutes = routeModule.endpointRoutes 4 firewallRule service {
            routes.ipv4 = [
              {
                dst = "10.90.10.0/24";
                via4 = "10.10.44.1";
                intent.kind = "internal-reachability";
              }
            ];
          };
        in
        {
          exposure = service.exposure;
          exposureClass = service.exposureClass;
          providerEndpoints = service.providerEndpoints;
          consumed = {
            exposureRecords = builtins.length (service.exposure.records or [ ]);
            externalServiceRules = routeModule.externalServiceRules [ firewallRule ];
            serviceRecordNames = builtins.attrNames (routeModule.serviceRecords services);
          };
          emitted = {
            exposureOnlyMetadata = service.exposure.notInferredFrom;
            noPathServiceEndpointRoutes = noPathRoutes;
            routedPathServiceEndpointRoutes = routedPathRoutes;
          };
        }
      ' > "$output_path"
}

base_intent="${labs_path}/examples/s-router-public-overlay-service/intent.nix"
base_inventory="${labs_path}/examples/s-router-public-overlay-service/inventory-nixos.nix"

eval_service "$base_intent" "$base_inventory" "$baseline_json"

baseline_ok="$(
  jq -r '
    .service.exposureClass == "public-ingress"
    and .service.exposure.class == "public-ingress"
    and .service.exposure.owningScope == {"kind":"service","name":"dmz-nebula"}
    and .service.exposure.classificationSource == "communicationContract.relations"
    and (.service.exposure.notInferredFrom | index("address-ownership") != null)
    and (.service.exposure.notInferredFrom | index("service-existence") != null)
    and (.service.exposure.notInferredFrom | index("route-availability") != null)
    and (.service.exposure.notInferredFrom | index("host-placement") != null)
    and any(.service.exposure.records[]; .relationId == "allow-sitec-wan-to-dmz-nebula" and .exposureClass == "public-ingress" and .ownerScope == {"kind":"service","name":"dmz-nebula"} and .requesterScope.kind == "external" and .requesterScope.names == ["wan"] and .requesterScope.selector == "uplinks" and .requesterScope.public == true and .sourceKind == "external" and .sourceNames == ["wan"])
    and .hasProviderEndpointRoute == true
  ' "$baseline_json"
)"
if [[ "$baseline_ok" != "true" ]]; then
  echo "FAIL service-exposure-classification: baseline service lacks explicit public-ingress classification" >&2
  jq '.' "$baseline_json" >&2
  exit 1
fi

cat > "$missing_endpoint_inventory" <<EOF
let
  base = import ${base_inventory};
in
base // {
  endpoints = builtins.removeAttrs (base.endpoints or { }) [ "c-router-lighthouse" ];
}
EOF

eval_service "$base_intent" "$missing_endpoint_inventory" "$missing_endpoint_json"

missing_endpoint_ok="$(
  jq -r '
    .service.exposureClass == "public-ingress"
    and .service.exposure.class == "public-ingress"
    and .service.providerEndpoints == []
    and .hasProviderEndpointRoute == false
  ' "$missing_endpoint_json"
)"
if [[ "$missing_endpoint_ok" != "true" ]]; then
  echo "FAIL service-exposure-classification: endpoint addresses or route availability changed exposure classification" >&2
  jq '.' "$missing_endpoint_json" >&2
  exit 1
fi

# === No exposure: remove the relation, verify via services.nix directly ===
# (Uses services.nix directly to bypass CPM build pipeline guard;
#  no-op failForwarding to allow testing the unexposed classification)
eval_no_exposure_fixture() {
  local output_path="$1"

  REPO_ROOT="$repo_root" \
    nix eval \
      --extra-experimental-features 'nix-command flakes' \
      --impure --json --expr '
        let
          repoRoot = builtins.getEnv "REPO_ROOT";
          localLib = import (repoRoot + "/lib/utils.nix");
          helpers = import (repoRoot + "/lib/contract.nix") { lib = localLib; };
          lib = {
            concatMap = f: list: builtins.concatLists (map f list);
          };
          common = {
            failForwarding = path: message: true;
          };
          uniqueStrings = values:
            helpers.sortedNames (
              builtins.listToAttrs (
                map
                  (value: { name = value; value = true; })
                  (builtins.filter helpers.isNonEmptyString values)
              )
            );
          services = import (repoRoot + "/src/cpm/Site/build-data/services.nix") {
            inherit lib helpers common uniqueStrings;
            sitePath = "forwardingModel.enterprise.esp0xdeadbeef.site.site-c";
            policyEndpointBindings = {
              externals = {
                wan = {
                  uplinks = [ "wan" ];
                  runtimeBindings = [ ];
                };
              };
              services = {
                dmz-nebula = {
                  providers = [ "c-router-lighthouse" ];
                  trafficType = "nebula";
                };
              };
              relations = [ ];
            };
            providerEndpointForServiceProvider = providerName: {
              name = providerName;
              node = "c-router-lighthouse";
              ipv4 = [ "10.90.10.100" ];
              runtimeTarget = "esp0xdeadbeef-site-c-c-router-access-dmz";
            };
            providerTenantsForServiceProvider = providerName: [ "dmz" ];
            preferredDnsUplinksForService = serviceName: [ ];
            preferredDnsUplinksByRelationForService = serviceName: { };
          };
          service = builtins.head services;
        in
        {
          providers = service.providers;
          providerEndpoints = service.providerEndpoints;
          exposureClass = service.exposureClass;
          exposure = service.exposure;
        }
      ' > "$output_path"
}

eval_no_exposure_fixture "$no_exposure_json"

no_exposure_ok="$(
  jq -r '
    .providers == ["c-router-lighthouse"]
    and (.providerEndpoints | length) == 1
    and .exposureClass == "unexposed"
    and .exposure.class == "unexposed"
    and (.exposure.records | length) == 0
  ' "$no_exposure_json"
)"
if [[ "$no_exposure_ok" != "true" ]]; then
  echo "FAIL service-exposure-classification: service existence, provider profile, address ownership, or host placement created exposure without an exposure relation" >&2
  jq '.' "$no_exposure_json" >&2
  exit 1
fi

eval_reachability_separation_fixture "$reachability_separation_json"

reachability_separation_ok="$(
  jq -r '
    .exposureClass == "public-ingress"
    and .exposure.classificationSource == "communicationContract.relations"
    and (.providerEndpoints | length) == 1
    and .providerEndpoints[0].ipv4 == ["10.90.10.100"]
    and .providerEndpoints[0].runtimeTarget == "esp0xdeadbeef-site-c-c-router-access-dmz"
    and .consumed.exposureRecords == 1
    and (.consumed.externalServiceRules | length) == 1
    and .consumed.externalServiceRules[0].relationId == "allow-public-dmz-nebula"
    and .consumed.serviceRecordNames == ["dmz-nebula"]
    and (.emitted.exposureOnlyMetadata | index("route-availability") != null)
    and (.emitted.exposureOnlyMetadata | index("host-placement") != null)
    and .emitted.noPathServiceEndpointRoutes == []
    and (.emitted.routedPathServiceEndpointRoutes | length) == 1
    and .emitted.routedPathServiceEndpointRoutes[0].dst == "10.90.10.100"
    and .emitted.routedPathServiceEndpointRoutes[0].intent == {"kind":"service-endpoint-reachability","service":"dmz-nebula"}
    and .emitted.routedPathServiceEndpointRoutes[0].relationId == "allow-public-dmz-nebula"
    and .emitted.routedPathServiceEndpointRoutes[0].trafficType == "nebula"
  ' "$reachability_separation_json"
)"
if [[ "$reachability_separation_ok" != "true" ]]; then
  echo "FAIL service-exposure-classification: exposure classification, provider endpoints, and host placement must not imply service endpoint reachability without route evidence" >&2
  jq '.' "$reachability_separation_json" >&2
  exit 1
fi

cat > "$missing_scope_intent" <<EOF
{
  action = "allow";
  from = { kind = "external"; };
  id = "allow-sitec-wan-to-dmz-nebula";
  to = {
    kind = "service";
    name = "dmz-nebula";
  };
  trafficType = "nebula";
}
EOF

if eval_service_scope_binding_fixture "$missing_scope_intent" "$missing_scope_json" 2> "$missing_scope_stderr"; then
  echo "FAIL service-exposure-classification: missing exposure requester scope unexpectedly evaluated" >&2
  jq '.' "$missing_scope_json" >&2
  exit 1
fi
if ! grep -Fq "service exposure scope binding requires requester scope to name an external or uplink" "$missing_scope_stderr"; then
  echo "FAIL service-exposure-classification: missing requester scope diagnostic did not name scope binding failure" >&2
  cat "$missing_scope_stderr" >&2
  exit 1
fi

cat > "$ambiguous_scope_intent" <<EOF
{
  action = "allow";
  from = {
    kind = "external";
    name = "wan";
    uplinks = [ "wan" ];
  };
  id = "allow-sitec-wan-to-dmz-nebula";
  to = {
    kind = "service";
    name = "dmz-nebula";
  };
  trafficType = "nebula";
}
EOF

if eval_service_scope_binding_fixture "$ambiguous_scope_intent" "$ambiguous_scope_json" 2> "$ambiguous_scope_stderr"; then
  echo "FAIL service-exposure-classification: ambiguous exposure requester scope unexpectedly evaluated" >&2
  jq '.' "$ambiguous_scope_json" >&2
  exit 1
fi
if ! grep -Fq "service exposure scope binding requires external requester scope to use exactly one of name or uplinks" "$ambiguous_scope_stderr"; then
  echo "FAIL service-exposure-classification: ambiguous requester scope diagnostic did not name scope binding failure" >&2
  cat "$ambiguous_scope_stderr" >&2
  exit 1
fi

echo "PASS service-exposure-classification"
