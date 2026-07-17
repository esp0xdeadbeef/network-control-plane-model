#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

result="$({
  REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
    let
      repoRoot = builtins.toPath (builtins.getEnv "REPO_ROOT");
      common = import (repoRoot + "/src/cpm/firewall-intent/rules/common.nix") { };
      build = import (repoRoot + "/src/cpm/firewall-intent/rules/downstream-selector.nix") { inherit common; };

      mkIface = runtimeIfName: kind: access: {
        inherit runtimeIfName;
        sourceInterface = runtimeIfName;
        sourceKind = "p2p";
        adapterClass = "p2p-realization";
        virtualAdapter = false;
        hostFacing = false;
        backingRef = {
          kind = "link";
          id = "link::test::${runtimeIfName}";
          name = "p2p-${runtimeIfName}";
          lane = {
            inherit kind access;
            uplink = null;
            uplinks = [ ];
          };
        };
        routes = {
          ipv4 = [ ];
          ipv6 = [ ];
        };
      };

      interfaces = [
        (mkIface "edge-a" "access-edge" "access-a")
        (mkIface "edge-b" "access-edge" "access-b")
        (mkIface "policy-a" "access" "access-a")
        (mkIface "policy-b" "access" "access-b")
      ];

      endpointBindings.tenants = {
        tenant-a.runtimeBindings = [ { logicalNode = "access-a"; } ];
        tenant-b.runtimeBindings = [ { logicalNode = "access-b"; } ];
      };

      allowRelation = {
        id = "allow-a-to-b";
        action = "allow";
        from = { kind = "tenant"; name = "tenant-a"; };
        to = { kind = "tenant"; name = "tenant-b"; };
        trafficType = "any";
        returnBehavior = "symmetric";
      };

      denyRelation = allowRelation // {
        id = "deny-a-to-b";
        action = "deny";
      };

      rulesFor = relation: requiresPolicy:
        build {
          inherit endpointBindings;
          transitInterfaces = interfaces;
          relations = [ relation ];
          trafficPaths = [
            {
              relationId = relation.id;
              inherit requiresPolicy;
              nodePath =
                if requiresPolicy then
                  [ "access-a" "downstream-selector" "policy" "downstream-selector" "access-b" ]
                else
                  [ "access-a" "downstream-selector" "access-b" ];
              stagePath =
                if requiresPolicy then
                  [ "access" "downstream-selector" "policy" "downstream-selector" "access" ]
                else
                  [ "access" "downstream-selector" "access" ];
            }
          ];
        };

      requiredRules = rulesFor allowRelation true;
      optionalRules = rulesFor allowRelation false;
      denyRules = rulesFor denyRelation true;
      wrongPathRules = build {
        inherit endpointBindings;
        transitInterfaces = interfaces;
        relations = [ allowRelation ];
        trafficPaths = [
          {
            relationId = allowRelation.id;
            requiresPolicy = true;
            nodePath = [ "access-a" "downstream-selector" "policy" "upstream-selector" "core" ];
            stagePath = [ "access" "downstream-selector" "policy" "upstream-selector" "core" ];
          }
        ];
      };

      matching = relationId: from: to: rules:
        builtins.filter
          (rule:
            (rule.relationId or null) == relationId
            && (rule.fromInterface or null) == from
            && (rule.toInterface or null) == to)
          rules;
    in
    {
      requiredDirect = builtins.length (matching "allow-a-to-b" "edge-a" "edge-b" requiredRules);
      requiredIngressHandoff = builtins.length (matching
        "selector-handoff-forward--access-a--access-to-selector-to-selector-to-policy--fabric"
        "edge-a"
        "policy-a"
        requiredRules);
      requiredEgressReturn = builtins.length (builtins.filter
        (rule:
          (rule.fromInterface or null) == "policy-b"
          && (rule.toInterface or null) == "edge-b"
          && (rule.connectionState or null) == "established,related"
          && (rule.returnRule or false))
        requiredRules);
      requiredPolicyEgressForward = builtins.length (builtins.filter
        (rule:
          (rule.relationId or null) == "allow-a-to-b"
          && (rule.direction or null) == "relation-forward-policy-egress"
          && (rule.fromInterface or null) == "policy-b"
          && (rule.toInterface or null) == "edge-b"
          && !(rule ? connectionState)
          && !(rule.returnRule or false)
          && (rule.transportAuthority.basis or null) == "modeled-relation")
        requiredRules);
      optionalDirect = builtins.length (matching "allow-a-to-b" "edge-a" "edge-b" optionalRules);
      denyDirect = builtins.length (matching "deny-a-to-b" "edge-a" "edge-b" denyRules);
      denyPolicyEgress = builtins.length (builtins.filter
        (rule: (rule.direction or null) == "relation-forward-policy-egress")
        denyRules);
      wrongPathPolicyEgress = builtins.length (builtins.filter
        (rule: (rule.direction or null) == "relation-forward-policy-egress")
        wrongPathRules);
    }
  '
})"

jq -e '
  .requiredDirect == 0
  and .requiredIngressHandoff == 1
  and .requiredEgressReturn >= 1
  and .requiredPolicyEgressForward == 1
  and .optionalDirect == 1
  and .denyDirect == 1
  and .denyPolicyEgress == 0
  and .wrongPathPolicyEgress == 0
' <<<"${result}" >/dev/null || {
  jq . <<<"${result}" >&2
  printf 'FAIL FS-260-HDS-010-SDS-010-SMS-010: policy-required access-to-access traffic may not bypass policy\n' >&2
  exit 1
}

printf 'PASS FS-260-HDS-010-SDS-010-SMS-010: policy-required access-to-access traffic uses selector policy handoffs without a direct selector accept\n'
