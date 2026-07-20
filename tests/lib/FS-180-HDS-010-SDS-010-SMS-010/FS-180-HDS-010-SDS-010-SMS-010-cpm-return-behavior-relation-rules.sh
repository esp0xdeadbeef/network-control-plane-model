#!/usr/bin/env bash
# GAMP-ID: FS-180-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-180-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-180-HDS-010-SDS-010-SMS-030
# GAMP-ID: FS-270-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
# Tests CPM relationRules() returnBehavior emission:
#   SMS-010: production-shaped relation WITHOUT returnBehavior → forward only, no reverse
#   SMS-010: relation WITH returnBehavior="symmetric" → forward + reverse rules
#   SMS-020: deny relation WITHOUT returnBehavior → forward only, no reverse
#   SMS-030: wrong returnBehavior value → forward only, no reverse (seeded negative)
#   SMS-040: reverse rule has correctly swapped fromInterface/toInterface vs forward
#
# Hardened 2026-06-15: mock endpoints are endpoint-aware so interface-swap
# verification actually proves correct from/to reversal. Production-shaped
# DEFAULT fixtures lack returnBehavior (matching NFM communicationContract.relations
# before the D18-NEW fix). If the policy.nix guard is removed, the production
# case catches it because the `noReturn*` fixtures would produce reverse rules.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

result_json="$(mktemp)"
trap 'rm -f "${result_json}"' EXIT

REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    common = import (repoRoot + "/src/cpm/firewall-intent/rules/common.nix") { };

    # --- Endpoint-aware mock interface resolution ---
    # Returns different runtimeIfName per endpoint name, so interface-swap
    # assertions actually prove correct from/to reversal.
    mockEndpointIfaces = relation: endpoint: peerEndpoint:
      let epName = (builtins.tryEval (endpoint.name or "")).value or "";
      in
      if epName == "client" then
        [ { runtimeIfName = "client0";
            backingRef = { lane = { kind = "access"; access = "client"; }; };
          } ]
      else if epName == "resolver" then
        [ { runtimeIfName = "resolver0";
            backingRef = { lane = { kind = "access"; access = "client"; }; };
          } ]
      else if epName == "web" then
        [ { runtimeIfName = "web0";
            backingRef = { lane = { kind = "access"; access = "client"; }; };
          } ]
      else
        [ { runtimeIfName = "unknown0";
            backingRef = { lane = { kind = "access"; access = "client"; }; };
          } ];

    mockEndpointIfacesForPeerAccess = relation: endpoint: peerEndpoint: access:
      let epName = (builtins.tryEval (endpoint.name or "")).value or "";
      in
      if epName == "client" then
        [ { runtimeIfName = "client0-policy";
            backingRef = { lane = { kind = "policy"; }; };
          } ]
      else if epName == "resolver" then
        [ { runtimeIfName = "resolver0-policy";
            backingRef = { lane = { kind = "policy"; }; };
          } ]
      else if epName == "web" then
        [ { runtimeIfName = "web0-policy";
            backingRef = { lane = { kind = "policy"; }; };
          } ]
      else
        [ { runtimeIfName = "unknown0-policy";
            backingRef = { lane = { kind = "policy"; }; };
          } ];

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

    # ── Test data (production-shaped: no returnBehavior by default) ──────────

    # Production shape: NFM communicationContract.relations items have NO returnBehavior.
    # This is what NFM actually emitted before the D18-NEW fix.
    productionAllow = {
      action = "allow";
      id = "allow-client-dns";
      from = { kind = "tenant"; name = "client"; };
      to = { kind = "tenant"; name = "resolver"; };
    };

    # After NFM fix: returnBehavior="symmetric" is present on allow relations
    symmetricAllow = productionAllow // { returnBehavior = "symmetric"; };

    # Seeded negative: wrong returnBehavior value → should NOT emit reverse rules
    wrongReturnAllow = productionAllow // { returnBehavior = "unsupported-value"; };

    # Production deny: deny action WITHOUT returnBehavior
    productionDeny = {
      action = "deny";
      id = "deny-client-bad";
      from = { kind = "tenant"; name = "client"; };
      to = { kind = "tenant"; name = "web"; };
    };

    # Deny with symmetric: reverse rules still emitted for deny when symmetric
    symmetricDeny = productionDeny // { returnBehavior = "symmetric"; };

    # ── Execute ──────────────────────────────────────────────────────────────

    prodAllowRules   = relationRules productionAllow;
    symAllowRules    = relationRules symmetricAllow;
    wrongRetRules    = relationRules wrongReturnAllow;
    prodDenyRules    = relationRules productionDeny;
    symDenyRules     = relationRules symmetricDeny;

    # Helpers
    forwardCount = rules: builtins.length (builtins.filter (r: r.direction == "relation-forward") rules);
    reverseCount = rules: builtins.length (builtins.filter (r: r.direction == "relation-reverse") rules);
    getRule = direction: rules: builtins.head (builtins.filter (r: r.direction == direction) rules);

    symFwd = getRule "relation-forward" symAllowRules;
    symRev = getRule "relation-reverse" symAllowRules;
    denFwd = getRule "relation-forward" symDenyRules;
    denRev = getRule "relation-reverse" symDenyRules;

  in {
    # ── SMS-010: allow tuple → forward + reverse ────────────────────────────

    # Production shape (no returnBehavior): forward only, NO reverse
    prodAllowHasForward = forwardCount prodAllowRules == 1;
    prodAllowHasZeroReverse = reverseCount prodAllowRules == 0;

    # With returnBehavior="symmetric": forward + reverse both present
    symAllowHasForward = forwardCount symAllowRules == 1;
    symAllowHasReverse = reverseCount symAllowRules == 1;
    symAllowTotalCount = builtins.length symAllowRules == 2;

    # ── SMS-020: adjacent denial → no returnBehavior → forward only ──────────

    prodDenyHasForward = forwardCount prodDenyRules == 1;
    prodDenyHasZeroReverse = reverseCount prodDenyRules == 0;

    # Deny WITH symmetric still emits reverse rules (action is deny, not skipped)
    symDenyHasForward = forwardCount symDenyRules == 1;
    symDenyHasReverse = reverseCount symDenyRules == 1;

    # ── SMS-030: wrong returnBehavior → forward only, no reverse ─────────────

    wrongReturnHasForward = forwardCount wrongRetRules == 1;
    wrongReturnHasZeroReverse = reverseCount wrongRetRules == 0;

    # ── SMS-040: reverse rule structure ─────────────────────────────────────

    # Same relationId propagated
    reverseRuleSameId = (symRev.relationId or null) == "allow-client-dns";

    # from/to endpoints swapped in reverse rule
    reverseRuleFromSwapped = (symRev.from or {}).name or "" == "resolver";
    reverseRuleToSwapped = (symRev.to or {}).name or "" == "client";
    reverseRuleDirection = (symRev.direction or "") == "relation-reverse";

    # Forward rule NOT swapped
    forwardRuleFrom = (symFwd.from or {}).name or "" == "client";
    forwardRuleTo = (symFwd.to or {}).name or "" == "resolver";
    forwardRuleDirection = (symFwd.direction or "") == "relation-forward";

    # ── Interface swap verification (endpoint-aware mocks make this real) ────
    # Forward: from=client → fromInterface=client0, to=resolver → toInterface=resolver0-policy
    forwardRuleFromIface = (symFwd.fromInterface or "") == "client0";
    forwardRuleToIface = (symFwd.toInterface or "") == "resolver0-policy";

    # Reverse: from=resolver (swapped) → fromInterface=resolver0, to=client → toInterface=client0-policy
    reverseRuleFromIface = (symRev.fromInterface or "") == "resolver0";
    reverseRuleToIface = (symRev.toInterface or "") == "client0-policy";

    # Prove interfaces actually differ between forward and reverse (the swap is real)
    reverseFromDiffersFromForward = (symRev.fromInterface or "") != (symFwd.fromInterface or "");
    reverseToDiffersFromForward = (symRev.toInterface or "") != (symFwd.toInterface or "");

    # ── Action propagation ──────────────────────────────────────────────────

    reverseRuleAction = (symRev.action or "") == "accept";
    denyReverseRuleAction = (denRev.action or "") == "deny";

    # ── Reverse rule has relationHandoff (policyPointTraversal) ──────────────

    reverseRuleHasHandoff = builtins.isAttrs (symRev.policyPointTraversal or null);
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
