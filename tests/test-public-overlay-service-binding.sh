#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

# shellcheck disable=SC2016
expr='
let
  flake = builtins.getFlake ("path:" + toString ./.);
  system = builtins.currentSystem;
  labs = flake.inputs.network-labs.outPath;
  built = flake.lib.${system}.compileAndBuildFromPaths {
    inputPath = labs + "/examples/s-router-public-overlay-service/intent.nix";
    inventoryPath = labs + "/examples/s-router-public-overlay-service/inventory-nixos.nix";
  };
  site = built.control_plane_model.data.esp0xdeadbeef."site-c";
  relations = (site.communicationContract.relations or [ ]) ++ (site.communicationContract.allowedRelations or [ ]);
  publicServiceRelation =
    builtins.any
      (relation:
        (relation.id or null) == "allow-sitec-wan-to-dmz-nebula"
        && (relation.from.kind or null) == "external"
        && (relation.from.uplinks or [ ]) == [ "wan" ]
        && (relation.to.kind or null) == "service"
        && (relation.to.name or null) == "dmz-nebula"
        && (relation.trafficType or null) == "nebula")
      relations;
  serviceBinding = site.policy.endpointBindings.services."dmz-nebula" or null;
  resolvedService =
    builtins.head (builtins.filter (service: (service.name or null) == "dmz-nebula") site.services);
  upstreamSelector =
    site.runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector".effectiveRuntimeRealization.interfaces;
  policy =
    site.runtimeTargets."esp0xdeadbeef-site-c-c-router-policy".effectiveRuntimeRealization.interfaces;
  dmzWanRoutes =
    upstreamSelector."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-wan".routes.ipv4 or [ ];
  dmzEastWestRoutes =
    upstreamSelector."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-east-west".routes.ipv4 or [ ];
  policyDmzWanRoutes =
    policy."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-wan".routes.ipv4 or [ ];
  hasRoute = routes: destination: gateway:
    builtins.any
      (route: (route.dst or null) == destination && (route.via4 or null) == gateway)
      routes;
in
  publicServiceRelation
  && serviceBinding.providers == [ "c-router-lighthouse" ]
  && resolvedService.providerTenants == [ "dmz" ]
  && hasRoute dmzWanRoutes "10.90.10.100" "10.80.0.18"
  && hasRoute policyDmzWanRoutes "10.90.10.100" "10.80.0.8"
  && !(hasRoute policyDmzWanRoutes "10.90.10.100" "10.80.0.19")
  && !(hasRoute dmzEastWestRoutes "10.90.10.100" "10.80.0.16")
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$expr" | grep -qx true; then
  echo "PASS public-overlay-service-binding"
else
  echo "FAIL public-overlay-service-binding" >&2
  exit 1
fi
