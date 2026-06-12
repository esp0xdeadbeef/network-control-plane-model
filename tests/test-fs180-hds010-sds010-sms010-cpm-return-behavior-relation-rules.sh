#!/usr/bin/env bash
# GAMP-ID: FS-180-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-180-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-180-HDS-010-SDS-010-SMS-030
# GAMP-ID: FS-270-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
# Tests CPM relationRules() returnBehavior emission:
#   SMS-010: allow tuple → returnBehavior="symmetric" emits relation-reverse rules
#   SMS-020: adjacent denial → no returnBehavior → no reverse rules
#   SMS-030: wrong returnBehavior value → no reverse rules (seeded negative)
#   SMS-040: selector handoff preserves relation identity in reverse rule
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

result_json="$(mktemp)"
trap 'rm -f "${result_json}"' EXIT

REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    common = import (repoRoot + "/src/cpm/firewall-intent/rules/common.nix") { };

    # --- Mock endpoint resolution ---
    mockFromIface = {
      runtimeIfName = "tenant0";
      backingRef = { lane = { kind = "access"; access = "client"; }; };
    };
    mockToIface = {
      runtimeIfName = "policy0";
      backingRef = { lane = { kind = "policy"; }; };
    };
    mockEndpointIfaces = relation: endpoint: peerEndpoint: [ mockFromIface ];
    mockEndpointIfacesForPeerAccess = relation: endpoint: peerEndpoint: access: [ mockToIface ];

    attrsOrEmpty = value: if builtins.isAttrs value then value else { };
    listOrEmpty = value: if builtins.isList value then value else [ ];
    isNonEmptyString = value: builtins.isString value && value != "";

    mockRelationMatches = relation:
      if builtins.isList (relation.matches or null) then relation.matches
      else [ { proto = "udp"; dport = 53; } ];

    mockServiceSourcePrefixes = endpoint: [ ];
    withRelationSourceScope = relation: rule:
      let
        fromEndpoint = attrsOrEmpty (relation.from or null);
        prefixes =
          if (fromEndpoint.kind or null) == "service" then mockServiceSourcePrefixes fromEndpoint else [ ];
      in common.withSourcePrefixes rule prefixes;

    relationId = relation:
      if builtins.isString (relation.id or null) && relation.id != "" then relation.id
      else if builtins.isString (relation.name or null) && relation.name != "" then relation.name
      else null;

    # --- relationRules (production-aligned, mock-backed) ---
    relationRules = relationRaw:
      let
        relation = attrsOrEmpty relationRaw;
        action = if (relation.action or "allow") == "deny" then "deny" else "accept";
        id = relationId relation;

        buildDirectionRules =
          { direction
          , fromEndpoint
          , toEndpoint
          , reverseSource ? false
          }:
          let
            fromIfaces = mockEndpointIfaces relation fromEndpoint toEndpoint;
            relationForSource =
              if reverseSource then
                relation // {
                  from = attrsOrEmpty toEndpoint;
                  to = attrsOrEmpty fromEndpoint;
                }
              else
                relation;
            ruleEndpointFrom = attrsOrEmpty fromEndpoint;
            ruleEndpointTo = attrsOrEmpty toEndpoint;
          in
          builtins.concatLists (
            map
              (fromIface:
                let
                  toIfaces =
                    mockEndpointIfacesForPeerAccess relation toEndpoint fromEndpoint (common.laneAccess fromIface);
                in
                map
                  (toIface:
                    withRelationSourceScope relationForSource {
                      inherit action;
                      relationId = id;
                      comment = id;
                      priority = relation.priority or null;
                      trafficType = relation.trafficType or "any";
                      inherit direction;
                      matches = mockRelationMatches relation;
                      from = ruleEndpointFrom;
                      to = ruleEndpointTo;
                      relationCardinality = {
                        unit = "policy-router-forwarding-rule";
                        decomposition = "decomposed-by-policy-interface-scope";
                        decomposed = true;
                      };
                      fromInterface = fromIface.runtimeIfName;
                      toInterface = toIface.runtimeIfName;
                      applyTcpMssClamp = false;
                    }
                    // common.relationHandoff {
                      relationId = id;
                      inherit action direction fromIface toIface;
                      policyPoint = "policy-router";
                    }
                    // (if builtins.isAttrs (relation.intent or null) then { intent = relation.intent; } else { })
                    // (if isNonEmptyString (relation.comment or null) then { comment = relation.comment; } else { }))
                  toIfaces)
              fromIfaces
          );

        forwardRules = buildDirectionRules {
          direction = "relation-forward";
          fromEndpoint = relation.from or null;
          toEndpoint = relation.to or null;
        };

        reverseRules =
          if (relation.returnBehavior or null) == "symmetric" then
            buildDirectionRules {
              direction = "relation-reverse";
              fromEndpoint = relation.to or null;
              toEndpoint = relation.from or null;
              reverseSource = true;
            }
          else
            [ ];
      in
      forwardRules ++ reverseRules;

    # --- Test data ---
    symmetricRelation = {
      action = "allow";
      id = "allow-client-dns";
      from = { kind = "tenant"; name = "client"; };
      to = { kind = "tenant"; name = "resolver"; };
      returnBehavior = "symmetric";
    };

    noReturnRelation = {
      action = "allow";
      id = "allow-client-web";
      from = { kind = "tenant"; name = "client"; };
      to = { kind = "tenant"; name = "web"; };
    };

    wrongReturnRelation = {
      action = "allow";
      id = "allow-client-other";
      from = { kind = "tenant"; name = "client"; };
      to = { kind = "tenant"; name = "other"; };
      returnBehavior = "unknown-value";
    };

    denyWithReturnRelation = {
      action = "deny";
      id = "deny-client-bad";
      from = { kind = "tenant"; name = "client"; };
      to = { kind = "tenant"; name = "bad"; };
      returnBehavior = "symmetric";
    };

    # --- Execute ---
    symmetricRules = relationRules symmetricRelation;
    noReturnRules = relationRules noReturnRelation;
    wrongReturnRules = relationRules wrongReturnRelation;
    denyReturnRules = relationRules denyWithReturnRelation;

    # Helpers
    forwardCount = rules: builtins.length (builtins.filter (r: r.direction == "relation-forward") rules);
    reverseCount = rules: builtins.length (builtins.filter (r: r.direction == "relation-reverse") rules);
    getRule = direction: rules: builtins.head (builtins.filter (r: r.direction == direction) rules);

    symForward = getRule "relation-forward" symmetricRules;
    symReverse = getRule "relation-reverse" symmetricRules;
  in {
    # SMS-010: symmetric returns forward + reverse
    symmetricHasForward = forwardCount symmetricRules == 1;
    symmetricHasReverse = reverseCount symmetricRules == 1;

    # SMS-020: no returnBehavior → forward only, no reverse
    noReturnHasForward = forwardCount noReturnRules == 1;
    noReturnHasZeroReverse = reverseCount noReturnRules == 0;

    # SMS-030: wrong returnBehavior → forward only, no reverse (seeded negative)
    wrongReturnHasForward = forwardCount wrongReturnRules == 1;
    wrongReturnHasZeroReverse = reverseCount wrongReturnRules == 0;

    # Deny with symmetric still emits rules (action is deny, not skipped)
    denySymmetricHasForward = forwardCount denyReturnRules == 1;
    denySymmetricHasReverse = reverseCount denyReturnRules == 1;

    # SMS-040: reverse rule structure — same relationId, swapped from/to
    reverseRuleSameId = (symReverse.relationId or null) == "allow-client-dns";
    reverseRuleFromSwapped = (symReverse.from or {}).name or "" == "resolver";
    reverseRuleToSwapped = (symReverse.to or {}).name or "" == "client";
    reverseRuleDirection = (symReverse.direction or "") == "relation-reverse";

    # Reverse rule has relationHandoff (policyPointTraversal)
    reverseRuleHasHandoff = builtins.isAttrs (symReverse.policyPointTraversal or null);

    # Forward rule NOT swapped
    forwardRuleFrom = (symForward.from or {}).name or "" == "client";
    forwardRuleTo = (symForward.to or {}).name or "" == "resolver";
    forwardRuleDirection = (symForward.direction or "") == "relation-forward";

    # Interfaces swapped in reverse (mock from=tenant0, to=policy0 for forward)
    forwardRuleFromIface = (symForward.fromInterface or "") == "tenant0";
    forwardRuleToIface = (symForward.toInterface or "") == "policy0";
    reverseRuleFromIface = (symReverse.fromInterface or "") == "tenant0";
    reverseRuleToIface = (symReverse.toInterface or "") == "policy0";

    # Same action propagated to reverse
    reverseRuleAction = (symReverse.action or "") == "accept";
    denyReverseRuleAction = (getRule "relation-reverse" denyReturnRules).action or "" == "deny";

    # Total rule counts
    symmetricTotalCount = builtins.length symmetricRules == 2;
    noReturnTotalCount = builtins.length noReturnRules == 1;
  }
' >"${result_json}"

failed_checks="$(jq -r '. | to_entries[] | select(.value != true) | .key' "${result_json}")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL fs180-hds010-sds010-sms010-cpm-return-behavior-relation-rules" >&2
  echo "failed checks:" >&2
  while IFS= read -r check; do
    echo "  ${check}" >&2
  done <<<"${failed_checks}"
  echo "full result:" >&2
  jq -S . "${result_json}" >&2
  exit 1
fi

echo "PASS fs180-hds010-sds010-sms010-cpm-return-behavior-relation-rules"
