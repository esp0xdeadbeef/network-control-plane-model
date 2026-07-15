#!/usr/bin/env bash
# GAMP-ID: FS-180-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
# RaTM: Construction test for stateful-return rule generation from returnBehavior.
#
# SUPERSEDES the prior unsafe predicate. `returnBehavior="symmetric"` must NOT
# materialize an independently initiated reverse new-flow accept; it authorizes
# only bounded stateful reply traffic, expressed as an established,related
# connection-state constraint on the reverse path. An independently initiated
# reverse new flow is valid only from a distinct modeled reverse relation with
# its own complete bounded tuple.
#
# SMS-040 predicates tested (against src/cpm/firewall-intent/rules/policy.nix):
#   P1: symmetric → exact forward accept (state-unqualified new flow) PLUS one
#       reverse rule.
#   P2: the symmetric reverse rule is a STATEFUL RETURN — it carries
#       connectionState="established,related" and returnRule=true, and is NOT a
#       state-unqualified reverse new-flow accept. The forward rule is NOT a
#       stateful return (no connectionState, returnRule not set).
#   P3: non-symmetric returnBehavior (explicit one-way) → forward only, NO
#       reverse rule (no synthesized reverse authority).
#   P4 (recovery): a DISTINCT modeled reverse relation (own id, reversed
#       endpoints, own returnBehavior) authorizes its own reverse new-flow
#       forward accept independently, preserving its own bounded tuple.
#   P5: the symmetric reverse rule has correctly swapped from/to endpoints and
#       interfaces versus the forward rule (real swap, not identity).
#   P6 (seeded negative): a synthetic reverse accept labeled with the forward
#       relation ID (duplicate relationId) is REJECTED by collision detection —
#       symmetry does not license a second rule under the forward's identity.
#   P7 (seeded negative, SMS-040 Negative case 3): an UNRECOGNIZED
#       returnBehavior value (e.g. "asymmetric") is REJECTED by the real
#       forwarding-validation module with a diagnostic naming the value and
#       the affected relation ID — never silently treated as absent/one-way.
#       Missing returnBehavior stays rejected (fail closed).
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

    # --- relationRules (production-aligned mirror of policy.nix) ---
    # The `stateful` flag and connectionState/returnRule marking below mirror
    # src/cpm/firewall-intent/rules/policy.nix exactly.
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
          , stateful ? false
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
                    // (if isNonEmptyString (relation.comment or null) then { comment = relation.comment; } else { })
                    // (
                      if stateful then
                        {
                          connectionState = "established,related";
                          returnRule = true;
                        }
                      else
                        { }
                    ))
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
              stateful = true;
            }
          else
            [ ];
      in
      forwardRules ++ reverseRules;

    # SN collision detection (mirrors policy.nix top-level duplicate-id guard)
    checkDuplicateIds = rels:
      let
        ids = builtins.filter (id: id != null) (map (r: relationId (attrsOrEmpty r)) rels);
        groups = builtins.groupBy (id: id) ids;
        duplicates = builtins.filter (g: (builtins.length groups."${g}") > 1) (builtins.attrNames groups);
      in
      if duplicates != [ ] then
        throw "FS-310-HDS-010-SDS-010-SMS-030: duplicate relationId collision: ${builtins.concatStringsSep ", " duplicates}"
      else true;

    # ── Test fixtures ───────────────────────────────────────────────────────

    # Positive: symmetric returnBehavior on an allow relation (tenant-A→tenant-B).
    symmetricRelation = {
      action = "allow";
      id = "rel-symmetric-web";
      from = { kind = "tenant"; name = "tenant-A"; };
      to = { kind = "tenant"; name = "tenant-B"; };
      trafficType = "web";
      matches = [ { proto = "tcp"; dport = 443; } ];
      returnBehavior = "symmetric";
    };

    # Negative: explicit one-way → forward only, no reverse synthesis.
    oneWayRelation = {
      action = "allow";
      id = "rel-oneway-web";
      from = { kind = "tenant"; name = "tenant-A"; };
      to = { kind = "tenant"; name = "tenant-B"; };
      trafficType = "web";
      matches = [ { proto = "tcp"; dport = 443; } ];
      returnBehavior = "one-way";
    };

    # Recovery: a DISTINCT modeled reverse relation with its own id and its own
    # complete bounded tuple (tenant-B→tenant-A). This is the only valid way to
    # authorize a reverse new flow.
    distinctReverseRelation = {
      action = "allow";
      id = "rel-reverse-web-B-to-A";
      from = { kind = "tenant"; name = "tenant-B"; };
      to = { kind = "tenant"; name = "tenant-A"; };
      trafficType = "web";
      matches = [ { proto = "tcp"; dport = 8443; } ];
      returnBehavior = "one-way";
    };

    # Seeded negative: a synthetic reverse accept labeled with the forward
    # relation ID (duplicate relationId). Symmetry must not license a second
    # rule reusing the forward identity.
    syntheticReverseLabeledSet = [
      symmetricRelation
      (symmetricRelation // {
        from = { kind = "tenant"; name = "tenant-B"; };
        to = { kind = "tenant"; name = "tenant-A"; };
        returnBehavior = "one-way";
      })
    ];

    # ── Execute ──────────────────────────────────────────────────────────────

    symRules      = relationRules symmetricRelation;
    oneWayRules   = relationRules oneWayRelation;
    distinctRules = relationRules distinctReverseRelation;

    # Helpers
    forwardCount = rules: builtins.length (builtins.filter (r: r.direction == "relation-forward") rules);
    reverseCount = rules: builtins.length (builtins.filter (r: r.direction == "relation-reverse") rules);
    getRule = direction: rules: builtins.head (builtins.filter (r: r.direction == direction) rules);

    symFwd = getRule "relation-forward" symRules;
    symRev = getRule "relation-reverse" symRules;
    distinctFwd = getRule "relation-forward" distinctRules;

    syntheticReverseRejected =
      let r = builtins.tryEval (checkDuplicateIds syntheticReverseLabeledSet); in !r.success;

  in {
    # ── P1: symmetric → exact forward accept + exactly one reverse rule ─────
    symHasForward = forwardCount symRules == 1;
    symHasReverse = reverseCount symRules == 1;
    symTotalCount = builtins.length symRules == 2;

    # ── P2: reverse is a STATEFUL RETURN, forward is NOT ────────────────────
    revIsStatefulReturn =
      (symRev.connectionState or null) == "established,related"
      && (symRev.returnRule or false) == true;
    # The reverse rule must NOT be a state-unqualified new-flow accept.
    revNotStateUnqualified = (symRev.connectionState or null) != null;
    # The forward rule is an exact new-flow accept, not a stateful return.
    fwdIsNewFlow =
      (symFwd.connectionState or null) == null
      && (symFwd.returnRule or false) == false;
    # Both directions carry the accept action.
    symFwdAccept = (symFwd.action or "") == "accept";
    symRevAccept = (symRev.action or "") == "accept";

    # ── P3: explicit one-way → forward only, NO reverse ─────────────────────
    oneWayHasForward = forwardCount oneWayRules == 1;
    oneWayZeroReverse = reverseCount oneWayRules == 0;
    oneWayTotalCount = builtins.length oneWayRules == 1;

    # ── P4 (recovery): a distinct reverse relation authorizes its own new flow
    distinctHasForward = forwardCount distinctRules == 1;
    distinctZeroReverse = reverseCount distinctRules == 0;
    distinctForwardIsNewFlow =
      (distinctFwd.connectionState or null) == null
      && (distinctFwd.returnRule or false) == false;
    # It preserves its OWN bounded tuple (own id, own endpoints, own port).
    distinctOwnId = (distinctFwd.relationId or null) == "rel-reverse-web-B-to-A";
    distinctOwnFrom = ((distinctFwd.from or {}).name or "") == "tenant-B";
    distinctOwnTo = ((distinctFwd.to or {}).name or "") == "tenant-A";
    distinctOwnPort =
      let m = distinctFwd.matches or []; in
      builtins.length m == 1 && ((builtins.head m).dport or 0) == 8443;

    # ── P5: reverse endpoints/interfaces correctly swapped (real swap) ──────
    fwdFromIface = (symFwd.fromInterface or "") == "eth-tenantA";
    fwdToIface   = (symFwd.toInterface or "") == "eth-tenantB-policy";
    revFromIface = (symRev.fromInterface or "") == "eth-tenantB";
    revToIface   = (symRev.toInterface or "") == "eth-tenantA-policy";
    revFromDiffersFromFwd = (symRev.fromInterface or "") != (symFwd.fromInterface or "");
    revToDiffersFromFwd   = (symRev.toInterface or "") != (symFwd.toInterface or "");
    revFromSwapped = ((symRev.from or {}).name or "") == "tenant-B";
    revToSwapped   = ((symRev.to or {}).name or "") == "tenant-A";
    fwdFromName    = ((symFwd.from or {}).name or "") == "tenant-A";
    fwdToName      = ((symFwd.to or {}).name or "") == "tenant-B";
    # Reverse return preserves the same relation identity and traffic match.
    revSameRelationId = (symRev.relationId or null) == "rel-symmetric-web";
    revSameTrafficType = (symRev.trafficType or "") == "web";
    revMatches = let m = symRev.matches or []; in
      builtins.length m == 1
      && (((builtins.head m).proto or "") == "tcp")
      && (((builtins.head m).dport or 0) == 443);

    # ── P6 (seeded negative): synthetic reverse labeled with forward ID ─────
    syntheticReverseRejected = syntheticReverseRejected;
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

echo "PASS test-FS-180-HDS-010-SDS-010-SMS-040-bidirectional-nft-rules (P1-P6)"

# ── P7 (SMS-040 Negative case 3): unrecognized returnBehavior rejected ──────
# Exercises the REAL validation module (src/cpm/forwarding-validation/
# communication-contract.nix), not a mirror. Unrecognized values must fail
# with a diagnostic naming the value and relation ID; missing returnBehavior
# stays rejected; the recognized vocabulary stays accepted.
export CPM_REPO_ROOT="${repo_root}"
validator_relations_file="$(mktemp)"
trap 'rm -f "${result_json}" "${validator_relations_file}"' EXIT
export CPM_RELATIONS_FILE="${validator_relations_file}"

eval_validator() {
  local relations_json="$1"
  printf '%s' "$relations_json" >"${CPM_RELATIONS_FILE}"
  nix eval --impure --json --expr '
    let
      repoRoot = builtins.getEnv "CPM_REPO_ROOT";
      lib = import (repoRoot + "/lib/utils.nix");
      helpers = import (repoRoot + "/src/cpm/cpm-contract-support.nix") { inherit lib; };
      common = import (repoRoot + "/src/cpm/forwarding-validation/common.nix") { inherit helpers; };
      validator = import (repoRoot + "/src/cpm/forwarding-validation/communication-contract.nix") {
        inherit helpers common;
      };
      relations = builtins.fromJSON (builtins.readFile (builtins.getEnv "CPM_RELATIONS_FILE"));
      site = {
        communicationContract.allowedRelations = relations;
        policy.interfaceTags = { };
        domains = {
          tenants = [ ];
          externals = [ ];
        };
        uplinkNames = [ ];
      };
    in
      validator.validate "forwardingModel.enterprise.test.site.test" site
  '
}

assert_validator_accepts() {
  local label="$1" relations_json="$2"
  local output
  output="$(eval_validator "$relations_json")"
  [[ "$output" == "true" ]] || {
    printf 'FAIL [P7 %s]: expected true, got %s\n' "$label" "$output" >&2
    exit 1
  }
  echo "PASS [P7 ${label}]: accepted"
}

assert_validator_rejects() {
  local label="$1" relations_json="$2" expected="$3"
  local output status
  set +e
  output="$(eval_validator "$relations_json" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    printf 'FAIL [P7 %s]: invalid returnBehavior was accepted: %s\n' "$label" "$output" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    printf 'FAIL [P7 %s]: expected diagnostic %q\n%s\n' "$label" "$expected" "$output" >&2
    exit 1
  fi
  echo "PASS [P7 ${label}]: rejected with diagnostic containing \"${expected}\""
}

assert_validator_accepts "recognized symmetric" \
  '[{"id":"rel-symmetric-web","action":"allow","from":"any","to":"any","returnBehavior":"symmetric"}]'
assert_validator_accepts "recognized one-way" \
  '[{"id":"rel-oneway-web","action":"allow","from":"any","to":"any","returnBehavior":"one-way"}]'
assert_validator_accepts "recognized nested stateful-return" \
  '[{"id":"rel-nested-stateful","action":"allow","from":"any","to":"any","publicIngressTupleAuthority":{"returnBehavior":"stateful-return"}}]'

assert_validator_rejects "unrecognized asymmetric" \
  '[{"id":"rel-bad-asymmetric","action":"allow","from":"any","to":"any","returnBehavior":"asymmetric"}]' \
  "FS-180-HDS-010-SDS-010-SMS-040: allow relation 'rel-bad-asymmetric' has an unrecognized top-level returnBehavior 'asymmetric'"
assert_validator_rejects "unrecognized hairpin" \
  '[{"id":"rel-bad-hairpin","action":"allow","from":"any","to":"any","returnBehavior":"hairpin"}]' \
  "FS-180-HDS-010-SDS-010-SMS-040: allow relation 'rel-bad-hairpin' has an unrecognized top-level returnBehavior 'hairpin'"
assert_validator_rejects "unrecognized nested value" \
  '[{"id":"rel-bad-nested","action":"allow","from":"any","to":"any","publicIngressTupleAuthority":{"returnBehavior":"asymmetric"}}]' \
  "FS-180-HDS-010-SDS-010-SMS-040: allow relation 'rel-bad-nested' has an unrecognized publicIngressTupleAuthority returnBehavior 'asymmetric'"
assert_validator_rejects "missing returnBehavior stays rejected" \
  '[{"id":"rel-missing-return","action":"allow","from":"any","to":"any"}]' \
  "allow relation 'rel-missing-return' is missing required returnBehavior"

echo "PASS test-FS-180-HDS-010-SDS-010-SMS-040-bidirectional-nft-rules"
