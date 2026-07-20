#!/usr/bin/env bash
# GAMP-ID: FS-275-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
#
# Virtual adapter transit relation preservation. Relation identity, comments,
# scopes, and non-bypass labels are PROVENANCE; a packet accept additionally
# requires enforceable match authority, complete dedicated p2p
# isolation/non-bypass authority, or bounded stateful-return authority.
#
# Module predicates (against the REAL src/cpm/firewall-intent/rules/*.nix):
#   EXT-N (external-adapter, 2026-07-15 production shape): a virtual PPP
#       session whose owning WAN surface is external = true is DENIED
#       core-transit-mesh admission fail-closed
#       (reason = external-surface-not-core-transit) and generates NO
#       interface-pair accept — the unconstrained ens3<->ppp0
#       trafficType=any bypass class cannot be constructed.
#   EXT-R (recovery): the same modeled pppoe session without the external
#       marking (modeled peer runtime target) is admitted with
#       transportAuthority basis = dedicated-link-isolation,
#       provenanceIsAuthority = false, both ends external = false.
#   VI-P / VI-N5 (SMS Negative case 5, translated virtual-ingress handoff):
#       a DNAT-translated public-ingress tuple (udp/192.168.3.10:4242)
#       entering through a provider/session virtual adapter, with WORKING
#       translation-owner artifacts (bounded tuple forward + exact target
#       route + successful DNAT record), must prove route AND tuple-forward
#       continuity at the FIRST downstream selector:
#         VI-N5-route: removing the first selector's target route breaks
#             continuity at exactly first-selector (missing-target-route)
#             while the translation owner stays independently OK — a
#             successful DNAT counter is not recovery.
#         VI-N5-labels: replacing the first selector's tuple-owned rule with
#             a relation/adapter-labeled bare interface-pair accept
#             (trafficType=any, no matches, provenance-label authority)
#             breaks continuity (route-without-tuple-allow) — adapter labels
#             are not recovery.
#         VI-N5-reverse: the stateful established,related return leg never
#             authorizes the forward tuple.
#
# Integrated predicates (pinned HAT lab, NixOS + CLAB inventories): every
# policy/selector relation rule with a virtual adapter scope and every
# core-transit-mesh rule preserves relation identity AND carries a
# transportAuthority record distinct from provenance
# (provenanceIsAuthority=false; basis in stateful-return |
# enforceable-matches | dedicated-link-isolation | modeled-relation, or an
# explicit admissible=false unproven record with a named diagnostic);
# dedicated-link-isolation requires both ends dedicated and non-external;
# reverse-direction rules are stateful established,related returns.
#
# Seeded negatives (both inventories):
#   Negative 1: lost-transit-relation      (relation metadata stripped)
#   Negative 2: false-transit-claim        (host-local adapter claims transit)
#   Negative 3: labeled-interface-only     (labels kept, matches replaced by
#                                           trafficType=any + label authority)
#   Negative 4: unsafe-reverse             (reverse accept loses
#                                           established,related state match)
#   External:   external-transit-adapter   (dedicated-link isolation claimed
#                                           over an external surface)
# Recovery: the unmodified outputs are re-accepted after every negative.
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

# --- Module fixture A: external virtual session adapter admission ----------
# 2026-07-15 production doublecheck shape, evaluated against the REAL
# src/cpm/firewall-intent/rules/core.nix admission authority.

cat > "${tmp_dir}/external-adapter-fixture.nix" <<'EOF'
let
  repoRoot = builtins.getEnv "CPM_REPO_ROOT";
  ruleBuilders = import (repoRoot + "/src/cpm/firewall-intent/rules.nix") { };
  buildCoreRules = ruleBuilders.buildCoreRules;

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

  internalTransit = mkIface {
    name = "ens3";
    id = "link-core-upstream-selector";
  };

  # Production defect shape: virtual PPP session whose owning WAN surface is
  # explicitly external, wrongly offered to core-transit-mesh.
  externalPpp = mkIface {
    name = "ppp0";
    sourceKind = "provider-session";
    kind = "pppoe-session";
    refExtra = {
      id = "pppoe-session::core::ppp0";
      peerRuntimeTarget = "isp-bng";
    };
    ifaceExtra = { external = true; };
  };

  # Recovery shape: the same modeled session without the external marking
  # (dedicated in-lab session with a modeled peer runtime target).
  modeledPpp = mkIface {
    name = "ppp0";
    sourceKind = "provider-session";
    kind = "pppoe-session";
    refExtra = {
      id = "pppoe-session::core::ppp0";
      peerRuntimeTarget = "isp-bng";
    };
  };

  withExternal = buildCoreRules {
    transitInterfaces = [ internalTransit externalPpp ];
    uplinkInterfaces = [ ];
  };
  withModeled = buildCoreRules {
    transitInterfaces = [ internalTransit modeledPpp ];
    uplinkInterfaces = [ ];
  };

  touchesPpp = rule:
    (rule.fromInterface or "") == "ppp0" || (rule.toInterface or "") == "ppp0";
in
{
  external = {
    denied = withExternal.transitAdmission.denied;
    admittedSurfaces = map (proof: proof.surface) withExternal.transitAdmission.admitted;
    pppRuleCount = builtins.length (builtins.filter touchesPpp withExternal.rules);
    ruleCount = builtins.length withExternal.rules;
  };
  recovered = {
    deniedCount = builtins.length withModeled.transitAdmission.denied;
    pppRules = builtins.filter touchesPpp withModeled.rules;
  };
}
EOF

external_eval="${tmp_dir}/external-adapter-fixture.json"
CPM_REPO_ROOT="${repo_root}" nix eval \
  --json --impure \
  --extra-experimental-features 'nix-command flakes' \
  --file "${tmp_dir}/external-adapter-fixture.nix" > "${external_eval}"

assert_module() {
  local eval_file="$1"
  local label="$2"
  local filter="$3"
  if jq -e "${filter}" "${eval_file}" >/dev/null; then
    echo "PASS FS-275-HDS-010-SDS-010-SMS-010 ${label}"
  else
    echo "FAIL FS-275-HDS-010-SDS-010-SMS-010 ${label}" >&2
    jq '.' "${eval_file}" >&2 || true
    exit 1
  fi
}

assert_module "${external_eval}" "EXT-N external virtual session denied core transit fail-closed" '
  .external
  | ((.denied | length) == 1)
    and (.denied[0].surface == "ppp0")
    and (.denied[0].admissible == false)
    and (.denied[0].reason == "external-surface-not-core-transit")
    and (.denied[0].failClosed == true)
    and (.denied[0].diagnostic == "core-transit-admission-denied")
    and ((.admittedSurfaces | index("ppp0")) == null)
    and (.pppRuleCount == 0)
'
assert_module "${external_eval}" "EXT-R modeled non-external session recovers with isolation authority" '
  .recovered
  | (.deniedCount == 0)
    and ((.pppRules | length) == 2)
    and (.pppRules | all(.[];
        (.trafficType == "any")
        and ((.relationId // "") | startswith("core-transit-mesh--"))
        and (.comment == .relationId)
        and (.transportAuthority.basis == "dedicated-link-isolation")
        and (.transportAuthority.provenanceIsAuthority == false)
        and (.transportAuthority.from.external == false)
        and (.transportAuthority.to.external == false)
        and (.transportAuthority.from.dedicated == true)
        and (.transportAuthority.to.dedicated == true)
      ))
'

# --- Module fixture B: translated virtual-ingress handoff continuity -------
# SMS Negative case 5, evaluated with the REAL selectorPairRule output and
# the REAL post-dnat-continuity module (production-shaped 2026-07-15 tuple).

cat > "${tmp_dir}/virtual-ingress-fixture.nix" <<'EOF'
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

  selIngress = mkIface { name = "sel0"; id = "link-owner-first-selector"; };
  selEgress = mkIface { name = "sel1"; id = "link-selector-policy"; };

  selectorPair = common.selectorPairRule selIngress selEgress;
  selectorForward = builtins.head selectorPair;
  selectorReverse = builtins.elemAt selectorPair 1;

  tuple = {
    family = 4;
    protocol = "udp";
    dstAddress = "192.168.3.10";
    dstPort = 4242;
    translationOwner = "translation-owner";
  };

  # Translation owner: public ingress enters through the provider/session
  # virtual adapter (ppp0), is destination-translated, and keeps WORKING
  # owner artifacts in every case: successful DNAT record, bounded
  # translated-tuple forward, exact target route toward the first selector.
  ownerHop = {
    name = "translation-owner";
    hopAddress = "10.9.0.1";
    selectedTable = "main";
    ingressAdapter = {
      runtimeInterface = "ppp0";
      adapterClass = "provider-session";
      virtualAdapter = true;
      hostFacing = false;
    };
    dnat = {
      applied = true;
      counterPackets = 1;
      owner = "translation-owner";
    };
    routes = [
      {
        dst = "192.168.3.10/32";
        table = "main";
        nextHop = "10.9.1.2";
      }
    ];
    rules = [
      {
        action = "accept";
        fromInterface = "ppp0";
        toInterface = "sel0";
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
    nextHop = "10.9.2.2";
  };

  firstSelectorHop = {
    name = "first-selector";
    hopAddress = "10.9.1.2";
    selectedTable = "main";
    routes = [ selectorRoute ];
    rules = [ selectorForward ];
  };

  policyHop = {
    name = "policy";
    hopAddress = "10.9.2.2";
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
        fromInterface = "sel1";
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

  # Adapter/relation labels without tuple or isolation authority: a bare
  # interface-pair accept that keeps every provenance label.
  labelsOnlyRule = {
    action = "accept";
    fromInterface = "sel0";
    toInterface = "sel1";
    trafficType = "any";
    relationId = "selector-handoff-forward--labels-only";
    comment = "selector-handoff-forward--labels-only";
    policyPointTraversal = { nonBypass = true; };
    adapterLabels = {
      ingressAdapter = "ppp0";
      adapterClass = "provider-session";
      virtualAdapter = true;
    };
    transportAuthority = {
      basis = "provenance-label";
      provenanceIsAuthority = true;
      admissible = true;
    };
  };

  working = evaluate {
    inherit tuple;
    hops = [ ownerHop firstSelectorHop policyHop ];
  };

  routeLost = evaluate {
    inherit tuple;
    hops = [ ownerHop (firstSelectorHop // { routes = [ ]; }) policyHop ];
  };

  labelsOnly = evaluate {
    inherit tuple;
    hops = [ ownerHop (firstSelectorHop // { rules = [ labelsOnlyRule ]; }) policyHop ];
  };

  reverseOnly = evaluate {
    inherit tuple;
    hops = [ ownerHop (firstSelectorHop // { rules = [ selectorReverse ]; }) policyHop ];
  };
in
{
  selectorForwardAuthority = selectorForward.transportAuthority;
  selectorReverseIsReturn =
    (selectorReverse.returnRule or false)
    && (selectorReverse.connectionState or "") == "established,related";
  inherit
    working
    routeLost
    labelsOnly
    reverseOnly
    ;
}
EOF

ingress_eval="${tmp_dir}/virtual-ingress-fixture.json"
CPM_REPO_ROOT="${repo_root}" nix eval \
  --json --impure \
  --extra-experimental-features 'nix-command flakes' \
  --file "${tmp_dir}/virtual-ingress-fixture.nix" > "${ingress_eval}"

assert_module "${ingress_eval}" "VI-P translated virtual-ingress tuple continuous through first selector" '
  (.selectorForwardAuthority
   | (.basis == "dedicated-link-isolation") and (.admissible == true)
     and (.provenanceIsAuthority == false))
  and (.working
       | (.continuous == true)
         and (.firstBrokenHop == null)
         and (.failClosed == false)
         and ((.hopRecords | length) == 3)
         and (.hopRecords | all(.[]; .ok == true)))
'
assert_module "${ingress_eval}" "VI-N5-route lost selector target route rejected; DNAT owner not recovery" '
  .routeLost
  | (.continuous == false)
    and (.firstBrokenHop == "first-selector")
    and (.failClosed == true)
    and (.diagnostic.code == "post-dnat-continuity-broken")
    and ((.diagnostic.missing | index("missing-target-route")) != null)
    and (.hopRecords[0] | (.hop == "translation-owner") and (.ok == true))
'
assert_module "${ingress_eval}" "VI-N5-labels adapter/relation labels are not tuple authority" '
  .labelsOnly
  | (.continuous == false)
    and (.firstBrokenHop == "first-selector")
    and (.failClosed == true)
    and ((.diagnostic.missing | index("route-without-tuple-allow")) != null)
    and (.hopRecords[1].preconditions.routeFound == true)
    and (.hopRecords[1].tupleForwarding.satisfied == false)
    and (.hopRecords[0].ok == true)
'
assert_module "${ingress_eval}" "VI-N5-reverse stateful return leg never authorizes the forward tuple" '
  (.selectorReverseIsReturn == true)
  and (.reverseOnly
       | (.continuous == false)
         and (.firstBrokenHop == "first-selector")
         and (.hopRecords[1].tupleForwarding.satisfied == false))
'

# --- Integrated artifact predicates (pinned HAT lab) ------------------------

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

validate_transit_non_bypass() {
  local input="$1"
  local inventory_label="$2"
  local mode="${3:-verbose}"
  local summary="${tmp_dir}/$(basename "${input}").${inventory_label}.summary.json"

  jq --arg inventory "${inventory_label}" '
    def non_empty_string($v):
      ($v | type) == "string" and $v != "";

    def rules:
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[] as $target
        | ($target.value.forwardingIntent.rules // [])[]?
        | . + {
            site: $site.key,
            target: $target.key,
            role: ($target.value.role // "")
          }
      ];

    def interfaces:
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[] as $target
        | (($target.value.effectiveRuntimeRealization.interfaces // {}) | to_entries[]?)
        | .value + {
            site: $site.key,
            target: $target.key,
            logicalInterface: .key,
            role: ($target.value.role // "")
          }
      ];

    def admissions:
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[] as $target
        | ($target.value.forwardingIntent.transitAdmission // empty)
        | . + {
            site: $site.key,
            target: $target.key
          }
      ];

    def scope_common($scope):
      ($scope | type) == "object"
      and non_empty_string($scope.runtimeInterface // "")
      and (($scope.backingRef // null) | type) == "object"
      and non_empty_string($scope.backingRef.name // "")
      and ($scope | has("hostFacing"))
      and (($scope.hostFacing | type) == "boolean")
      and ($scope | has("virtualAdapter"))
      and (($scope.virtualAdapter | type) == "boolean");

    def virtual_transit_scope($scope):
      if $scope.virtualAdapter == true then
        $scope.hostFacing == false
        and non_empty_string($scope.adapterClass // "")
        and (($scope.sourceKind // "") != "host-local")
        and (($scope.relationPurpose // "") != "host-local")
        and (
          $scope.adapterClass == "selector-fabric-link"
          or $scope.adapterClass == "provider-session"
          or ($scope.adapterClass == "vpn" and ($scope.sourceKind // "") == "overlay")
        )
      else
        true
      end;

    def handoff_scopes_ok($rule):
      all([$rule.sourceScope, $rule.destinationScope, $rule.candidateEgress][];
        scope_common(.) and virtual_transit_scope(.)
      );

    def has_handoff($rule):
      non_empty_string($rule.relationId // "")
      and non_empty_string($rule.action // "")
      and non_empty_string($rule.trafficType // "")
      and non_empty_string($rule.direction // "")
      and non_empty_string($rule.fromInterface // "")
      and non_empty_string($rule.toInterface // "")
      and handoff_scopes_ok($rule)
      and (($rule.policyPointTraversal // null) | type) == "object"
      and ($rule.policyPointTraversal | has("nonBypass"))
      and $rule.policyPointTraversal.nonBypass == true
      and $rule.policyPointTraversal.relationId == $rule.relationId
      and $rule.policyPointTraversal.action == $rule.action
      and $rule.policyPointTraversal.sourceInterface == $rule.fromInterface
      and $rule.policyPointTraversal.destinationInterface == $rule.toInterface
      and $rule.sourceScope.runtimeInterface == $rule.fromInterface
      and $rule.destinationScope.runtimeInterface == $rule.toInterface
      and $rule.candidateEgress.runtimeInterface == $rule.toInterface;

    def has_virtual_scope($rule):
      (($rule.sourceScope.virtualAdapter? // false) == true)
      or (($rule.destinationScope.virtualAdapter? // false) == true)
      or (($rule.candidateEgress.virtualAdapter? // false) == true);

    # FS-275-HDS-010-SDS-010-SMS-010: relation identity is provenance;
    # a permissive rule additionally needs authority distinct from labels.
    def valid_authority($rule):
      (($rule.transportAuthority? // null) | type) == "object"
      and (($rule.transportAuthority.provenanceIsAuthority?) == false)
      and ((["stateful-return", "enforceable-matches", "dedicated-link-isolation", "modeled-relation", "unproven"]
            | index(($rule.transportAuthority.basis? // ""))) != null)
      and (if ($rule.transportAuthority.admissible?) == false then
             (($rule.transportAuthority.basis? // "") == "unproven")
             and non_empty_string($rule.transportAuthority.diagnostic? // "")
             and ((($rule.transportAuthority.surfaces? // []) | length) > 0)
           else true end)
      and (if ($rule.transportAuthority.basis? // "") == "enforceable-matches" then
             ((($rule.trafficType // "any") != "any")
              or ((($rule.sourcePrefixes // []) | length) > 0))
           else true end)
      and (if ($rule.transportAuthority.basis? // "") == "stateful-return" then
             ((($rule.connectionState? // "") == "established,related")
              and (($rule.returnRule?) == true))
           else true end)
      and (if ($rule.transportAuthority.basis? // "") == "dedicated-link-isolation" then
             ((($rule.transportAuthority.from.external?) == false)
              and (($rule.transportAuthority.to.external?) == false)
              and (($rule.transportAuthority.from.dedicated?) == true)
              and (($rule.transportAuthority.to.dedicated?) == true))
           else true end);

    def safe_reverse($rule):
      if (($rule.direction // "") | startswith("reverse")) then
        ((($rule.connectionState? // "") == "established,related")
         and (($rule.returnRule?) == true))
      else
        true
      end;

    def source_key:
      [ (.sourcePrefixes // [])[]? | { family: (.family // null), prefix: (.prefix // "") } ]
      | sort_by(.family // 0, .prefix);

    rules as $rules
    | interfaces as $interfaces
    | admissions as $admissions
    | ($rules | map(select(.role == "policy"))) as $policyRules
    | ($rules | map(select((.relationId // "") | startswith("selector-handoff-")))) as $allSelectorHandoffs
    | ($allSelectorHandoffs | map(select(.role == "downstream-selector" or .role == "upstream-selector"))) as $selectorHandoffs
    | ($policyRules + $allSelectorHandoffs) as $relationRules
    | ($rules | map(select((.relationId // "") | startswith("core-transit-mesh--")))) as $meshRules
    | (($relationRules + $meshRules) | map(select(has_virtual_scope(.)))) as $virtualScopeRules
    | ($virtualScopeRules | map(select((valid_authority(.) and safe_reverse(.)) | not))) as $badVirtualAuthority
    | ($meshRules
       | map(select((valid_authority(.)
                     and ((.transportAuthority.basis? // "") == "dedicated-link-isolation")) | not))) as $badMeshRules
    | ([$admissions[] | (.admitted // [])[]
        | select(((.admissible == true)
                  and (.external == false)
                  and (.dedicated == true)
                  and ((.modeledPeer | type) == "object")) | not)]) as $badAdmitted
    | ([$admissions[] | (.denied // [])[]
        | select(((.admissible == false)
                  and (.failClosed == true)
                  and non_empty_string(.reason // "")) | not)]) as $badDenied
    | ($policyRules | map(select(.relationId == "allow-provider-handoff-a-to-isp-a" or .relationId == "allow-provider-handoff-b-to-isp-a"))) as $providerPolicy
    | ($policyRules | map(select(.relationId == "allow-iot-underlay-to-nebula-egress"))) as $nebulaPolicy
    | ($policyRules | map(select(.relationId == "allow-iot-underlay-to-wireguard-egress"))) as $wireguardPolicy
    | ($policyRules | map(select(.relationId == "allow-hat-site-dns-service-to-client-uplinks"))) as $dnsAllows
    | ($policyRules | map(select(.relationId == "deny-client-dns-to-uplinks"))) as $dnsDenies
    | ($providerPolicy | map(select(has_handoff(.) | not))) as $badProviderPolicy
    | ($nebulaPolicy | map(select(has_handoff(.) | not))) as $badNebulaPolicy
    | ($wireguardPolicy | map(select(has_handoff(.) | not))) as $badWireguardPolicy
    | ($dnsAllows | map(select((has_handoff(.) and .action == "accept" and .trafficType == "dns" and ((.sourcePrefixes // []) | length > 0)) | not))) as $badDnsAllows
    | ($dnsDenies | map(select((has_handoff(.) and .action == "deny" and .trafficType == "dns" and ((.sourcePrefixes // []) == [])) | not))) as $badDnsDenies
    | ([
        $dnsAllows[] as $allow
        | $dnsDenies[] as $deny
        | select(
            $allow.fromInterface == $deny.fromInterface
            and $allow.toInterface == $deny.toInterface
            and $allow.trafficType == $deny.trafficType
            and (($allow.matches // []) == ($deny.matches // []))
            and (($allow | source_key) == ($deny | source_key))
          )
      ]) as $dnsCollapsed
    | {
        trace: "FS-275-HDS-010-SDS-010-SMS-010",
        inventory: $inventory,
        policyRuleCount: ($policyRules | length),
        allSelectorHandoffCount: ($allSelectorHandoffs | length),
        selectorHandoffCount: ($selectorHandoffs | length),
        meshRuleCount: ($meshRules | length),
        virtualScopeRuleCount: ($virtualScopeRules | length),
        badVirtualAuthorityCount: ($badVirtualAuthority | length),
        badVirtualAuthoritySample: ($badVirtualAuthority[:3] | map({target, relationId, direction, connectionState, transportAuthority})),
        badMeshRuleCount: ($badMeshRules | length),
        admissionTargetCount: ($admissions | length),
        badAdmittedCount: ($badAdmitted | length),
        badDeniedCount: ($badDenied | length),
        providerSessionVirtualAdapters: ($interfaces | map(select(.adapterClass == "provider-session" and .virtualAdapter == true and .hostFacing == false)) | length),
        selectorFabricVirtualAdapters: ($interfaces | map(select(.adapterClass == "selector-fabric-link" and .virtualAdapter == true and .hostFacing == false)) | length),
        overlayVpnAdapters: ($interfaces | map(select(.sourceKind == "overlay" and .adapterClass == "vpn" and .virtualAdapter == true and .hostFacing == false)) | length),
        virtualTransitSurfaceCount: ($interfaces | map(select(.virtualAdapter == true and .hostFacing == false and (.adapterClass == "selector-fabric-link" or .adapterClass == "provider-session" or (.sourceKind == "overlay" and .adapterClass == "vpn")))) | length),
        relationRulesMissingHandoff: ($relationRules | map(select(has_handoff(.) | not)) | length),
        invalidRelationSample: ($relationRules | map(select(has_handoff(.) | not))[:3] | map({target, role, relationId, sourceScope, destinationScope, candidateEgress, policyPointTraversal})),
        providerPolicyCount: ($providerPolicy | length),
        badProviderPolicyCount: ($badProviderPolicy | length),
        nebulaPolicyCount: ($nebulaPolicy | length),
        badNebulaPolicyCount: ($badNebulaPolicy | length),
        wireguardPolicyCount: ($wireguardPolicy | length),
        badWireguardPolicyCount: ($badWireguardPolicy | length),
        dnsAllowCount: ($dnsAllows | length),
        badDnsAllowCount: ($badDnsAllows | length),
        dnsDenyCount: ($dnsDenies | length),
        badDnsDenyCount: ($badDnsDenies | length),
        dnsCollapsedCount: ($dnsCollapsed | length),
        ok:
          ($policyRules | length > 0)
          and ($allSelectorHandoffs | length > 0)
          and ($selectorHandoffs | length > 0)
          and (($interfaces | map(select(.adapterClass == "selector-fabric-link" and .virtualAdapter == true and .hostFacing == false)) | length) > 0)
          and (($interfaces | map(select(.sourceKind == "overlay" and .adapterClass == "vpn" and .virtualAdapter == true and .hostFacing == false)) | length) > 0)
          and (($interfaces | map(select(.virtualAdapter == true and .hostFacing == false and (.adapterClass == "selector-fabric-link" or .adapterClass == "provider-session" or (.sourceKind == "overlay" and .adapterClass == "vpn")))) | length) > 0)
          and all($relationRules[]; has_handoff(.))
          and all($selectorHandoffs[]; has_handoff(.))
          and ($virtualScopeRules | length > 0)
          and (($badVirtualAuthority | length) == 0)
          and (($badMeshRules | length) == 0)
          and (($badAdmitted | length) == 0)
          and (($badDenied | length) == 0)
          and ($providerPolicy | length > 0)
          and all($providerPolicy[]; has_handoff(.))
          and ($nebulaPolicy | length > 0)
          and all($nebulaPolicy[]; has_handoff(.))
          and ($wireguardPolicy | length > 0)
          and all($wireguardPolicy[]; has_handoff(.))
          and ($dnsAllows | length > 0)
          and ($dnsDenies | length > 0)
          and all($dnsAllows[];
            has_handoff(.)
            and .action == "accept"
            and .trafficType == "dns"
            and ((.sourcePrefixes // []) | length > 0)
          )
          and all($dnsDenies[];
            has_handoff(.)
            and .action == "deny"
            and .trafficType == "dns"
            and ((.sourcePrefixes // []) == [])
          )
          and (($dnsCollapsed | length) == 0)
      }
  ' "${input}" > "${summary}"

  if jq -e '.ok == true' "${summary}" >/dev/null; then
    return 0
  fi

  if [[ "${mode}" != "quiet" ]]; then
    echo "FAIL FS-275-HDS-010-SDS-010-SMS-010 ${inventory_label}: virtual adapter transit relation preservation contract was not met" >&2
    jq . "${summary}" >&2
  fi
  return 1
}

mutate_transit_contract() {
  local input="$1"
  local output="$2"
  local mutation="$3"

  jq --arg mutation "${mutation}" '
    def relation_rule:
      (.role == "policy")
      or ((.relationId // "") | startswith("selector-handoff-"));

    def has_virtual_scope:
      ((.sourceScope.virtualAdapter? // false) == true)
      or ((.destinationScope.virtualAdapter? // false) == true)
      or ((.candidateEgress.virtualAdapter? // false) == true);

    if $mutation == "lost-transit-relation" then
      (.. | objects | select(relation_rule and has_virtual_scope)) |= del(.policyPointTraversal)
    elif $mutation == "false-transit-claim" then
      (.. | objects | select(relation_rule and has_virtual_scope) | .sourceScope) |= (
        .adapterClass = "host-local-virtual"
        | .sourceKind = "host-local"
        | .relationPurpose = "host-local"
        | .virtualAdapter = true
        | .hostFacing = false
      )
    elif $mutation == "labeled-interface-only" then
      # SMS Negative case 3: keep relation ID, comment, scopes, and the
      # non-bypass label, but replace enforceable matches with
      # trafficType=any and a label-shaped authority record.
      (.. | objects
        | select(relation_rule and has_virtual_scope
                 and ((.direction? // "") | startswith("reverse") | not)
                 and has("transportAuthority")))
        |= (.trafficType = "any"
            | del(.matches)
            | del(.sourcePrefixes)
            | .transportAuthority = {
                basis: "provenance-label",
                provenanceIsAuthority: true,
                admissible: true
              })
    elif $mutation == "unsafe-reverse" then
      # SMS Negative case 4: the reverse leg becomes a symmetric new-flow
      # accept without connection-state matching and without a distinct
      # modeled reverse relation.
      (.. | objects
        | select(relation_rule and has_virtual_scope
                 and ((.direction? // "") | startswith("reverse"))))
        |= (del(.connectionState) | del(.returnRule))
    elif $mutation == "external-transit-adapter" then
      # 2026-07-15 production class: dedicated-link isolation claimed over a
      # surface whose owning WAN is external.
      (.. | objects
        | select((.transportAuthority.basis? // "") == "dedicated-link-isolation")
        | .transportAuthority.from)
        |= (.external = true)
    else
      .
    end
  ' "${input}" > "${output}"
}

assert_rejects() {
  local input="$1"
  local inventory="$2"
  local label="$3"

  if validate_transit_non_bypass "${input}" "${inventory}-${label}" quiet; then
    echo "FAIL FS-275-HDS-010-SDS-010-SMS-010 ${inventory} ${label}: seeded violation was accepted" >&2
    exit 1
  fi
  echo "PASS FS-275-HDS-010-SDS-010-SMS-010 ${inventory} ${label}: seeded violation rejected"
}

build_cpm "${hat_dir}/inventory-nixos.nix" "${nixos_output}"
build_cpm "${hat_dir}/inventory-clab.nix" "${clab_output}"

for case in "nixos:${nixos_output}" "clab:${clab_output}"; do
  inventory="${case%%:*}"
  output="${case#*:}"

  validate_transit_non_bypass "${output}" "${inventory}"

  for mutation in \
    lost-transit-relation \
    false-transit-claim \
    labeled-interface-only \
    unsafe-reverse \
    external-transit-adapter; do
    mutated="${tmp_dir}/${inventory}.${mutation}.json"
    mutate_transit_contract "${output}" "${mutated}" "${mutation}"
    assert_rejects "${mutated}" "${inventory}" "${mutation}"
  done

  validate_transit_non_bypass "${output}" "${inventory}"
done

echo "PASS fs275-virtual-adapter-transit-non-bypass"
