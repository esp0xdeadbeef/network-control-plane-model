#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-020-SDS-010-SMS-075
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

result="$(REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    lib = import <nixpkgs/lib>;
    common = {
      attrsOrEmpty = value: if builtins.isAttrs value then value else { };
      listOrEmpty = value: if builtins.isList value then value else [ ];
    };
    addPublicIngressPath = import (repoRoot + "/src/cpm/ControlModule/runtime-targets/public-ingress-routes.nix") {
      inherit lib common;
    };
    relationId = "allow-wan-to-nebula";
    record = {
      inherit relationId;
      publicSurface = "wan";
      translationOwnerRuntimeTarget = "core";
      target = {
        address = "192.0.2.10";
        port = 4242;
        accessNode = "access-dmz";
        providerTenants = [ "dmz" ];
      };
      tupleRecords = [
        { protocol = "udp"; publicPort = 4242; targetPort = 4242; }
        { protocol = "tcp"; publicPort = 4242; targetPort = 4242; }
      ];
      internalPath.egressInterface = "core";
      sourceTranslation.address = "10.19.0.3";
    };
    iface = runtimeIfName: sourceKind: addr4: lane: backingName: {
      inherit runtimeIfName sourceKind addr4;
      backingRef = {
        name = backingName;
        inherit lane;
      };
      routes = { ipv4 = [ ]; ipv6 = [ ]; };
    };
    broadRule = fromInterface: toInterface: {
      inherit relationId fromInterface toInterface;
      action = "accept";
      trafficType = "nebula";
    };
    runtimeTargets = {
      core = {
        role = "core";
        natIntent.publicIngress = [ record ];
        effectiveRuntimeRealization.interfaces = {
          uplink = iface "core" "p2p" "10.0.0.0/31" { kind = "uplink"; uplink = "wan"; } "core-upstream";
        };
      };
      upstream = {
        role = "upstream-selector";
        forwardingIntent.rules = [ (broadRule "core" "policy-dmz") ];
        effectiveRuntimeRealization.interfaces = {
          core = iface "core" "p2p" "10.0.0.1/31" { kind = "uplink"; uplink = "wan"; } "core-upstream";
          policy = iface "policy-dmz" "p2p" "10.0.0.2/31" { kind = "access-uplink"; access = "access-dmz"; uplink = "wan"; } "upstream-policy-dmz";
        };
      };
      policy = {
        role = "policy";
        forwardingIntent.rules = [ (broadRule "upstream-dmz" "downstream-dmz") ];
        effectiveRuntimeRealization.interfaces = {
          upstream = iface "upstream-dmz" "p2p" "10.0.0.3/31" { kind = "access-uplink"; access = "access-dmz"; uplink = "wan"; } "upstream-policy-dmz";
          downstream = iface "downstream-dmz" "p2p" "10.0.0.4/31" { kind = "access"; access = "access-dmz"; } "policy-downstream-dmz";
        };
      };
      downstream = {
        role = "downstream-selector";
        forwardingIntent.rules = [ ];
        effectiveRuntimeRealization.interfaces = {
          policy = iface "policy-dmz" "p2p" "10.0.0.5/31" { kind = "access"; access = "access-dmz"; } "policy-downstream-dmz";
          access = iface "access-dmz" "p2p" "10.0.0.6/31" { kind = "access-edge"; access = "access-dmz"; } "downstream-access-dmz";
        };
      };
      access = {
        role = "access";
        logicalNode.name = "access-dmz";
        forwardingIntent.rules = [ ];
        effectiveRuntimeRealization.interfaces = {
          upstream = iface "access-dmz" "p2p" "10.0.0.7/31" { kind = "access-edge"; access = "access-dmz"; } "downstream-access-dmz";
          tenant = iface "lan-dmz" "tenant" "192.0.2.1/24" { kind = "tenant"; access = "access-dmz"; } "dmz";
        };
      };
      unrelated = {
        role = "access";
        logicalNode.name = "access-other";
        forwardingIntent.rules = [ ];
        effectiveRuntimeRealization.interfaces.tenant =
          iface "lan-other" "tenant" "198.51.100.1/24" { kind = "tenant"; access = "access-other"; } "other";
      };
    };
    out = addPublicIngressPath runtimeTargets;
    relationRules = target:
      builtins.filter (rule: (rule.relationId or null) == relationId) (out.${target}.forwardingIntent.rules or [ ]);
    routeDsts = target: interface:
      map (route: route.dst) (out.${target}.effectiveRuntimeRealization.interfaces.${interface}.routes.ipv4 or [ ]);
    summarizeRule = target:
      let rules = relationRules target;
      in if builtins.length rules != 1 then { count = builtins.length rules; }
      else let rule = builtins.head rules; in {
        count = 1;
        from = rule.fromInterface;
        to = rule.toInterface;
        matches = rule.matches;
        destinations = rule.destinationPrefixes;
        authority = rule.transportAuthority.basis;
      };
  in {
    rules = builtins.listToAttrs (map (target: { name = target; value = summarizeRule target; }) [
      "upstream" "policy" "downstream" "access"
    ]);
    unrelatedRuleCount = builtins.length (relationRules "unrelated");
    routes = {
      coreTarget = routeDsts "core" "uplink";
      upstreamTarget = routeDsts "upstream" "policy";
      upstreamReturn = routeDsts "upstream" "core";
      policyTarget = routeDsts "policy" "downstream";
      policyReturn = routeDsts "policy" "upstream";
      downstreamTarget = routeDsts "downstream" "access";
      downstreamReturn = routeDsts "downstream" "policy";
      accessTarget = routeDsts "access" "tenant";
      accessReturn = routeDsts "access" "upstream";
    };
  }
')"

jq -e '
  .rules as $rules
  | ([ $rules[] | .count ] | all(. == 1))
    and ([ $rules[] | .authority ] | all(. == "public-ingress-tuple-authority"))
    and ([ $rules[] | .destinations ] | all(. == [{"family":4,"prefix":"192.0.2.10/32"}]))
    and ([ $rules[] | .matches ] | all(
      length == 2
      and map(.family) == ["ipv4","ipv4"]
      and map(.proto) == ["udp","tcp"]
      and map(.dports) == [[4242],[4242]]
    ))
    and ($rules.upstream.from == "core" and $rules.upstream.to == "policy-dmz")
    and ($rules.policy.from == "upstream-dmz" and $rules.policy.to == "downstream-dmz")
    and ($rules.downstream.from == "policy-dmz" and $rules.downstream.to == "access-dmz")
    and ($rules.access.from == "access-dmz" and $rules.access.to == "lan-dmz")
    and (.unrelatedRuleCount == 0)
    and ([.routes.coreTarget, .routes.upstreamTarget, .routes.policyTarget, .routes.downstreamTarget, .routes.accessTarget] | all(index("192.0.2.10/32") != null))
    and ([.routes.upstreamReturn, .routes.policyReturn, .routes.downstreamReturn, .routes.accessReturn] | all(index("10.19.0.3/32") != null))
' <<<"${result}" >/dev/null

echo "PASS FS-310-HDS-020-SDS-010-SMS-075: exact public-ingress tuple and /32 path are emitted across every runtime namespace"
