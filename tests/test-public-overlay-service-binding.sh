#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-OVERLAY-SERVICE-BINDING-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
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
        # FS-322: the ingress source names the exit scope, not an uplink list.
        && (relation.from.scope or null) == "c-router-core"
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
  coreIngressRoutes4 =
    upstreamSelector."p2p-c-router-core-c-router-upstream-selector".routes.ipv4 or [ ];
  coreIngressRoutes6 =
    upstreamSelector."p2p-c-router-core-c-router-upstream-selector".routes.ipv6 or [ ];
  dmzWanRoutes =
    upstreamSelector."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-wan".routes.ipv4 or [ ];
  dmzWanRoutes6 =
    upstreamSelector."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-wan".routes.ipv6 or [ ];
  dmzEastWestRoutes =
    upstreamSelector."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-east-west".routes.ipv4 or [ ];
  policyDmzWanRoutes =
    policy."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-wan".routes.ipv4 or [ ];
  policyDmzWanRoutes6 =
    policy."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-wan".routes.ipv6 or [ ];
  policyDownstreamDmzRoutes =
    policy."p2p-c-router-downstream-selector-c-router-policy--access-c-router-access-dmz".routes.ipv4 or [ ];
  policyDownstreamDmzRoutes6 =
    policy."p2p-c-router-downstream-selector-c-router-policy--access-c-router-access-dmz".routes.ipv6 or [ ];
  hasRoute = routes: destination: gateway:
    builtins.any
      (route: (route.dst or null) == destination && (route.via4 or null) == gateway)
      routes;
  hasRoute6 = routes: destination: gateway:
    builtins.any
      (route: (route.dst or null) == destination && (route.via6 or null) == gateway)
      routes;
  hasEndpointRoute = routes: destination:
    builtins.any
      (route:
        (route.dst or null) == destination
        && (((route.intent or { }).kind or null) == "service-endpoint-reachability"))
      routes;
  # The provider endpoint is inside the modelled dmz tenant prefix
  # (10.90.10.0/24, fd42:dead:cafe:10::/64), so the lane reaches it by that
  # prefix route rather than by a synthesized host route. Both forms bind the
  # endpoint to the modelled lane next hop; which one the model emits is the
  # service-endpoint-routes decision (a host route is emitted there only when no
  # modelled prefix covers the address), not this case observation.
  #
  # IPv6 destinations are emitted zero-padded per hextet (fd42:dead:cafe:0010:
  # 0000:0000:0000:0000/64), so the shorthand spelling never matched an emitted
  # route.
  endpointCover4 = [ "10.90.10.100/32" "10.90.10.0/24" ];
  endpointCover6 = [
    "fd42:dead:cafe:0010:0000:0000:0000:0100/128"
    "fd42:dead:cafe:0010:0000:0000:0000:0100/64"
    "fd42:dead:cafe:0010:0000:0000:0000:0000/64"
  ];
  # The route that carries the endpoint is the policy-table complement of the
  # lane own reachability: policyOnly, tagged `policy-default-lane`. Requiring
  # that tag keeps the assertion exact -- a plain fabric route for the same
  # prefix, with no lane attribution, does not count.
  hasIngressServiceRoute = routes: destinations: gateway: access: uplink:
    builtins.any
      (route:
        builtins.elem (route.dst or null) destinations
        && (route.via4 or null) == gateway
        && (route.policyOnly or false) == true
        && (((route.intent or { }).source or null) == "policy-default-lane")
        && (((route.lane or { }).access or null) == access)
        && (((route.lane or { }).uplink or null) == uplink))
      routes;
  hasIngressServiceRoute6 = routes: destinations: gateway: access: uplink:
    builtins.any
      (route:
        builtins.elem (route.dst or null) destinations
        && (route.via6 or null) == gateway
        && (route.policyOnly or false) == true
        && (((route.intent or { }).source or null) == "policy-default-lane")
        && (((route.lane or { }).access or null) == access)
        && (((route.lane or { }).uplink or null) == uplink))
      routes;
in
  publicServiceRelation
  && serviceBinding.providers == [ "c-router-lighthouse" ]
  && resolvedService.providerTenants == [ "dmz" ]
  && !(hasEndpointRoute coreIngressRoutes4 "10.90.10.100")
  && !(hasEndpointRoute coreIngressRoutes6 "fd42:dead:cafe:10::100")
  && !(hasRoute coreIngressRoutes4 "10.90.10.100" "10.80.0.4")
  # On the upstream selector the lane is the egress binding point and still
  # names the access scope it carries, so the route is attributed to
  # `c-router-access-dmz` on the `wan` uplink. FS-370 SMS-050 allows an uplink
  # lane to have access null; this model populates it, and the assertion states
  # what is emitted rather than a permissive either-way match.
  && hasIngressServiceRoute dmzWanRoutes endpointCover4 "10.80.0.18" "c-router-access-dmz" "wan"
  && hasIngressServiceRoute6 dmzWanRoutes6 endpointCover6 "fd42:dead:cafe:1000:0:0:0:12" "c-router-access-dmz" "wan"
  # The policy node downstream-dmz lane is not an uplink lane: it carries the
  # access scope and an uplink of null, which FS-370 SMS-050 permits for a hop
  # before the egress binding point. The upstream selector bears the uplink.
  && hasIngressServiceRoute policyDownstreamDmzRoutes endpointCover4 "10.80.0.8" "c-router-access-dmz" null
  && hasIngressServiceRoute6 policyDownstreamDmzRoutes6 endpointCover6 "fd42:dead:cafe:1000:0:0:0:8" "c-router-access-dmz" null
  && !(hasRoute policyDmzWanRoutes "10.90.10.100" "10.80.0.19")
  && !(hasRoute dmzEastWestRoutes "10.90.10.100" "10.80.0.16")
'

if nix eval --no-write-lock-file --extra-experimental-features 'nix-command flakes' --impure --expr "$expr" | grep -qx true; then
  echo "PASS public-overlay-service-binding"
else
  echo "FAIL public-overlay-service-binding" >&2
  exit 1
fi
