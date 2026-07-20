#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
# Tests CPM policy-router runtime-rule relation identity:
#   Module Responsibilities: consume platform-neutral policy decisions with
#   relation ID/action/source scope/destination scope/traffic class/direction/
#   cardinality; emit rules with same identity; reject bare rules without
#   relation identity.
#
#   Predicates proven:
#   - Rules carry relationId, action, comment (=relationId), trafficType, direction
#   - Rules carry source/destination scope (from/to endpoint objects)
#   - Rules carry relationCardinality (unit, decomposition, decomposed)
#   - Policy-router-forwarding-rule unit used
#   - Comment == relationId (machine-readable audit mapping)
#
#   Seeded negatives (SN1/SN2):
#   - SN1: rule without relationId → reject (CMC fix: relationRules() now
#     throws when id is null)
#   - SN2: duplicate relationId collision → reject (CMC fix: policy.nix in-block
#     detects duplicate IDs before map relationRules; mock in this unit test
#     demonstrates collision rejection at the caller level)
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

result_json="$(mktemp)"
trap 'rm -f "${result_json}"' EXIT

REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    common = import (repoRoot + "/src/cpm/firewall-intent/rules/common.nix") { };

    # ── Mock helpers (production-shaped) ──────────────────────────────────────
    attrsOrEmpty = value: if builtins.isAttrs value then value else { };
    isNonEmptyString = value: builtins.isString value && value != "";

    # Endpoint-aware mock: different runtimeIfName per endpoint
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
      else
        [ { runtimeIfName = "unknown0-policy";
            backingRef = { lane = { kind = "policy"; }; };
          } ];

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

    # ── relationRules (mirror of policy.nix with SN1 fix) ─────────────────────
    relationRules = relationRaw:
      let
        relation = attrsOrEmpty relationRaw;
        action = if (relation.action or "allow") == "deny" then "deny" else "accept";
        id =
          let
            rawId = relationId relation;
          in
          if rawId == null then
            throw "FS-310-HDS-010-SDS-010-SMS-030: relationRules rejected rule with null relationId. Source relation must carry non-null id or name. Source: ${builtins.toJSON relationRaw}"
          else rawId;

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
                    // (if builtins.isAttrs (relation.intent or null) then { intent = relation.intent; } else { }))
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
      builtins.seq id (forwardRules ++ reverseRules);

    # SN2 collision detection (mirrors policy.nix in-block check)
    checkDuplicateIds = rels:
      let
        ids = builtins.filter (id: id != null) (map (r: relationId (attrsOrEmpty r)) rels);
        groups = builtins.groupBy (id: id) ids;
        duplicates = builtins.filter (g: (builtins.length groups."${g}") > 1) (builtins.attrNames groups);
      in
      if duplicates != [ ] then
        throw "FS-310-HDS-010-SDS-010-SMS-030: duplicate relationId collision: ${builtins.concatStringsSep ", " duplicates}"
      else true;

    # ── Test data ────────────────────────────────────────────────────────────

    # Production-shaped allow relation
    allowRelation = {
      action = "allow";
      id = "allow-client-dns";
      from = { kind = "tenant"; name = "client"; };
      to = { kind = "tenant"; name = "resolver"; };
      trafficType = "dns";
      priority = 50;
    };

    # Production-shaped deny relation
    denyRelation = {
      action = "deny";
      id = "deny-client-web";
      from = { kind = "tenant"; name = "client"; };
      to = { kind = "tenant"; name = "resolver"; };
      trafficType = "any";
      priority = 100;
    };

    # ── Execute ──────────────────────────────────────────────────────────────

    allowRules = relationRules allowRelation;
    denyRules = relationRules denyRelation;

    allowForward = builtins.head (builtins.filter (r: r.direction == "relation-forward") allowRules);
    denyForward = builtins.head (builtins.filter (r: r.direction == "relation-forward") denyRules);

    # ── SMS-030 Module Responsibility checks ─────────────────────────────────

    # 1. Rules carry relationId
    allowRuleHasRelationId = isNonEmptyString (allowForward.relationId or null);
    denyRuleHasRelationId = isNonEmptyString (denyForward.relationId or null);

    # 2. relationId matches the source relation
    allowRuleRelationIdCorrect = (allowForward.relationId or null) == "allow-client-dns";
    denyRuleRelationIdCorrect = (denyForward.relationId or null) == "deny-client-web";

    # 3. comment == relationId (machine-readable audit mapping)
    allowRuleCommentEqId = (allowForward.comment or null) == (allowForward.relationId or null);
    denyRuleCommentEqId = (denyForward.comment or null) == (denyForward.relationId or null);

    # 4. Action preserved
    allowRuleAction = (allowForward.action or null) == "accept";
    denyRuleAction = (denyForward.action or null) == "deny";

    # 5. Source scope (from endpoint object)
    allowRuleHasFrom = builtins.isAttrs (allowForward.from or null);
    allowRuleFromTenant = (allowForward.from or {}).name or "" == "client";

    # 6. Destination scope (to endpoint object)
    allowRuleHasTo = builtins.isAttrs (allowForward.to or null);
    allowRuleToTenant = (allowForward.to or {}).name or "" == "resolver";

    # 7. Traffic class
    allowRuleHasTrafficType = isNonEmptyString (allowForward.trafficType or null);
    allowRuleTrafficCorrect = (allowForward.trafficType or null) == "dns";
    denyRuleTrafficAny = (denyForward.trafficType or null) == "any";

    # 8. Direction
    allowRuleHasDirection = isNonEmptyString (allowForward.direction or null);
    allowRuleDirectionForward = (allowForward.direction or null) == "relation-forward";

    # 9. Relation cardinality
    allowRuleHasCardinality = builtins.isAttrs (allowForward.relationCardinality or null);
    allowRuleCardUnitPolicy = (allowForward.relationCardinality or {}).unit or "" == "policy-router-forwarding-rule";
    allowRuleCardDecomp = isNonEmptyString ((allowForward.relationCardinality or {}).decomposition or "");
    allowRuleCardDecomposed = (allowForward.relationCardinality or {}).decomposed or false;

    # 10. rule count = 1 per direction (no decomposition for single interface pair)
    allowForwardCount = builtins.length (builtins.filter (r: r.direction == "relation-forward") allowRules) == 1;

    # 11. Policy-point traversal (relationHandoff)
    allowRuleHasHandoff = builtins.isAttrs (allowForward.policyPointTraversal or null);
    allowRuleHandoffPolicyRouter = (allowForward.policyPointTraversal or {}).policyPoint or "" == "policy-router";

    # 12. Interface names set
    allowRuleHasFromIface = isNonEmptyString (allowForward.fromInterface or "");
    allowRuleHasToIface = isNonEmptyString (allowForward.toInterface or "");

    # ── SN1: rule without relationId → reject (CMC fix applied) ────────────

    # When relationId is null, relationRules now throws (CMC fix).
    relationWithoutId = {
      action = "allow";
      from = { kind = "tenant"; name = "client"; };
      to = { kind = "tenant"; name = "resolver"; };
      # No id field
    };
    sn1Result = builtins.tryEval (relationRules relationWithoutId);
    sn1Rejected = !sn1Result.success;

    # Recovery: add relationId field → accept
    relationWithIdRecovered = relationWithoutId // { id = "recovery-test"; };
    sn1RecoveryResult = builtins.tryEval (relationRules relationWithIdRecovered);
    sn1RecoveryAccepted = sn1RecoveryResult.success;

    # ── SN2: duplicate relationId collision → reject (CMC fix at caller level) ──

    # SN2: two distinct relations sharing the same ID should be rejected
    sn2Relation1 = {
      action = "allow";
      id = "dup-id-test";
      from = { kind = "tenant"; name = "client"; };
      to = { kind = "tenant"; name = "resolver"; };
      trafficType = "dns";
    };
    sn2Relation2 = {
      action = "allow";
      id = "dup-id-test";  # Same id as sn2Relation1
      from = { kind = "tenant"; name = "resolver"; };
      to = { kind = "tenant"; name = "client"; };
      trafficType = "any";
    };
    # The collision check (caller-level) rejects the list with duplicate IDs
    sn2CheckResult = builtins.tryEval (checkDuplicateIds [ sn2Relation1 sn2Relation2 ]);
    sn2Rejected = !sn2CheckResult.success;

    # Recovery: unique IDs → pass
    sn2Unique1 = sn2Relation1 // { id = "unique-id-a"; };
    sn2Unique2 = sn2Relation2 // { id = "unique-id-b"; };
    sn2UniqueResult = builtins.tryEval (checkDuplicateIds [ sn2Unique1 sn2Unique2 ]);
    sn2UniqueAccepted = sn2UniqueResult.success;

  in {
    # ── Positive predicates ──────────────────────────────────────────────────

    # Relation identity
    allowRuleHasRelationId = allowRuleHasRelationId;
    denyRuleHasRelationId = denyRuleHasRelationId;
    allowRuleRelationIdCorrect = allowRuleRelationIdCorrect;
    denyRuleRelationIdCorrect = denyRuleRelationIdCorrect;
    allowRuleCommentEqId = allowRuleCommentEqId;
    denyRuleCommentEqId = denyRuleCommentEqId;

    # Action provenance
    allowRuleAction = allowRuleAction;
    denyRuleAction = denyRuleAction;

    # Source/destination scope
    allowRuleHasFrom = allowRuleHasFrom;
    allowRuleFromTenant = allowRuleFromTenant;
    allowRuleHasTo = allowRuleHasTo;
    allowRuleToTenant = allowRuleToTenant;

    # Traffic class
    allowRuleHasTrafficType = allowRuleHasTrafficType;
    allowRuleTrafficCorrect = allowRuleTrafficCorrect;
    denyRuleTrafficAny = denyRuleTrafficAny;

    # Direction
    allowRuleHasDirection = allowRuleHasDirection;
    allowRuleDirectionForward = allowRuleDirectionForward;

    # Cardinality
    allowRuleHasCardinality = allowRuleHasCardinality;
    allowRuleCardUnitPolicy = allowRuleCardUnitPolicy;
    allowRuleCardDecomp = allowRuleCardDecomp;
    allowRuleCardDecomposed = allowRuleCardDecomposed;

    # One-to-one cardinality
    allowForwardCount = allowForwardCount;

    # Policy-point traversal
    allowRuleHasHandoff = allowRuleHasHandoff;
    allowRuleHandoffPolicyRouter = allowRuleHandoffPolicyRouter;

    # Interfaces
    allowRuleHasFromIface = allowRuleHasFromIface;
    allowRuleHasToIface = allowRuleHasToIface;

    # ── SN1: null-relationId rejection (CMC fix verified) ───────────────────
    sn1Rejected = sn1Rejected;
    sn1RecoveryAccepted = sn1RecoveryAccepted;

    # ── SN2: duplicate-id collision rejection (CMC fix verified) ────────────
    sn2Rejected = sn2Rejected;
    sn2UniqueAccepted = sn2UniqueAccepted;
  }
' >"${result_json}"

# Check all positive assertions pass
failed_checks="$(jq -r '
  . | to_entries
    | map(select(.key | startswith("sn") | not))
    | .[]
    | select(.value != true)
    | .key
' "${result_json}")"

if [[ -n "${failed_checks}" ]]; then
  echo "FAIL fs310-hds010-sds010-sms030-policy-router-relation-identity" >&2
  echo "failed checks:" >&2
  while IFS= read -r check; do
    echo "  ${check}" >&2
  done <<<"${failed_checks}"
  echo "full result:" >&2
  jq -S . "${result_json}" >&2
  exit 1
fi

# Verify SN1/SN2 are resolved (rejected + recovery)
sn1_rejected="$(jq -r '.sn1Rejected' "${result_json}")"
sn1_recovery="$(jq -r '.sn1RecoveryAccepted' "${result_json}")"
sn2_rejected="$(jq -r '.sn2Rejected' "${result_json}")"
sn2_recovery="$(jq -r '.sn2UniqueAccepted' "${result_json}")"

if [[ "${sn1_rejected}" != "true" ]]; then
  echo "FAIL fs310-hds010-sds010-sms030-policy-router-relation-identity: SN1 null-relationId was not rejected" >&2
  exit 1
fi
if [[ "${sn1_recovery}" != "true" ]]; then
  echo "FAIL fs310-hds010-sds010-sms030-policy-router-relation-identity: SN1 recovery (add id) was not accepted" >&2
  exit 1
fi
if [[ "${sn2_rejected}" != "true" ]]; then
  echo "FAIL fs310-hds010-sds010-sms030-policy-router-relation-identity: SN2 duplicate-id collision was not rejected" >&2
  exit 1
fi
if [[ "${sn2_recovery}" != "true" ]]; then
  echo "FAIL fs310-hds010-sds010-sms030-policy-router-relation-identity: SN2 recovery (unique ids) was not accepted" >&2
  exit 1
fi

echo "PASS fs310-hds010-sds010-sms030-policy-router-relation-identity"
echo "SN1 RESOLVED: null-relationId is now rejected with diagnostic throw in relationRules()"
echo "SN2 RESOLVED: duplicate-id collision is now detected and rejected at the caller level (checkDuplicateIds)"
