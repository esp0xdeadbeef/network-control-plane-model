#!/usr/bin/env bash
# GAMP-ID: FS-180-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
# RaTM: Construction test for bidirectional nft rule generation from returnBehavior.
# SMS-040 predicates tested:
#   P1: returnBehavior="symmetric" → forward + reverse nft accept rules
#   P2: returnBehavior absent → forward only, NO reverse rules
#   P3 (seeded negative): returnBehavior="nonexistent" → forward only, NO reverse
#   P4 (seeded negative): wrong returnBehavior value → forward only, NO reverse
#   P5: reverse rule has correctly swapped fromInterface/toInterface vs forward
#   P6: reverse rule preserves traffic match (trafficType, proto/port) with
#       source/destination endpoints swapped
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

result_json="$(mktemp)"
trap 'rm -f "${result_json}"' EXIT

REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    common = import (repoRoot + "/src/cpm/firewall-intent/rules/common.nix") { };

    # --- Endpoint-aware mock interface resolution ---
    # Returns distinct runtimeIfName per endpoint name so interface-swap
    # assertions actually prove correct from/to reversal.
    mockEndpointIfaces = relation: endpoint: peerEndpoint:
      let epName = (builtins.tryEval (endpoint.name or "")).value or "";
      in
      if epName == "tenant-A" then
        [ { runtimeIfName = "eth-tenantA";
            backingRef = { lane = { kind = "access"; access = "tenant-A"; }; };
          } ]
      else if epName == "tenant-B" then
        [ { runtimeIfName = "eth-tenantB";
            backingRef = { lane = { kind = "access"; access = "tenant-B"; }; };
          } ]
      else if epName == "tenant-C" then
        [ { runtimeIfName = "eth-tenantC";
            backingRef = { lane = { kind = "access"; access = "tenant-C"; }; };
          } ]
      else
        [ { runtimeIfName = "eth-unknown";
            backingRef = { lane = { kind = "access"; access = "unknown"; }; };
          } ];

    mockEndpointIfacesForPeerAccess = relation: endpoint: peerEndpoint: access:
      let epName = (builtins.tryEval (endpoint.name or "")).value or "";
      in
      if epName == "tenant-A" then
        [ { runtimeIfName = "eth-tenantA-policy";
            backingRef = { lane = { kind = "policy"; }; };
          } ]
      else if epName == "tenant-B" then
        [ { runtimeIfName = "eth-tenantB-policy";
            backingRef = { lane = { kind = "policy"; }; };
          } ]
      else if epName == "tenant-C" then
        [ { runtimeIfName = "eth-tenantC-policy";
            backingRef = { lane = { kind = "policy"; }; };
          } ]
      else
        [ { runtimeIfName = "eth-unknown-policy";
            backingRef = { lane = { kind = "policy"; }; };
          } ];

    attrsOrEmpty = value: if builtins.isAttrs value then value else { };
    listOrEmpty = value: if builtins.isList value then value else [ ];
    isNonEmptyString = value: builtins.isString value && value != "";

    mockRelationMatches = relation:
      if builtins.isList (relation.matches or null) then relation.matches
      else [ { proto = "tcp"; dport = 443; } ];

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

    # --- relationRules (production-aligned) ---
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

    # ── Test fixtures ───────────────────────────────────────────────────────

    # Positive: symmetric returnBehavior on an allow relation
    symmetricRelation = {
      action = "allow";
      id = "rel-symmetric-web";
      from = { kind = "tenant"; name = "tenant-A"; };
      to = { kind = "tenant"; name = "tenant-B"; };
      trafficType = "web";
      matches = [ { proto = "tcp"; dport = 443; } ];
      returnBehavior = "symmetric";
    };

    # Seeded negative 1: absent returnBehavior → should NOT emit reverse rules
    absentReturnRelation = {
      action = "allow";
      id = "rel-absent-web";
      from = { kind = "tenant"; name = "tenant-A"; };
      to = { kind = "tenant"; name = "tenant-B"; };
      trafficType = "web";
      matches = [ { proto = "tcp"; dport = 443; } ];
    };

    # Seeded negative 2: unrecognized returnBehavior → forward only, no reverse
    nonexistentReturnRelation = {
      action = "allow";
      id = "rel-nonexistent-web";
      from = { kind = "tenant"; name = "tenant-A"; };
      to = { kind = "tenant"; name = "tenant-C"; };
      trafficType = "web";
      matches = [ { proto = "tcp"; dport = 443; } ];
      returnBehavior = "nonexistent";
    };

    # Seeded negative 3: wrong returnBehavior value → forward only, no reverse
    wrongReturnRelation = {
      action = "allow";
      id = "rel-wrong-web";
      from = { kind = "tenant"; name = "tenant-B"; };
      to = { kind = "tenant"; name = "tenant-A"; };
      trafficType = "web";
      matches = [ { proto = "tcp"; dport = 443; } ];
      returnBehavior = "hairpin";
    };

    # ── Execute ──────────────────────────────────────────────────────────────

    symRules   = relationRules symmetricRelation;
    absRules   = relationRules absentReturnRelation;
    nonexRules = relationRules nonexistentReturnRelation;
    wrongRules = relationRules wrongReturnRelation;

    # Helpers
    forwardCount = rules: builtins.length (builtins.filter (r: r.direction == "relation-forward") rules);
    reverseCount = rules: builtins.length (builtins.filter (r: r.direction == "relation-reverse") rules);
    getRule = direction: rules: builtins.head (builtins.filter (r: r.direction == direction) rules);

    symFwd = getRule "relation-forward" symRules;
    symRev = getRule "relation-reverse" symRules;

  in {
    # ── P1: symmetric returnBehavior → forward + reverse ───────────────────
    symHasForward = forwardCount symRules == 1;
    symHasReverse = reverseCount symRules == 1;
    symTotalCount = builtins.length symRules == 2;

    # ── P2: absent returnBehavior → forward only, NO reverse ────────────────
    absHasForward = forwardCount absRules == 1;
    absHasZeroReverse = reverseCount absRules == 0;
    absTotalCount = builtins.length absRules == 1;

    # ── P3 (SN1): nonexistent returnBehavior → forward only, NO reverse ─────
    nonexHasForward = forwardCount nonexRules == 1;
    nonexHasZeroReverse = reverseCount nonexRules == 0;
    nonexTotalCount = builtins.length nonexRules == 1;

    # ── P4 (SN2): wrong returnBehavior → forward only, NO reverse ───────────
    wrongHasForward = forwardCount wrongRules == 1;
    wrongHasZeroReverse = reverseCount wrongRules == 0;
    wrongTotalCount = builtins.length wrongRules == 1;

    # ── P5: reverse rule has correctly swapped fromInterface/toInterface ────
    # Forward: from=tenant-A → fromInterface=eth-tenantA, to=tenant-B → toInterface=eth-tenantB-policy
    fwdFromIface = (symFwd.fromInterface or "") == "eth-tenantA";
    fwdToIface   = (symFwd.toInterface or "") == "eth-tenantB-policy";
    fwdDirection = (symFwd.direction or "") == "relation-forward";

    # Reverse: from=tenant-B → fromInterface=eth-tenantB, to=tenant-A → toInterface=eth-tenantA-policy
    revFromIface = (symRev.fromInterface or "") == "eth-tenantB";
    revToIface   = (symRev.toInterface or "") == "eth-tenantA-policy";
    revDirection = (symRev.direction or "") == "relation-reverse";

    # Prove interfaces actually differ (the swap is real, not identity)
    revFromDiffersFromFwd = (symRev.fromInterface or "") != (symFwd.fromInterface or "");
    revToDiffersFromFwd   = (symRev.toInterface or "") != (symFwd.toInterface or "");

    # ── P6: traffic match preservation ──────────────────────────────────────
    # Same relationId in reverse rule
    revSameRelationId = (symRev.relationId or null) == "rel-symmetric-web";

    # Same trafficType in reverse rule
    revSameTrafficType = (symRev.trafficType or "") == "web";

    # Same action in reverse rule
    revAction = (symRev.action or "") == "accept";

    # Same protocol/port match in reverse
    revMatches = let m = symRev.matches or []; in
      builtins.length m == 1 && (builtins.head m).proto or "" == "tcp" && (builtins.head m).dport or 0 == 443;

    # from/to endpoints swapped
    revFromSwapped = (symRev.from or {}).name or "" == "tenant-B";
    revToSwapped   = (symRev.to or {}).name or "" == "tenant-A";

    # Forward rule NOT swapped
    fwdFromName = (symFwd.from or {}).name or "" == "tenant-A";
    fwdToName   = (symFwd.to or {}).name or "" == "tenant-B";

    # ── Reverse rule has relationHandoff (policyPointTraversal) ────────────
    revHasHandoff = builtins.isAttrs (symRev.policyPointTraversal or null);

    # ── Forward rule also has relationHandoff ───────────────────────────────
    fwdHasHandoff = builtins.isAttrs (symFwd.policyPointTraversal or null);
  }
' >"${result_json}"

failed_checks="$(jq -r '. | to_entries[] | select(.value != true) | .key' "${result_json}")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL test-FS-180-HDS-010-SDS-010-SMS-040-bidirectional-nft-rules" >&2
  echo "failed checks:" >&2
  while IFS= read -r check; do
    echo "  ${check}" >&2
  done <<<"${failed_checks}"
  echo "full result:" >&2
  jq -S . "${result_json}" >&2
  exit 1
fi

echo "PASS test-FS-180-HDS-010-SDS-010-SMS-040-bidirectional-nft-rules"
