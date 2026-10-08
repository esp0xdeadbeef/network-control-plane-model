#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${NETWORK_CONTROL_PLANE_MODEL_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

REPO_ROOT="${repo_root}" nix eval --impure --raw --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    flake = builtins.getFlake ("path:" + repoRoot);
    lib = flake.inputs.nixpkgs.lib;
    common = {
      laneAccess = iface: iface.laneAccess or null;
      attrsOrEmpty = value: if builtins.isAttrs value then value else { };
      listOrEmpty = value: if builtins.isList value then value else [ ];
    };
    endpointContext = {
      accessInterfaces = [
        { runtimeIfName = "down-vlan2"; laneAccess = "access-vlan2"; }
        { runtimeIfName = "down-vlan7"; laneAccess = "access-vlan7"; }
      ];
      uplinkInterfaces = [
        {
          runtimeIfName = "up-vlan2";
          laneAccess = "access-vlan2";
          laneUplink = "wan";
          routes = {
            ipv4 = [
              {
                dst = "10.1.1.9/32";
                via4 = "10.0.0.1";
                intent = { kind = "internal-reachability"; };
              }
            ];
          };
        }
        { runtimeIfName = "up-vlan3"; laneAccess = "access-vlan3"; laneUplink = "wan"; }
        { runtimeIfName = "up-vlan7"; laneAccess = "access-vlan7"; laneUplink = "wan"; }
      ];
      accessNodesForEndpoint = endpoint:
        if (endpoint.kind or null) == "service" && (endpoint.name or null) == "vlan2-dns" then
          [ "access-vlan2" ]
        else
          [ ];
      uplinksForEndpoint = endpoint:
        if (endpoint.kind or null) == "external" then [ "wan" ] else [ ];
      # FS-315: a core-hosted service reaches the fabric through the uplink
      # lane(s) derived from the external bindings that land on its provider
      # node. This synthetic context models a core-local DNS service (service
      # vlan2-dns has access nodes) so there is no provider-node uplink lane.
      uplinksForService = _endpoint: [ ];
      serviceKnown = endpoint: (endpoint.kind or null) == "service";
      attrsOrEmpty = value: if builtins.isAttrs value then value else { };
    };
    select = import (repoRoot + "/src/cpm/firewall-intent/rules/policy-endpoints.nix") {
      inherit common endpointContext;
    };
    serviceRoutes = import (repoRoot + "/src/cpm/ControlModule/runtime-targets/service-endpoint-routes.nix") {
      inherit lib common;
      ipam = { };
      hasP2PPrefixLength = _: false;
      routeIntent = route: if builtins.isAttrs (route.intent or null) then route.intent else { };
    };
    relation = {
      action = "allow";
      id = "modeled-dns-relation";
    };
    coreDns = {
      kind = "service";
      name = "core-dns";
      providerEndpoints = [ { ipv4 = [ "10.1.1.9" ]; } ];
    };
    accessDns = { kind = "service"; name = "vlan2-dns"; };
    wan = { kind = "external"; uplinks = [ "wan" ]; };
    names = interfaces: map (iface: iface.runtimeIfName) interfaces;
    # FS-540-HDS-010-SDS-010-SMS-040 / FS-315: the resolver route is keyed by the
    # requester relation and rides only that requester modeled lane. The
    # external return side must not produce a requester-lane route, and the
    # requester route must carry the relation id rather than fanning out over
    # sibling lanes.
    requesterRuleIds = map (rule: rule.relationId) (
      serviceRoutes.endpointRoutes 4 { action = "accept"; trafficType = "dns"; relationId = "requester-to-core"; } coreDns
        (builtins.head (select.endpointIfaces relation coreDns accessDns))
    );
    externalRouteCount = builtins.length (
      serviceRoutes.endpointRoutes 4 { action = "accept"; trafficType = "dns"; relationId = "core-return-from-wan"; } coreDns
        (builtins.head (select.endpointIfaces relation accessDns coreDns))
    );
    require = condition: message: if condition then true else throw message;
  in
    if
      require (select.endpointIfaces relation coreDns wan == [ ])
        "core-local DNS service acquired every policy uplink toward WAN"
      && require (names (select.endpointIfaces relation accessDns coreDns) == [ "down-vlan2" ])
        "access DNS service lost its explicit access-side policy interface"
      && require (names (select.endpointIfaces relation coreDns accessDns) == [ "up-vlan2" ])
        "core DNS endpoint was not scoped to the explicit requester peer lane"
      && require (requesterRuleIds == [ "requester-to-core" ])
        "DNS endpoint-route selection lost the requester relation"
      && require (externalRouteCount == 0)
        "DNS endpoint-route selection admitted external return fan-out"
    then "ok" else throw "unreachable"
' >/dev/null

echo "PASS FS-540 policy DNS endpoint lane ownership"
