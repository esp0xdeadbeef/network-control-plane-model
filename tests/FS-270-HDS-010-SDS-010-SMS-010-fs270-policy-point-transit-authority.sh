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

if [[ "${fail}" -ne 0 ]]; then
  echo "FAIL FS-270-HDS-010-SDS-010-SMS-010 policy-point transit authority construction test" >&2
  exit 1
fi

echo "PASS FS-270-HDS-010-SDS-010-SMS-010 policy-point transit authority construction test"
