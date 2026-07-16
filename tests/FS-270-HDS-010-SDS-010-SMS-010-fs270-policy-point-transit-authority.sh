#!/usr/bin/env bash
# GAMP-ID: FS-270-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
# RaTM: Construction test for policy-point transit authority in the CPM
# core-transit construction path (src/cpm/firewall-intent/rules/core.nix).
#
# Topology provenance (relation IDs, comments, non-bypass labels) proves
# origin but never authorizes packets. Interface-pair transport without
# enforceable packet matches is admissible only with a complete
# dedicated-link isolation proof, and an inventory surface marked
# external = true shall never be admitted to core-transit-mesh or generate
# a bare public-to-internal interface accept.
#
# Predicates (against the REAL src/cpm/firewall-intent/rules/core.nix):
#   P1: dedicated modeled transit pair (fabric link + pppoe session with a
#       modeled peer runtime target) → mesh accepts carry a
#       transportAuthority policy record with basis=dedicated-link-isolation,
#       provenanceIsAuthority=false, and complete per-endpoint isolation
#       proofs (dedicated=true, external=false, modeledPeer named) —
#       distinct from the relationId/comment provenance labels.
#   SN1 (SMS Negative case 3 / external admission, gap record 2026-07-15):
#       a pppoe session surface marked wan.external=true — with otherwise
#       plausible labels and even a modeled-looking peer — is DENIED
#       core-transit admission: no emitted rule (mesh or exit) touches the
#       surface in either direction (no bare public-to-internal accept),
#       and transitAdmission.denied names the surface with
#       reason=external-surface-not-core-transit and failClosed=true.
#   SN2 (SMS Negative case 3, provenance without authority): a transit
#       record whose backingRef provides only label-shaped provenance (no
#       modeled fabric-link id, no modeled session peer) is DENIED with
#       reason=provenance-without-isolation-authority; no accept is emitted
#       for it even though a relation ID and comment would be generated.
#   SN3 (SMS Negative case 4, unsafe reverse): the core module's
#       delegated-overlay return leg is a STATEFUL RETURN — it carries
#       connectionState=established,related and returnRule=true and is not
#       a state-unqualified reverse new-flow accept. The forward delegated
#       rules preserve their enforceable source-prefix matches.
#   R1 (recovery): clearing the external mark on the same surface restores
#       the dedicated modeled admission (P1 fixture is the recovery shape).
#
# Post-DNAT hop continuity (SMS Negative case 5 / Construction Handoff item 7,
# against the REAL src/cpm/firewall-intent/rules/post-dnat-continuity.nix):
#   P2: a working translation owner (DNAT + bounded udp/4242 forward), an
#       upstream-selector hop, and a target-facing policy hop each prove an
#       exact target route, selected main/policy table, next hop, and tuple
#       forwarding precondition for the SAME translated payload tuple —
#       continuous, no broken hop.
#   N5a missing route at upstream-selector      → first broken hop is
#       upstream-selector with missing-target-route; the translation owner
#       stays independently OK.
#   N5b wrong policy table at upstream-selector → wrong-policy-table at
#       exactly that hop (route present in the unauthorized table).
#   N5c wrong next hop at upstream-selector     → wrong-next-hop at exactly
#       that hop.
#   N5d route without tuple allow               → route-without-tuple-allow
#       at exactly that hop.
#   N5e NON-RECOVERY: a generic interface-pair accept (trafficType=any,
#       relation/comment/non-bypass labels, no matches, no isolation
#       authority) does NOT recover the broken hop.
#   N5f NON-RECOVERY: a stateful established,related return rule never
#       authorizes the forward tuple.
#   R3 recovery: enforceable udp/4242 matches (P2 shape) or complete
#       isolated transport authority both restore continuity.
#   N5g fail-closed tuple: an incomplete translated tuple (no dstPort) is
#       rejected (post-dnat-tuple-incomplete), never broadly accepted.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

command -v jq >/dev/null 2>&1 || { echo "missing required command: jq" >&2; exit 1; }
command -v nix >/dev/null 2>&1 || { echo "missing required command: nix" >&2; exit 1; }

result_json="$(mktemp)"
trap 'rm -f "${result_json}"' EXIT

REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    common = import (repoRoot + "/src/cpm/firewall-intent/rules/common.nix") { };
    buildCoreRules = import (repoRoot + "/src/cpm/firewall-intent/rules/core.nix") { inherit common; };

    # --- fixtures -------------------------------------------------------
    p2pIface = {
      runtimeIfName = "ens21";
      sourceKind = "p2p";
      backingRef = {
        kind = "link";
        id = "link::esp.site-a::p2p-core-upstream-selector";
        name = "p2p-core-upstream-selector";
      };
    };

    modeledSessionIface = {
      runtimeIfName = "ppp0";
      sourceKind = "pppoe-session";
      virtualAdapter = true;
      backingRef = {
        kind = "pppoe-session";
        id = "pppoe-session::core::ppp0";
        name = "pppoe-a";
        peerRuntimeTarget = "esp-site-a-provider-handoff-access-a";
      };
    };

    # SN1: same session surface, but the inventory marks the carrying WAN
    # surface external = true. Labels stay plausible on purpose: the modeled
    # peer, relation IDs, and comments must NOT outrank the external mark.
    externalSessionIface = modeledSessionIface // {
      wan = { external = true; };
    };

    # SN2: provenance-shaped record without isolation authority — a
    # relation label can be generated for it, but no modeled fabric link id
    # and no modeled session peer exists.
    provenanceOnlyIface = {
      runtimeIfName = "gre9";
      sourceKind = "p2p";
      backingRef = {
        kind = "link";
        id = "";
        name = "labeled-but-unmodeled";
      };
    };

    wanUplink = {
      runtimeIfName = "ens80";
      sourceKind = "wan";
      backingRef = {
        kind = "link";
        id = "uplink::esp.site-a::wan";
        name = "wan";
      };
    };

    overlayUplink = {
      runtimeIfName = "nebula1";
      sourceKind = "overlay";
      backingRef = {
        kind = "overlay";
        id = "overlay::esp.site-a::nebula-egress";
        name = "nebula-egress";
      };
      routes = {
        ipv4 = [
          {
            dst = "0.0.0.0/0";
            policyOnly = true;
            intent = {
              kind = "delegated-public-egress";
              exitNode = "exit-1";
            };
          }
        ];
        ipv6 = [ ];
      };
    };

    tenantPrefixOwners = {
      "4|10.20.20.0/24" = {
        owner = "exit-1";
        dst = "10.20.20.0/24";
      };
    };

    build = args: buildCoreRules ({ tenantPrefixOwners = { }; } // args);

    baseline = build {
      transitInterfaces = [ p2pIface modeledSessionIface ];
      uplinkInterfaces = [ wanUplink ];
    };

    externalCase = build {
      transitInterfaces = [ p2pIface externalSessionIface ];
      uplinkInterfaces = [ wanUplink ];
    };

    provenanceCase = build {
      transitInterfaces = [ p2pIface provenanceOnlyIface ];
      uplinkInterfaces = [ wanUplink ];
    };

    reverseCase = buildCoreRules {
      inherit tenantPrefixOwners;
      transitInterfaces = [ p2pIface ];
      uplinkInterfaces = [ overlayUplink ];
    };

    meshOf = result: builtins.filter (rule: (rule.direction or "") == "core-transit-mesh") result.rules;
    touching = ifName: result:
      builtins.filter
        (rule: (rule.fromInterface or "") == ifName || (rule.toInterface or "") == ifName)
        result.rules;
  in
  {
    baseline = {
      mesh = meshOf baseline;
      denied = baseline.transitAdmission.denied;
      admittedCount = builtins.length baseline.transitAdmission.admitted;
    };
    externalCase = {
      mesh = meshOf externalCase;
      ppp0Rules = touching "ppp0" externalCase;
      denied = externalCase.transitAdmission.denied;
    };
    provenanceCase = {
      mesh = meshOf provenanceCase;
      gre9Rules = touching "gre9" provenanceCase;
      denied = provenanceCase.transitAdmission.denied;
    };
    reverseCase = {
      rules = reverseCase.rules;
      denied = reverseCase.transitAdmission.denied;
    };
  }
' > "${result_json}"

fail=0
check() {
  local label="$1"
  local expr="$2"
  if jq -e "${expr}" "${result_json}" >/dev/null; then
    echo "PASS FS-270-HDS-010-SDS-010-SMS-010 ${label}"
  else
    echo "FAIL FS-270-HDS-010-SDS-010-SMS-010 ${label}" >&2
    fail=1
  fi
}

# --- P1: dedicated modeled pair emits authority distinct from provenance ---
check "P1 mesh pair count" '.baseline.mesh | length == 2'
check "P1 no denied surfaces" '.baseline.denied == [] and .baseline.admittedCount == 2'
check "P1 transportAuthority basis" '
  .baseline.mesh | all(.[];
    .transportAuthority.basis == "dedicated-link-isolation"
    and .transportAuthority.provenanceIsAuthority == false
  )'
check "P1 endpoint isolation proofs complete" '
  .baseline.mesh | all(.[];
    [.transportAuthority.from, .transportAuthority.to] | all(.[];
      .admissible == true
      and .dedicated == true
      and .external == false
      and (.modeledPeer.kind == "fabric-link" or .modeledPeer.kind == "modeled-session-peer")
    )
  )'
check "P1 session proof names modeled peer runtime target" '
  .baseline.mesh
  | map(select(.toInterface == "ppp0"))
  | all(.[]; .transportAuthority.to.modeledPeer.peerRuntimeTarget == "esp-site-a-provider-handoff-access-a")
  and (length > 0)'
check "P1 provenance labels still present but flagged non-authority" '
  .baseline.mesh | all(.[];
    ((.relationId // "") | startswith("core-transit-mesh--"))
    and (.comment // "") == (.relationId // "x")
    and .transportAuthority.provenanceIsAuthority == false
  )'

# --- SN1: external surface cannot enter core-transit-mesh -----------------
check "SN1 external surface emits no rule in either direction" '.externalCase.ppp0Rules == []'
check "SN1 no bare public-to-internal mesh accept" '
  .externalCase.mesh | all(.[]; .fromInterface != "ppp0" and .toInterface != "ppp0")'
check "SN1 fail-closed denial names surface and reason" '
  .externalCase.denied
  | length == 1
  and .[0].surface == "ppp0"
  and .[0].reason == "external-surface-not-core-transit"
  and .[0].failClosed == true
  and .[0].diagnostic == "core-transit-admission-denied"'
check "SN1 remaining dedicated surface keeps no mesh peer (no pair invention)" '
  .externalCase.mesh == []'

# --- SN2: provenance labels alone do not authorize -------------------------
check "SN2 unmodeled surface emits no rule" '.provenanceCase.gre9Rules == []'
check "SN2 denial reason is provenance-without-isolation-authority" '
  .provenanceCase.denied
  | length == 1
  and .[0].surface == "gre9"
  and .[0].reason == "provenance-without-isolation-authority"
  and .[0].failClosed == true'

# --- SN3: return leg is stateful, never reverse new-flow authority ---------
check "SN3 exactly one reverse rule and it is stateful established,related" '
  .reverseCase.rules
  | map(select(.fromInterface == "nebula1" and .toInterface == "ens21"))
  | length == 1
  and .[0].connectionState == "established,related"
  and .[0].returnRule == true'
check "SN3 no state-unqualified reverse accept from uplink into transit" '
  .reverseCase.rules
  | map(select(.fromInterface == "nebula1" and .toInterface == "ens21"
               and ((.connectionState // "") == "")))
  | length == 0'
check "SN3 forward delegated rules preserve enforceable source-prefix matches" '
  .reverseCase.rules
  | map(select(.fromInterface == "ens21" and .toInterface == "nebula1"))
  | length > 0
  and all(.[]; (.sourcePrefixes // []) | length > 0)'

# ===========================================================================
# Post-DNAT hop continuity (SMS Negative case 5 / Construction Handoff item 7)
# against the REAL src/cpm/firewall-intent/rules/post-dnat-continuity.nix
# ===========================================================================

continuity_json="$(mktemp)"
trap 'rm -f "${result_json}" "${continuity_json}"' EXIT

REPO_ROOT="${repo_root}" nix eval --impure --json --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    ruleBuilders = import (repoRoot + "/src/cpm/firewall-intent/rules.nix") { };
    evaluate = ruleBuilders.evaluatePostDnatContinuity;

    # Production-shaped translated public-ingress tuple (2026-07-15 case):
    # UDP to 192.168.3.10:4242 after DNAT on the translation owner.
    tuple = {
      family = 4;
      protocol = "udp";
      dstAddress = "192.168.3.10";
      dstPort = 4242;
      translationOwner = "core";
    };

    tupleAllow = {
      action = "accept";
      fromInterface = "ens3";
      toInterface = "ens21";
      trafficType = "public-ingress-tuple";
      matches = [
        {
          proto = "udp";
          family = "any";
          dports = [ 4242 ];
        }
      ];
    };

    # Generic interface-pair accept: plausible provenance labels, no
    # enforceable matches, no isolation authority. Never tuple authority.
    genericPairAccept = {
      action = "accept";
      fromInterface = "ens21";
      toInterface = "ens22";
      trafficType = "any";
      relationId = "selector-handoff-forward--labeled";
      comment = "selector-handoff-forward--labeled";
      nonBypass = true;
    };

    statefulReturn = {
      action = "accept";
      fromInterface = "ens22";
      toInterface = "ens21";
      connectionState = "established,related";
      returnRule = true;
    };

    isolatedTransportAccept = {
      action = "accept";
      fromInterface = "ens21";
      toInterface = "ens22";
      trafficType = "any";
      transportAuthority = {
        basis = "dedicated-link-isolation";
        provenanceIsAuthority = false;
        admissible = true;
      };
    };

    coreHop = {
      name = "core";
      hopAddress = "10.0.0.1";
      selectedTable = "main";
      routes = [
        {
          dst = "192.168.3.10/32";
          table = "main";
          nextHop = "10.0.0.2";
        }
      ];
      rules = [ tupleAllow ];
    };

    selectorRoute = {
      dst = "192.168.3.10/32";
      table = "main";
      nextHop = "10.0.1.2";
    };

    selectorAllow = tupleAllow // {
      fromInterface = "ens21";
      toInterface = "ens22";
    };

    selectorHop = {
      name = "upstream-selector";
      hopAddress = "10.0.0.2";
      selectedTable = "main";
      routes = [ selectorRoute ];
      rules = [ selectorAllow ];
    };

    policyHop = {
      name = "policy";
      hopAddress = "10.0.1.2";
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
        (tupleAllow // {
          fromInterface = "ens22";
          toInterface = "br-tenant";
        })
      ];
    };

    working = evaluate {
      inherit tuple;
      hops = [ coreHop selectorHop policyHop ];
    };

    missingRoute = evaluate {
      inherit tuple;
      hops = [ coreHop (selectorHop // { routes = [ ]; }) policyHop ];
    };

    wrongTable = evaluate {
      inherit tuple;
      hops = [
        coreHop
        (selectorHop // {
          selectedTable = "table-77";
          routes = [ (selectorRoute // { table = "table-77"; }) ];
        })
        policyHop
      ];
    };

    wrongNextHop = evaluate {
      inherit tuple;
      hops = [
        coreHop
        (selectorHop // {
          routes = [ (selectorRoute // { nextHop = "10.0.0.1"; }) ];
        })
        policyHop
      ];
    };

    routeWithoutAllow = evaluate {
      inherit tuple;
      hops = [ coreHop (selectorHop // { rules = [ ]; }) policyHop ];
    };

    genericAcceptNonRecovery = evaluate {
      inherit tuple;
      hops = [
        coreHop
        (selectorHop // { rules = [ genericPairAccept ]; })
        policyHop
      ];
    };

    statefulReturnNonRecovery = evaluate {
      inherit tuple;
      hops = [
        coreHop
        (selectorHop // { rules = [ statefulReturn ]; })
        policyHop
      ];
    };

    isolatedTransportRecovery = evaluate {
      inherit tuple;
      hops = [
        coreHop
        (selectorHop // { rules = [ isolatedTransportAccept ]; })
        policyHop
      ];
    };

    incompleteTuple = evaluate {
      tuple = builtins.removeAttrs tuple [ "dstPort" ];
      hops = [ coreHop selectorHop policyHop ];
    };
  in
  {
    inherit
      working
      missingRoute
      wrongTable
      wrongNextHop
      routeWithoutAllow
      genericAcceptNonRecovery
      statefulReturnNonRecovery
      isolatedTransportRecovery
      incompleteTuple
      ;
  }
' > "${continuity_json}"

check5() {
  local label="$1"
  local expr="$2"
  if jq -e "${expr}" "${continuity_json}" >/dev/null; then
    echo "PASS FS-270-HDS-010-SDS-010-SMS-010 ${label}"
  else
    echo "FAIL FS-270-HDS-010-SDS-010-SMS-010 ${label}" >&2
    fail=1
  fi
}

# --- P2: working chain — same tuple continuous through every hop -----------
check5 "P2 chain continuous with no broken hop" '
  .working.continuous == true
  and .working.firstBrokenHop == null
  and .working.diagnostic == null
  and (.working.hopRecords | length == 3)
  and (.working.hopRecords | all(.[]; .ok == true))'
check5 "P2 every hop emits exact target route, table, next hop, tuple precondition" '
  .working.hopRecords | all(.[];
    .targetRoute != null
    and .selectedTable == "main"
    and .tupleForwarding.satisfied == true
    and .preconditions.routeFound == true
    and .preconditions.tableAuthorized == true
    and .preconditions.nextHopContinuous == true
    and .preconditions.tupleAuthorized == true
  )'
check5 "P2 upstream-selector hop names exact /32 target route and next hop" '
  .working.hopRecords[1]
  | .hop == "upstream-selector"
  and .targetRoute.dst == "192.168.3.10/32"
  and .nextHop == "10.0.1.2"
  and .tupleForwarding.basis == "enforceable-matches"'
check5 "P2 tuple is the same modeled payload tuple at every hop" '
  .working.tuple ==
  {family: 4, protocol: "udp", dstAddress: "192.168.3.10",
   dstPort: 4242, translationOwner: "core"}'

# --- N5a: missing target route fails at exactly upstream-selector ----------
check5 "N5a missing route breaks at upstream-selector with missing-target-route" '
  .missingRoute.continuous == false
  and .missingRoute.firstBrokenHop == "upstream-selector"
  and .missingRoute.failClosed == true
  and .missingRoute.diagnostic.code == "post-dnat-continuity-broken"
  and .missingRoute.diagnostic.hop == "upstream-selector"
  and (.missingRoute.diagnostic.missing | index("missing-target-route") != null)'
check5 "N5a translation owner stays independently OK (per-hop evaluation)" '
  .missingRoute.hopRecords[0] | .hop == "core" and .ok == true'

# --- N5b: wrong policy table fails at exactly upstream-selector ------------
check5 "N5b unauthorized policy table breaks at upstream-selector" '
  .wrongTable.continuous == false
  and .wrongTable.firstBrokenHop == "upstream-selector"
  and (.wrongTable.diagnostic.missing | index("wrong-policy-table") != null)'

# --- N5c: wrong next hop fails at exactly upstream-selector ----------------
check5 "N5c wrong next hop breaks at upstream-selector" '
  .wrongNextHop.continuous == false
  and .wrongNextHop.firstBrokenHop == "upstream-selector"
  and (.wrongNextHop.diagnostic.missing | index("wrong-next-hop") != null)
  and (.wrongNextHop.diagnostic.missing | index("missing-target-route") == null)'

# --- N5d: route present but tuple allow missing ----------------------------
check5 "N5d route without tuple allow breaks at upstream-selector" '
  .routeWithoutAllow.continuous == false
  and .routeWithoutAllow.firstBrokenHop == "upstream-selector"
  and (.routeWithoutAllow.diagnostic.missing | index("route-without-tuple-allow") != null)
  and .routeWithoutAllow.hopRecords[1].preconditions.routeFound == true'

# --- N5e: generic interface-pair accept is NOT recovery --------------------
check5 "N5e generic labeled interface-pair accept does not recover the hop" '
  .genericAcceptNonRecovery.continuous == false
  and .genericAcceptNonRecovery.firstBrokenHop == "upstream-selector"
  and (.genericAcceptNonRecovery.diagnostic.missing
       | index("route-without-tuple-allow") != null)
  and .genericAcceptNonRecovery.hopRecords[1].tupleForwarding.satisfied == false'

# --- N5f: stateful return never authorizes the forward tuple ---------------
check5 "N5f stateful return rule does not authorize the forward tuple" '
  .statefulReturnNonRecovery.continuous == false
  and .statefulReturnNonRecovery.firstBrokenHop == "upstream-selector"
  and .statefulReturnNonRecovery.hopRecords[1].tupleForwarding.satisfied == false'

# --- R3: recovery via enforceable matches or complete isolated transport ---
check5 "R3 complete isolated transport authority restores continuity" '
  .isolatedTransportRecovery.continuous == true
  and .isolatedTransportRecovery.firstBrokenHop == null
  and .isolatedTransportRecovery.hopRecords[1].tupleForwarding.basis
      == "isolated-transport-authority"'

# --- N5g: incomplete translated tuple is rejected fail-closed --------------
check5 "N5g incomplete translated tuple rejected fail-closed" '
  .incompleteTuple.continuous == false
  and .incompleteTuple.failClosed == true
  and .incompleteTuple.diagnostic.code == "post-dnat-tuple-incomplete"'

if [[ "${fail}" -ne 0 ]]; then
  echo "FAIL FS-270-HDS-010-SDS-010-SMS-010 policy-point transit authority construction test" >&2
  exit 1
fi

echo "PASS FS-270-HDS-010-SDS-010-SMS-010 policy-point transit authority construction test"
