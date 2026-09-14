#!/usr/bin/env bash
# GAMP-ID: FS-267-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
#
# FS-267: host-facing status is derived from what a surface attaches to, not
# from the role name of the terminating node. A modeled point-to-point fabric
# link between two non-core, non-access fabric roles is dedicated transport.
#
# Seeded negative 3: a fabric link with neither a core nor an access role,
# carrying an unclassified (trafficType = "any") forward rule, must be
# admitted as dedicated-link-isolation rather than rejected as unproven.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
LABS="${NETWORK_LABS_PATH:-/home/deadbeef/github/network-labs}"
row="${LABS}/GAMP/SMT/FS-540-HDS-010-SDS-010-SMS-045"

fail() {
  echo "FAIL FS-267-HDS-010-SDS-010-SMS-010: $1" >&2
  exit 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

cat >"${tmpdir}/probe.nix" <<NIX
let
  cpm = builtins.getFlake "${repo_root}";
  site = cpm.lib.\${builtins.currentSystem}.compileAndBuildFromPaths {
    inputPath = ${row}/intent.nix;
    inventoryPath = ${row}/inventory-nixos.nix;
  };
  data = site.control_plane_model.data.mini-smt."FS-540-HDS-010-SDS-010-SMS-045";
  selector = data.runtimeTargets."mini-smt-FS-540-HDS-010-SDS-010-SMS-045-upstream-selector";
  policy = data.runtimeTargets."mini-smt-FS-540-HDS-010-SDS-010-SMS-045-policy";
  downstream = data.runtimeTargets."mini-smt-FS-540-HDS-010-SDS-010-SMS-045-downstream-selector";
  hostFacing = target:
    builtins.mapAttrs (_: i: i.hostFacing or null) target.effectiveRuntimeRealization.interfaces;
  forwardLegs = target:
    builtins.filter
      (r:
        let c = r.comment or "<none>"; in
        builtins.match ".*selector-handoff-forward--.*" c != null)
      target.forwardingIntent.rules;
  summarize = r:
    let ta = r.transportAuthority or null; in
    {
      from = r.fromInterface or null;
      to = r.toInterface or null;
      admissible = if ta == null then null else ta.admissible;
      basis = if ta == null then null else (ta.basis or null);
    };
in
{
  selectorHostFacing = hostFacing selector;
  policyHostFacing = hostFacing policy;
  selectorForward = map summarize (forwardLegs selector);
  downstreamForward = map summarize (forwardLegs downstream);
}
NIX

result="$(nix eval --impure --json -f "${tmpdir}/probe.nix" 2>/dev/null)"
[[ -n "${result}" ]] || fail "probe evaluation produced no result"

# Seeded negative 3a: the fabric links carry no core or access role yet must be
# classified non-host-facing.
jq -e '
  ([ .selectorHostFacing[] ] | length) > 0
  and ([ .selectorHostFacing[] | . == false ] | all)
  and ([ .policyHostFacing[] ] | length) > 0
  and ([ .policyHostFacing[] | . == false ] | all)
' <<<"${result}" >/dev/null || fail "a modeled fabric link was classified host-facing"

# Seeded negative 3b: the unclassified fabric forward rule must be admitted by
# dedicated-link-isolation, not dropped as unproven.
jq -e '
  (.selectorForward | length) > 0
  and ([ .selectorForward[] | .admissible == true ] | all)
  and ([ .selectorForward[] | .basis == "dedicated-link-isolation" ] | all)
' <<<"${result}" >/dev/null || {
  echo "FAIL FS-267-HDS-010-SDS-010-SMS-010: unclassified fabric forward leg was not admitted as dedicated transport" >&2
  jq '.selectorForward' <<<"${result}" >&2
  exit 1
}

# The same holds for every other selector in the fabric, so the fix is not
# specific to one role.
jq -e '
  (.downstreamForward | length) > 0
  and ([ .downstreamForward[] | .admissible == true ] | all)
' <<<"${result}" >/dev/null || fail "downstream selector forward legs were not admitted"

echo "PASS FS-267-HDS-010-SDS-010-SMS-010: modeled fabric links are dedicated transport and their forward rules are admitted"
