#!/usr/bin/env bash
# GAMP-ID: FS-190-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-190-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-190-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
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
  ARCHIVE_JSON="$archive_json" nix eval --no-write-lock-file --impure --raw --expr '
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
    nix eval --no-write-lock-file \
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
          # FS-315/FS-270: the service endpoint route into the dmz access space is
          # carried on the access-facing lane of the downstream-selector, not on
          # the upstream selector dmz uplink.
          #
          # This asserted the POLICY node. That is the one node the model must not
          # put it on: 5857ec5 (FS-525) suppresses service-endpoint routes there
          # deliberately, because a /32 outranks the fabric /31 that names the
          # real next hop and reflects the query back the way it came -- measured
          # on the cobalt HAT before that change. The endpoint route is emitted
          # where the terminal attachment is, on the downstream-selector, and the
          # policy node reaches the endpoint by its covering /24 on the same lane.
          # The case was asserting the configuration the model was fixed away from.
          #
          # The endpoint is reached by the modelled tenant prefix, not necessarily
          # by a synthesized host route. The `dmz-nebula` provider address sits
          # inside the modelled `10.90.10.0/24`, so that prefix route on this
          # lane already names the modelled next hop and the host route added only
          # specificity (see service-endpoint-routes.nix). Assert the covering
          # route that carries the endpoint, and require its gateway to be the
          # lane modelled peer, so a route pointing anywhere else does not count.
          target = site.runtimeTargets."esp0xdeadbeef-site-c-c-router-downstream-selector" or { };
          realization = target.effectiveRuntimeRealization or { };
          interfaces = realization.interfaces or { };
          iface = interfaces."p2p-c-router-access-dmz-c-router-downstream-selector" or { };
          routes = (iface.routes or { }).ipv4 or [ ];
          serviceAddress = "10.90.10.100";
          # The route that carries the provider endpoint on this lane.
          #
          # the dmz-nebula address sits inside its own modelled tenant prefix
          # (10.90.10.0/24), so the model reaches it by that prefix route rather
          # than by a synthesized host route -- the host route would only add
          # specificity and would outrank the modelled next hop (see
          # service-endpoint-routes.nix). Both forms are therefore the endpoint
          # route, and which one is emitted is the model decision, not this case
          # observation.
          #
          # The route alone does not prove the endpoint exists: the covering
          # prefix stays on the lane whether or not any provider endpoint is
          # assigned, because it is fabric reachability. Callers that need that
          # distinction use `providerEndpoints`, which is emitted alongside.
          endpointDestinations = [
            "${serviceAddress}/32"
            "10.90.10.0/24"
          ];
          hasProviderEndpointRoute =
            builtins.any
              (route:
                (route.dst or null) != null
                && builtins.elem (route.dst or null) endpointDestinations
                && (route.via4 or null) != null)
              routes;
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
    nix eval --no-write-lock-file \
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
            runtimeTargets = { };
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
            providerEndpointForServiceProvider = serviceName: providerName: null;
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
    nix eval --no-write-lock-file \
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
              scope = "c-router-core";
            };
            id = "allow-public-dmz-nebula";
            # FS-210: public ingress is authorized by an explicit
            # publicIngressTupleAuthority, not inferred from the requester form.
            publicIngressTupleAuthority = {
              sourceScope = "internet";
              publicSurface = "wan";
              targetService = "dmz-nebula";
              targetEndpoint = "c-router-lighthouse";
              targetPort = 4242;
              returnBehavior = "stateful-return";
              sourcePreservation = "preserve-source";
              translationMode = "none";
              hairpin = "not-modeled";
              asymmetricRouting = "not-allowed";
              tuples = [
                {
                  protocol = "udp";
                  publicPort = 4242;
                }
              ];
            };
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
            runtimeTargets = { };
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
            providerEndpointForServiceProvider = serviceName: providerName: {
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
          routedPathIface = {
            routes.ipv4 = [
              {
                dst = "10.90.10.0/24";
                via4 = "10.10.44.1";
                intent.kind = "internal-reachability";
              }
            ];
          };
          routedPathRoutes = routeModule.endpointRoutes 4 firewallRule service routedPathIface;
          # Ask the module itself whether the modelled prefix covers the endpoint,
          # rather than re-deriving it here: the predicate that decides whether a
          # host route is emitted must be the same one the case asserts against.
          endpointCoveredByModelledPrefix =
            routeModule.coveredByModelledPrefix 4 routedPathIface "10.90.10.100";
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
            inherit endpointCoveredByModelledPrefix;
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
    and any(.service.exposure.records[]; .relationId == "allow-sitec-wan-to-dmz-nebula" and .exposureClass == "public-ingress" and .ownerScope == {"kind":"service","name":"dmz-nebula"} and .requesterScope.kind == "external" and .requesterScope.names == ["c-router-core"] and .requesterScope.selector == "scope" and .sourceKind == "external" and .sourceNames == ["c-router-core"])
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
    # Removing the endpoint must remove the endpoint-derived reachability. The
    # covering tenant prefix is fabric reachability and stays on the lane either
    # way, so the endpoint fact is `providerEndpoints`, not the prefix route.
    and .service.providerEndpoints == []
    and .hasProviderEndpointRoute == true
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
    nix eval --no-write-lock-file \
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
            runtimeTargets = { };
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
            providerEndpointForServiceProvider = serviceName: providerName: {
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
    # A modelled prefix on the lane that covers the endpoint IS the endpoint
    # route: the synthesized /32 would add only specificity and would outrank the
    # modelled next hop (service-endpoint-routes.nix). The fixture supplies
    # 10.90.10.0/24 as the lane route, and the dmz-nebula address 10.90.10.100 sits inside
    # it, so no host route is emitted for it.
    and (.emitted.routedPathServiceEndpointRoutes | length) == 0
    and (.emitted.endpointCoveredByModelledPrefix == true)
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
if ! grep -Fq "service exposure scope binding requires external requester scope to use exactly one of name, uplinks, or scope" "$ambiguous_scope_stderr"; then
  echo "FAIL service-exposure-classification: ambiguous requester scope diagnostic did not name scope binding failure" >&2
  cat "$ambiguous_scope_stderr" >&2
  exit 1
fi

# === SMS-020 N2: Host-placement scope inheritance rejection ===
host_placement_intent="$(mktemp)"
host_placement_json="$(mktemp)"
host_placement_stderr="$(mktemp)"
trap 'rm -f "$host_placement_intent" "$host_placement_json" "$host_placement_stderr"' EXIT

eval_host_placement_fixture() {
  local output_path="$1"
  local stderr_path="$2"

  REPO_ROOT="$repo_root" \
    nix eval --no-write-lock-file \
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
            runtimeTargets = { };
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
                  hostPlacementExposure = "core-boundary";  # seeded: scope inherited from host placement
                };
              };
              relations = [ {
                action = "allow";
                from = {
                  kind = "external";
                  uplinks = [ "wan" ];
                };
                id = "allow-sitec-wan-to-dmz-nebula";
                to = {
                  kind = "service";
                  name = "dmz-nebula";
                };
                trafficType = "nebula";
              } ];
            };
            providerEndpointForServiceProvider = serviceName: providerName: null;
            providerTenantsForServiceProvider = providerName: [ "dmz" ];
            preferredDnsUplinksForService = serviceName: [ ];
            preferredDnsUplinksByRelationForService = serviceName: { };
          };
          svc = builtins.head services;
        in
        svc
      ' > "$output_path" 2> "$stderr_path" || true
}

if eval_host_placement_fixture "$host_placement_json" "$host_placement_stderr"; then
  if jq -e '.hostPlacementExposure == "core-boundary"' "$host_placement_json" >/dev/null 2>&1; then
    echo "FAIL service-exposure-classification: host-placement scope inheritance was accepted but should have been rejected" >&2
    jq '.' "$host_placement_json" >&2
    exit 1
  fi
fi
if ! grep -Fq "exposure-scope-inherited-from-host" "$host_placement_stderr"; then
  echo "FAIL service-exposure-classification: host-placement scope inheritance diagnostic not emitted" >&2
  cat "$host_placement_stderr" >&2
  exit 1
fi

echo "PASS service-exposure-classification"
