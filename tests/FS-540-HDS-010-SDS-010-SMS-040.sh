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
        { runtimeIfName = "up-vlan2"; laneAccess = "access-vlan2"; laneUplink = "wan"; }
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
      routeIntent = _: { };
    };
    relation = {
      action = "allow";
      id = "modeled-dns-relation";
    };
    coreDns = { kind = "service"; name = "core-dns"; };
    accessDns = { kind = "service"; name = "vlan2-dns"; };
    wan = { kind = "external"; uplinks = [ "wan" ]; };
    names = interfaces: map (iface: iface.runtimeIfName) interfaces;
    requesterRuleIds = map (rule: rule.relationId) (serviceRoutes.requesterServiceRules [
      {
        action = "accept";
        trafficType = "dns";
        relationId = "requester-to-core";
        from = accessDns;
        to = coreDns;
      }
      {
        action = "accept";
        trafficType = "dns";
        relationId = "core-return-from-wan";
        from = wan;
        to = coreDns;
      }
    ]);
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
        "DNS endpoint-route selection admitted external return fan-out or lost the requester relation"
    then "ok" else throw "unreachable"
' >/dev/null

echo "PASS FS-540 policy DNS endpoint lane ownership"
