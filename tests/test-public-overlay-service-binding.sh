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
    inputPath = labs + "/examples/s-router-test-three-site/intent.nix";
    inventoryPath = labs + "/examples/s-router-test-three-site/inventory-nixos.nix";
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
in
  publicServiceRelation
  && serviceBinding.providers == [ "c-router-lighthouse" ]
  && resolvedService.providerTenants == [ "dmz" ]
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$expr" | grep -qx true; then
  echo "PASS public-overlay-service-binding"
else
  echo "FAIL public-overlay-service-binding" >&2
  exit 1
fi
