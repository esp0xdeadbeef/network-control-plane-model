#!/usr/bin/env bash
# GAMP-ID: FS-270-HDS-010-SDS-010-SMS-040
# GAMP-ID: FS-310-HDS-010-SDS-010-SMS-030
# GAMP-ID: FS-320-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
#
# Selector handoff transport forwarding boundary. Topology provenance
# (relationId, comment, topology scopes, non-bypass labels) proves origin but
# never authorizes a packet accept. Every selector forwarding rule must carry
# a transportAuthority record DISTINCT from provenance, with one of:
#   stateful-return | enforceable-matches | dedicated-link-isolation |
#   modeled-relation, or an explicit admissible=false unproven record whose
#   diagnostic names the unlabeled forwarding surfaces.
#
# Fixture predicates (against the REAL src/cpm/firewall-intent/rules/common.nix):
#   P1: dedicated modeled p2p pair (both ends fabric-link ids, non-external,
#       non-host-facing) -> forward accept carries transportAuthority with
#       basis=dedicated-link-isolation, provenanceIsAuthority=false, and
#       per-end isolation proofs binding stable isolation keys, while the
#       relationId/comment provenance labels stay present and separate.
#   N3 (SMS Negative case 3, labeled-overbroad): a trafficType=any pair whose
#       ends carry only label-shaped provenance (link kind without a modeled
#       link id) keeps its relationId, comment, scopes and nonBypass label but
#       its authority is admissible=false / basis=unproven with
#       diagnostic=selector-unlabeled-broad-forwarding naming both surfaces.
#       Labels alone never authorize.
#   N4 (SMS Negative case 4, unsafe reverse): the reverse leg of a selector
#       pair is a STATEFUL RETURN: connectionState=established,related,
#       returnRule=true, authority basis=stateful-return. No state-unqualified
#       reverse new-flow accept is synthesized from the forward pair.
#   N-ext: an external surface can never prove isolated transport
#       (reason=external-surface-not-selector-transport).
#   N-hf (incomplete isolation): a host-facing surface can never prove
#       isolated transport (reason=host-facing-surface-not-isolated-transport).
#   R1 (recovery via enforceable matches): the N3 pair recovers admissibility
#       through modeled packet matches (trafficType class or source-prefix
#       scope) -> basis=enforceable-matches.
#   R2 (recovery via complete isolation): the N3 pair recovers through
#       complete dedicated-link isolation (modeled link ids, non-external,
#       non-host-facing) -> basis=dedicated-link-isolation.
#
# Integrated predicates (pinned HAT lab, NixOS + CLAB inventories):
#   - every selector rule carries provenance identity (relationId, comment,
#     direction, scopes, candidate egress, policy-point traversal,
#     cardinality) AND a transportAuthority record with
#     provenanceIsAuthority=false;
#   - admissible=false authority is only the explicit unproven record with a
#     diagnostic naming the unlabeled surfaces;
#   - every reverse-direction selector rule is a stateful established,related
#     return;
#   - seeded negatives: missing-relation, missing-source-scope,
#     bad-cardinality, missing-candidate-egress, missing-authority,
#     labels-only-authority, unsafe-reverse are all rejected, then the
#     unmodified outputs are re-accepted.
#
# Post-DNAT selector route/forward continuity (SMS Construction Handoff item 8
# / Negative case 5), against the REAL selector construction output plus
# src/cpm/firewall-intent/rules/post-dnat-continuity.nix:
#   CONT-P: the REAL selectorPairRule dedicated forward accept, placed as the
#           upstream-selector's tuple-forwarding rule with an exact /32 target
#           route and a next hop that is the following (policy) hop, carries
#           the SAME translated udp/4242 tuple continuously through
#           translation-owner -> upstream-selector -> policy; the selector hop
#           authorizes the tuple via its dedicated-link-isolation transport
#           authority (provenance labels alone never authorize).
#   CONT-N5-route: removing the upstream-selector's target route breaks
#           continuity at exactly upstream-selector (missing-target-route)
#           while the translation owner stays independently OK.
#   CONT-N5-tuple: removing the upstream-selector's tuple-owned forward rule
#           breaks continuity at exactly upstream-selector
#           (route-without-tuple-allow) even though the route is present.
#   CONT-N5-reverse: the selector's stateful established,related return leg
#           does NOT authorize the forward tuple (non-recovery).
#   CONT-N5g: an incomplete translated tuple is rejected fail-closed
#           (post-dnat-tuple-incomplete), never broadly accepted.
#
# REMAINING GAP (row stays NOT OK until proven): the seeded module-level
# continuity predicate above proves the boundary against constructed
# translated-tuple hop chains, but the INTEGRATED pinned-lab predicate — a
# REAL translated public-ingress tuple flowing through the compiled site
# pipeline and materializing route + tuple-scoped forward authority at each
# selector handoff — still requires CPM to consume a public-ingress tuple
# authority in the site pipeline (evaluatePostDnatContinuity has no site-
# pipeline consumer yet; see FS-310-HDS-020-SDS-010-SMS-075). That integrated
# predicate cannot be constructed here until the SMS-075 chain recovers.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

hat_dir="$(pinned_hat_dir)"
intent_path="${hat_dir}/intent.nix"
nixos_output="${tmp_dir}/nixos-cpm.json"
clab_output="${tmp_dir}/clab-cpm.json"

# --- Fixture predicates against the real common.nix module -----------------

cat > "${tmp_dir}/module-fixture.nix" <<'EOF'
let
  repoRoot = builtins.getEnv "CPM_REPO_ROOT";
  common = import (repoRoot + "/src/cpm/firewall-intent/rules/common.nix") { };
  mkIface = args:
    {
      runtimeIfName = args.name;
      sourceKind = args.sourceKind or "p2p";
      hostFacing = args.hostFacing or false;
      backingRef = {
        kind = args.kind or "link";
        id = args.id or "";
        lane = args.lane or { kind = "transit"; };
      } // (args.refExtra or { });
    }
    // (args.ifaceExtra or { });

  dedicated0 = mkIface { name = "p0"; id = "link-access-selector"; };
  dedicated1 = mkIface { name = "p1"; id = "link-selector-policy"; };

  # Label-shaped provenance only: link kind without a modeled link id.
  labelOnly0 = mkIface { name = "p0"; id = ""; };
  labelOnly1 = mkIface { name = "p1"; id = ""; };

  externalIface = mkIface {
    name = "ppp0";
    kind = "pppoe-session";
    refExtra = { peerRuntimeTarget = "isp-peer"; };
    ifaceExtra = { external = true; };
  };
  hostFacingIface = mkIface {
    name = "ens3";
    id = "link-host-facing";
    hostFacing = true;
  };

  dedicatedPair = common.selectorPairRule dedicated0 dedicated1;
  overbroadPair = common.selectorPairRule labelOnly0 labelOnly1;
in
{
  p1Forward = builtins.head dedicatedPair;
  p1Reverse = builtins.elemAt dedicatedPair 1;
  n3Forward = builtins.head overbroadPair;
  nExternalProof = common.selectorIsolationProof externalIface;
  nHostFacingProof = common.selectorIsolationProof hostFacingIface;
  r1TrafficClass =
    (common.selectorRuntimeRuleAudit {
      relationId = "recovery-traffic-class";
      direction = "forward";
      fromIface = labelOnly0;
      toIface = labelOnly1;
      trafficType = "dns";
    }).transportAuthority;
  r1SourceScope =
    (common.selectorRuntimeRuleAudit {
      relationId = "recovery-source-scope";
      direction = "forward";
      fromIface = labelOnly0;
      toIface = labelOnly1;
      sourcePrefixes = [ { family = 4; prefix = "10.0.10.0/24"; } ];
    }).transportAuthority;
  r2Isolation =
    (common.selectorRuntimeRuleAudit {
      relationId = "recovery-complete-isolation";
      direction = "forward";
      fromIface = dedicated0;
      toIface = dedicated1;
    }).transportAuthority;
}
EOF

module_eval="${tmp_dir}/module-fixture.json"
CPM_REPO_ROOT="${repo_root}" nix eval \
  --json --impure \
  --extra-experimental-features 'nix-command flakes' \
  --file "${tmp_dir}/module-fixture.nix" > "${module_eval}"

assert_fixture() {
  local label="$1"
  local filter="$2"
  if jq -e "${filter}" "${module_eval}" >/dev/null; then
    echo "PASS FS-270-HDS-010-SDS-010-SMS-040 ${label}"
  else
    echo "FAIL FS-270-HDS-010-SDS-010-SMS-040 ${label}" >&2
    jq '.' "${module_eval}" >&2 || true
    exit 1
  fi
}

# P1: authority distinct from provenance on a dedicated modeled pair.
assert_fixture "P1 dedicated-link isolation authority" '
  .p1Forward
  | (.relationId | startswith("selector-handoff-forward"))
    and (.comment == .relationId)
    and (.policyPointTraversal.nonBypass == true)
    and (.transportAuthority.basis == "dedicated-link-isolation")
    and (.transportAuthority.provenanceIsAuthority == false)
    and (.transportAuthority.admissible == true)
    and (.transportAuthority.from.isolationKey == {kind: "fabric-link", id: "link-access-selector"})
    and (.transportAuthority.to.isolationKey == {kind: "fabric-link", id: "link-selector-policy"})
    and (.transportAuthority.from.dedicated == true)
    and (.transportAuthority.to.external == false)
'

# N4: reverse leg is a stateful return, never a reverse new-flow accept.
assert_fixture "N4 reverse leg is stateful established,related return" '
  .p1Reverse
  | (.direction == "reverse")
    and (.connectionState == "established,related")
    and (.returnRule == true)
    and (.transportAuthority.basis == "stateful-return")
    and (.transportAuthority.provenanceIsAuthority == false)
'

# N3: fully labeled trafficType=any pair without enforceable matches and
# without complete isolation is rejected as provenance-without-authority.
assert_fixture "N3 labeled-overbroad accept has no authority" '
  .n3Forward
  | ((.relationId | type) == "string" and (.relationId != ""))
    and (.comment == .relationId)
    and (.trafficType == "any")
    and (.policyPointTraversal.nonBypass == true)
    and ((.sourceScope | type) == "object")
    and ((.destinationScope | type) == "object")
    and (.transportAuthority.admissible == false)
    and (.transportAuthority.basis == "unproven")
    and (.transportAuthority.provenanceIsAuthority == false)
    and (.transportAuthority.diagnostic == "selector-unlabeled-broad-forwarding")
    and (.transportAuthority.surfaces == ["p0", "p1"])
    and (.transportAuthority.from.reason == "provenance-without-isolation-authority")
'

# N-ext / N-hf: external and host-facing surfaces never prove isolation.
assert_fixture "N-ext external surface denied isolated transport" '
  .nExternalProof
  | (.admissible == false) and (.reason == "external-surface-not-selector-transport")
'
assert_fixture "N-hf host-facing surface denied isolated transport" '
  .nHostFacingProof
  | (.admissible == false) and (.reason == "host-facing-surface-not-isolated-transport")
'

# R1/R2: recovery through enforceable matches or complete isolation —
# adding labels alone (N3 shape) did not recover; these do.
assert_fixture "R1 recovery via modeled traffic class" '
  .r1TrafficClass
  | (.basis == "enforceable-matches") and (.admissible == true)
    and (.matches.trafficType == "dns") and (.provenanceIsAuthority == false)
'
assert_fixture "R1 recovery via modeled source scope" '
  .r1SourceScope
  | (.basis == "enforceable-matches") and (.admissible == true)
    and (.matches.sourcePrefixCount == 1) and (.provenanceIsAuthority == false)
'
assert_fixture "R2 recovery via complete dedicated-link isolation" '
  .r2Isolation
  | (.basis == "dedicated-link-isolation") and (.admissible == true)
    and (.provenanceIsAuthority == false)
'

# --- Post-DNAT selector route/forward continuity (CH item 8 / Negative 5) ---
# Seeded translated-tuple hop chain consuming the REAL selectorPairRule
# output at the upstream-selector hop, evaluated by the REAL
# post-dnat-continuity module (production-shaped 2026-07-15 tuple:
# UDP to 192.168.3.10:4242 after DNAT on the translation owner).

cat > "${tmp_dir}/continuity-fixture.nix" <<'EOF'
let
  repoRoot = builtins.getEnv "CPM_REPO_ROOT";
  common = import (repoRoot + "/src/cpm/firewall-intent/rules/common.nix") { };
  ruleBuilders = import (repoRoot + "/src/cpm/firewall-intent/rules.nix") { };
  evaluate = ruleBuilders.evaluatePostDnatContinuity;

  mkIface = args: {
    runtimeIfName = args.name;
    sourceKind = args.sourceKind or "p2p";
    hostFacing = args.hostFacing or false;
    backingRef = {
      kind = args.kind or "link";
      id = args.id or "";
      lane = args.lane or { kind = "transit"; };
    };
  };

  # Dedicated modeled selector p2p ends (ingress from translation owner,
  # egress toward the policy hop) — the SMS-040 P1 shape.
  selIngress = mkIface { name = "p0"; id = "link-core-upstream-selector"; };
  selEgress = mkIface { name = "p1"; id = "link-selector-policy"; };

  # The REAL selector handoff rules emitted by the SMS-040 construction.
  selectorPair = common.selectorPairRule selIngress selEgress;
  selectorForward = builtins.head selectorPair;
  selectorReverse = builtins.elemAt selectorPair 1;

  tuple = {
    family = 4;
    protocol = "udp";
    dstAddress = "192.168.3.10";
    dstPort = 4242;
    translationOwner = "core";
  };

  # Translation owner: DNAT plus bounded udp/4242 forward and an exact
  # target route toward the upstream selector — kept valid in every case.
  coreHop = {
    name = "core";
    hopAddress = "10.0.0.1";
    selectedTable = "main";
    routes = [
      {
        dst = "192.168.3.10/32";
        table = "main";
        nextHop = "10.0.1.2";
      }
    ];
    rules = [
      {
        action = "accept";
        fromInterface = "ens3";
        toInterface = "p0";
        matches = [
          {
            proto = "udp";
            family = "any";
            dports = [ 4242 ];
          }
        ];
      }
    ];
  };

  selectorRoute = {
    dst = "192.168.3.10/32";
    table = "main";
    nextHop = "10.0.2.2";
  };

  selectorHop = {
    name = "upstream-selector";
    hopAddress = "10.0.1.2";
    selectedTable = "main";
    routes = [ selectorRoute ];
    rules = [ selectorForward ];
  };

  policyHop = {
    name = "policy";
    hopAddress = "10.0.2.2";
    targetFacing = true;
    selectedTable = "main";
    routes = [
      {
        dst = "192.168.3.0/24";
        table = "main";
        nextHop = null;
      }
    ];
    rules = [
      {
        action = "accept";
        fromInterface = "p1";
        toInterface = "br-tenant";
        matches = [
          {
            proto = "udp";
            family = "any";
            dports = [ 4242 ];
          }
        ];
      }
    ];
  };

  working = evaluate {
    inherit tuple;
    hops = [ coreHop selectorHop policyHop ];
  };

  selectorRouteMissing = evaluate {
    inherit tuple;
    hops = [ coreHop (selectorHop // { routes = [ ]; }) policyHop ];
  };

  selectorTupleMissing = evaluate {
    inherit tuple;
    hops = [ coreHop (selectorHop // { rules = [ ]; }) policyHop ];
  };

  reverseOnlyNonRecovery = evaluate {
    inherit tuple;
    hops = [ coreHop (selectorHop // { rules = [ selectorReverse ]; }) policyHop ];
  };

  incompleteTuple = evaluate {
    tuple = builtins.removeAttrs tuple [ "dstPort" ];
    hops = [ coreHop selectorHop policyHop ];
  };
in
{
  selectorForwardAuthority = selectorForward.transportAuthority;
  selectorReverseIsReturn =
    (selectorReverse.returnRule or false)
    && (selectorReverse.connectionState or "") == "established,related";
  inherit
    working
    selectorRouteMissing
    selectorTupleMissing
    reverseOnlyNonRecovery
    incompleteTuple
    ;
}
EOF

continuity_eval="${tmp_dir}/continuity-fixture.json"
CPM_REPO_ROOT="${repo_root}" nix eval \
  --json --impure \
  --extra-experimental-features 'nix-command flakes' \
  --file "${tmp_dir}/continuity-fixture.nix" > "${continuity_eval}"

assert_continuity() {
  local label="$1"
  local filter="$2"
  if jq -e "${filter}" "${continuity_eval}" >/dev/null; then
    echo "PASS FS-270-HDS-010-SDS-010-SMS-040 ${label}"
  else
    echo "FAIL FS-270-HDS-010-SDS-010-SMS-040 ${label}" >&2
    jq '.' "${continuity_eval}" >&2 || true
    exit 1
  fi
}

assert_continuity "CONT-P real selector forward rule carries isolation authority" '
  .selectorForwardAuthority
  | (.basis == "dedicated-link-isolation")
    and (.admissible == true)
    and (.provenanceIsAuthority == false)
'
assert_continuity "CONT-P translated tuple continuous through the selector handoff" '
  .working
  | (.continuous == true)
    and (.firstBrokenHop == null)
    and (.failClosed == false)
    and ((.hopRecords | length) == 3)
    and (.hopRecords | all(.[]; .ok == true))
'
assert_continuity "CONT-P selector hop emits exact route, next hop, and tuple authority" '
  .working.hopRecords[1]
  | (.hop == "upstream-selector")
    and (.targetRoute.dst == "192.168.3.10/32")
    and (.nextHop == "10.0.2.2")
    and (.tupleForwarding.satisfied == true)
    and (.tupleForwarding.basis == "isolated-transport-authority")
'
assert_continuity "CONT-N5-route missing selector route breaks at upstream-selector" '
  .selectorRouteMissing
  | (.continuous == false)
    and (.firstBrokenHop == "upstream-selector")
    and (.failClosed == true)
    and (.diagnostic.code == "post-dnat-continuity-broken")
    and ((.diagnostic.missing | index("missing-target-route")) != null)
    and (.hopRecords[0] | (.hop == "core") and (.ok == true))
'
assert_continuity "CONT-N5-tuple selector route without tuple allow breaks at upstream-selector" '
  .selectorTupleMissing
  | (.continuous == false)
    and (.firstBrokenHop == "upstream-selector")
    and ((.diagnostic.missing | index("route-without-tuple-allow")) != null)
    and (.hopRecords[1].preconditions.routeFound == true)
'
assert_continuity "CONT-N5-reverse stateful return leg never authorizes the forward tuple" '
  (.selectorReverseIsReturn == true)
  and (.reverseOnlyNonRecovery
       | (.continuous == false)
         and (.firstBrokenHop == "upstream-selector")
         and (.hopRecords[1].tupleForwarding.satisfied == false))
'
assert_continuity "CONT-N5g incomplete translated tuple rejected fail-closed" '
  .incompleteTuple
  | (.continuous == false)
    and (.failClosed == true)
    and (.diagnostic.code == "post-dnat-tuple-incomplete")
'

# --- Integrated predicates on the pinned HAT lab ---------------------------

build_cpm() {
  local inventory="$1"
  local output="$2"

  nix run \
    --no-write-lock-file \
    --extra-experimental-features 'nix-command flakes' \
    "${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory}" \
    "${output}" >/dev/null
}

validate_selector_rules() {
  local input="$1"

  jq -e '
    def selector_rule:
      ((.relationCardinality.unit // "") == "selector-forwarding-rule")
      or ((.relationId // "") | startswith("selector-handoff-"));

    def non_empty_string($v):
      ($v | type) == "string" and $v != "";

    def metadata_scope($scope):
      ($scope | type) == "object"
      and non_empty_string($scope.runtimeInterface // "")
      and (($scope.lane // null) | type) == "object"
      and (($scope.backingRef // null) | type) == "object"
      and non_empty_string($scope.backingRef.name // "")
      and ($scope | has("hostFacing"))
      and ($scope.hostFacing | type) == "boolean";

    def valid_cardinality($rule):
      (($rule.relationCardinality // null) | type) == "object"
      and $rule.relationCardinality.unit == "selector-forwarding-rule"
      and non_empty_string($rule.relationCardinality.decomposition // "")
      and ($rule.relationCardinality | has("decomposed"))
      and ($rule.relationCardinality.decomposed | type) == "boolean";

    def valid_authority($rule):
      (($rule.transportAuthority // null) | type) == "object"
      and ($rule.transportAuthority.provenanceIsAuthority == false)
      and (($rule.transportAuthority.admissible | type) == "boolean")
      and ((["stateful-return", "enforceable-matches", "dedicated-link-isolation", "modeled-relation", "unproven"] | index($rule.transportAuthority.basis)) != null)
      and (if $rule.transportAuthority.admissible == false then
             ($rule.transportAuthority.basis == "unproven")
             and ($rule.transportAuthority.diagnostic == "selector-unlabeled-broad-forwarding")
             and (($rule.transportAuthority.surfaces // []) | length > 0)
           else true end)
      and (if $rule.transportAuthority.basis == "enforceable-matches" then
             ((($rule.trafficType // "any") != "any")
              or ((($rule.sourcePrefixes // []) | length) > 0))
           else true end)
      and (if $rule.transportAuthority.basis == "stateful-return" then
             ($rule.connectionState == "established,related" and $rule.returnRule == true)
           else true end);

    def safe_reverse($rule):
      if (($rule.direction // "") | startswith("reverse")) then
        ($rule.connectionState == "established,related" and $rule.returnRule == true)
      else
        true
      end;

    [
      .control_plane_model.data
      | to_entries[] as $enterprise
      | $enterprise.value
      | to_entries[] as $site
      | $site.value.runtimeTargets
      | to_entries[] as $target
      | ($target.value.forwardingIntent.rules // [])[]
      | select(selector_rule)
      | . + {
          enterprise: $enterprise.key,
          site: $site.key,
          target: $target.key
        }
    ] as $rules
    | [
        $rules[]
        | select(
            ((.action // "") as $a | ($a != "accept" and $a != "deny"))
            or (non_empty_string(.relationId // "") | not)
            or ((.comment // null) != (.relationId // null))
            or (non_empty_string(.trafficType // "") | not)
            or (non_empty_string(.direction // "") | not)
            or (non_empty_string(.fromInterface // "") | not)
            or (non_empty_string(.toInterface // "") | not)
            or (metadata_scope(.sourceScope // null) | not)
            or (metadata_scope(.destinationScope // null) | not)
            or (metadata_scope(.candidateEgress // null) | not)
            or (((.policyPointTraversal // null) | type) != "object")
            or ((.policyPointTraversal.nonBypass // null) != true)
            or (non_empty_string(.policyPointTraversal.relationId // "") | not)
            or (valid_cardinality(.) | not)
            or (valid_authority(.) | not)
            or (safe_reverse(.) | not)
          )
      ] as $invalid
    | {
        trace: "FS-270-HDS-010-SDS-010-SMS-040",
        selectorRuleCount: ($rules | length),
        invalidCount: ($invalid | length),
        invalidSample: ($invalid[:3] | map({target, relationId, direction, connectionState, transportAuthority}))
      }
    | select(.selectorRuleCount > 0 and .invalidCount == 0)
  ' "${input}" >/dev/null
}

mutate_selector_rules() {
  local input="$1"
  local output="$2"
  local mutation="$3"

  jq --arg mutation "${mutation}" '
    def is_selector:
      ((.relationCardinality.unit // "") == "selector-forwarding-rule")
      or ((.relationId // "") | startswith("selector-handoff-"));

    if $mutation == "missing-relation" then
      (.. | objects | select(is_selector)) |= del(.relationId)
    elif $mutation == "missing-source-scope" then
      (.. | objects | select(is_selector)) |= del(.sourceScope)
    elif $mutation == "bad-cardinality" then
      (.. | objects | select(is_selector)) |= (.relationCardinality.unit = "broad-unlabeled-rule")
    elif $mutation == "missing-candidate-egress" then
      (.. | objects | select(is_selector)) |= del(.candidateEgress.backingRef.name)
    elif $mutation == "missing-authority" then
      (.. | objects | select(is_selector and has("transportAuthority"))) |= del(.transportAuthority)
    elif $mutation == "labels-only-authority" then
      (.. | objects | select(is_selector and has("transportAuthority"))) |=
        (.transportAuthority = {
          basis: "provenance-label",
          provenanceIsAuthority: true,
          admissible: true
        })
    elif $mutation == "unsafe-reverse" then
      (.. | objects
        | select(is_selector and ((.direction // "") | startswith("reverse"))))
        |= (del(.connectionState) | del(.returnRule))
    else
      .
    end
  ' "${input}" > "${output}"
}

assert_rejects() {
  local input="$1"
  local label="$2"

  if validate_selector_rules "${input}"; then
    echo "FAIL FS-270-HDS-010-SDS-010-SMS-040 ${label}: seeded violation was accepted" >&2
    exit 1
  fi
  echo "PASS FS-270-HDS-010-SDS-010-SMS-040 ${label}: seeded violation rejected"
}

build_cpm "${hat_dir}/inventory-nixos.nix" "${nixos_output}"
build_cpm "${hat_dir}/inventory-clab.nix" "${clab_output}"

validate_selector_rules "${nixos_output}"
validate_selector_rules "${clab_output}"

for output in "${nixos_output}" "${clab_output}"; do
  for mutation in \
    missing-relation \
    missing-source-scope \
    bad-cardinality \
    missing-candidate-egress \
    missing-authority \
    labels-only-authority \
    unsafe-reverse; do
    mutated="${tmp_dir}/$(basename "${output}").${mutation}.json"
    mutate_selector_rules "${output}" "${mutated}" "${mutation}"
    assert_rejects "${mutated}" "${mutation}"
  done

  validate_selector_rules "${output}"
done

echo "PASS selector-forwarding-relation-identity"
