#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-540-HDS-010-SDS-010-SMS-040.md  (Requester-Lane Reachability)
# OWNER:  network-control-plane-model
#
# Predicates:
#   P1  Every admitted requester lane carries the resolver endpoint prefix in
#       both families, tagged with its relation identity and its own lane.
#   P2  The route rides the interface whose modeled peer is the next hop, so the
#       requester policy table selects the modeled upstream lane instead of
#       reflecting the query back out the ingress lane (D3/D4).
#   P3  An access lane the relation did not admit carries no route for it.
#   P4  An exit (uplink/access-uplink) lane carries no requester endpoint route
#       (FS-550 return-route leak prevention).
#
# This case used to assert that
# src/cpm/ControlModule/runtime-targets/requester-lane-recursive-reachability.nix
# was imported. That module was dead code written against an older producer
# shape (`intent.kind = "service-dns-reachability"`) and stripped routes from
# non-requester lanes, which regressed FS-470-SMS-090 when enabled. The producer
# that owns requester legs is
# src/cpm/ControlModule/runtime-targets/dns-service-routes.nix, so the case now
# asserts the emitted contract instead of a file being imported.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
require_cmd jq
require_cmd nix

fail() { echo "FAIL requester-lane-reachability: $*" >&2; exit 1; }

archive_json="$(mktemp)"
output_json="$(mktemp)"
trap 'rm -f "${archive_json}" "${output_json}"' EXIT

nix flake archive --json "path:${repo_root}" >"${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --no-write-lock-file --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
    in
      if labs == null then
        throw "tests: missing archived network-labs input path"
      else
        labs.path or (throw "tests: network-labs archive has no path")
  '
)"

REPO_ROOT="${repo_root}" \
INTENT_PATH="${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
INVENTORY_PATH="${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
  nix eval --no-write-lock-file --impure --json --expr '
    let
      flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
      out = flake.libBySystem.${builtins.currentSystem}.compileAndBuildFromPaths {
        inputPath = builtins.getEnv "INTENT_PATH";
        inventoryPath = builtins.getEnv "INVENTORY_PATH";
      };
      policy =
        out.control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets."esp0xdeadbeef-site-a-s-router-policy";
      interfaces = policy.effectiveRuntimeRealization.interfaces;
      names = builtins.attrNames interfaces;
      routesOf = name: interfaces.${name}.routes or { };
      laneOf = name: (interfaces.${name}.backingRef or { }).lane or { };
      allFor = name: (routesOf name).ipv4 or [ ] ++ (routesOf name).ipv6 or [ ];
      isEndpointRoute =
        route:
        builtins.isAttrs route
        && (route.intent.kind or null) == "service-endpoint-reachability";
      endpointsOn = name:
        builtins.filter isEndpointRoute (allFor name);
      mgmtLane = "p2p-s-router-downstream-selector-s-router-policy-only--access-s-router-access-mgmt";
    in {
      # P1/P2: the requester legs for both families live on the service-facing
      # lane, each carrying its own lane identity and relation identity.
      clientV4 =
        builtins.any
          (route:
            route.dst == "10.20.10.1/32"
            && (route.lane.access or null) == "s-router-access-client"
            && (route.relationId or null) == "allow-sitea-tenants-to-mgmt-dns"
            && (route.via4 or null) != null
            && (route.intent.policyTableComplement or false))
          ((routesOf mgmtLane).ipv4 or [ ]);
      clientV6 =
        builtins.any
          (route:
            route.dst == "fd42:dead:beef:10::1/128"
            && (route.lane.access or null) == "s-router-access-client"
            && (route.relationId or null) == "allow-sitea-tenants-to-mgmt-dns"
            && (route.via6 or null) != null
            && (route.intent.policyTableComplement or false))
          ((routesOf mgmtLane).ipv6 or [ ]);
      dmzV4 =
        builtins.any
          (route:
            route.dst == "10.20.10.1/32"
            && (route.lane.access or null) == "s-router-access-dmz"
            && (route.relationId or null) == "allow-sitea-tenants-to-mgmt-dns")
          ((routesOf mgmtLane).ipv4 or [ ]);
      # P3: the streaming lane is admitted only by its own relation, so it must
      # not carry the tenants relation leg.
      streamingHasTenantsLeg =
        builtins.any
          (route:
            (route.lane.access or null) == "s-router-access-streaming"
            && (route.relationId or null) == "allow-sitea-tenants-to-mgmt-dns")
          (endpointsOn mgmtLane);
      # P4: no exit lane may carry a requester endpoint route.
      exitLaneRoutes = builtins.filter
        (name:
          builtins.elem ((laneOf name).kind or null) [ "uplink" "access-uplink" ]
          && endpointsOn name != [ ])
        names;
      interfaceCount = builtins.length names;
    }
  ' >"${output_json}"

for predicate in clientV4 clientV6 dmzV4; do
  if [[ "$(jq -r ".${predicate}" "${output_json}")" != "true" ]]; then
    jq . "${output_json}" >&2 || true
    fail "P1/P2 ${predicate}: the requester leg is missing from the service-facing policy lane; the endpoint prefix must be emitted per requester lane with its relation, lane and next-hop provenance (FS-540-HDS-010-SDS-010-SMS-040 D3)"
  fi
done

if [[ "$(jq -r '.streamingHasTenantsLeg' "${output_json}")" != "false" ]]; then
  fail "P3 the unadmitted streaming lane carries the tenants DNS relation leg; reachability was copied to a requester without recursive authority"
fi

exit_lane_count="$(jq -r '.exitLaneRoutes | length' "${output_json}")"
if [[ "${exit_lane_count}" != "0" ]]; then
  jq '.exitLaneRoutes' "${output_json}" >&2
  fail "P4 ${exit_lane_count} exit lane(s) carry a requester endpoint route; an uplink lane must not carry internal resolver reachability (FS-550 return-route leak prevention)"
fi

echo "PASS requester-lane-reachability"
