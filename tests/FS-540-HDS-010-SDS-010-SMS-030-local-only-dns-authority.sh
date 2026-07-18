#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
cd "${repo_root}"

result="$(nix eval --json --extra-experimental-features 'nix-command flakes' --impure --expr '
let
  flake = builtins.getFlake ("path:" + toString ./.);
  system = builtins.currentSystem;
  labs = flake.inputs.network-labs.outPath;
  traceId = "FS-540-HDS-010-SDS-010-SMS-030";
  source = import (labs + "/GAMP/SMT/FS-540-HDS-010-SDS-010-SMS-030/intent.nix");
  nixosInventory = import (labs + "/GAMP/SMT/FS-540-HDS-010-SDS-010-SMS-030/inventory-nixos.nix");
  clabInventory = import (labs + "/GAMP/SMT/FS-540-HDS-010-SDS-010-SMS-030/inventory-clab.nix");
  build = inventory: flake.libBySystem.${system}.compileAndBuild {
    input = source;
    inherit inventory;
  };
  siteFor = built: built.control_plane_model.data.mini-smt.${traceId};
  dnsByNode = built:
    let site = siteFor built;
    in builtins.listToAttrs (builtins.map
      (target: {
        name = target.logicalNode.name;
        value = (target.services or { }).dns or null;
      })
      (builtins.attrValues site.runtimeTargets));
  nixosBuilt = build nixosInventory;
  clabBuilt = build clabInventory;
  nixosDns = dnsByNode nixosBuilt;
  clabDns = dnsByNode clabBuilt;
  recursiveDns = nixosDns.access-recursive;
  localDns = nixosDns.access-local;
  coreDns = nixosDns.core-primary;
  localUpstream = builtins.head (
    builtins.filter (entry: (entry.kind or null) == "local-namespace-authority")
      localDns.upstreamResolvers
  );
  requesterPolicy = builtins.head recursiveDns.requesterPolicies;
  familyComplete = addresses:
    builtins.any (address: builtins.match ".*:.*" address == null) addresses
    && builtins.any (address: builtins.match ".*:.*" address != null) addresses;
  baseSite = source.mini-smt.${traceId};
  leakingInput = {
    mini-smt.${traceId} = baseSite // {
      localDnsSharingIntent = baseSite.localDnsSharingIntent // {
        requester = baseSite.localDnsSharingIntent.requester // {
          recursion = true;
        };
      };
    };
  };
  leakingBuilt = flake.libBySystem.${system}.compileAndBuild {
    input = leakingInput;
    inventory = nixosInventory;
  };
  leakingSite = siteFor leakingBuilt;
  leakingWarnings = leakingSite.dns.warnings or [ ];
  projectedWarningSets = builtins.filter (warnings: warnings != [ ]) (
    builtins.map
      (target: ((target.services or { }).dns or { }).reproducibilityWarnings or [ ])
      (builtins.attrValues leakingSite.runtimeTargets)
  );
in {
  positive =
    (siteFor nixosBuilt).dns.warnings == [ ]
    && nixosDns == clabDns
    && localDns.recursionMode == "local-only"
    && (localDns.forwarders or [ ]) == [ ]
    && builtins.map (zone: zone.name) localDns.localForwardZones == [
      "30.54.10.in-addr.arpa."
      "lab."
    ]
    && builtins.all (zone: zone.forwardFirst == false && familyComplete zone.forwardTo)
      localDns.localForwardZones
    && localDns.localOnlyPolicy.recursion == false
    && localDns.localOnlyPolicy.publicFallback == false
    && localDns.localOnlyPolicy.transitiveEgress == false
    && localUpstream.recursion == false
    && localUpstream.publicFallback == false
    && localUpstream.transitiveEgress == false
    && requesterPolicy.requesterService == "local-dns"
    && requesterPolicy.action == "refuse_non_local"
    && familyComplete requesterPolicy.sourcePrefixes
    && builtins.all (prefix: !(builtins.elem prefix (recursiveDns.allowFrom or [ ])))
      requesterPolicy.sourcePrefixes
    && coreDns.recursionMode == "iterative"
    && (coreDns.forwarders or [ ]) == [ ]
    && coreDns.egress.uplinks == [ "isp-primary" ];
  inherit leakingWarnings projectedWarningSets;
}
')"

jq -e '
  . as $root
  | $root.positive == true
  and [$root.leakingWarnings[].code] == ["DNS_LOCAL_ONLY_AUTHORITY_LEAK"]
  and ($root.projectedWarningSets | length) >= 2
  and all($root.projectedWarningSets[]; . == $root.leakingWarnings)
  and all($root.leakingWarnings[];
    .disposition == "fail-closed"
    and .traceId == "FS-540-HDS-010-SDS-010-SMS-020"
  )
' <<<"${result}" >/dev/null

if jq -e '[.leakingWarnings[] | paths(scalars) as $path | ($path[-1] | tostring) | select(
  . == "address" or . == "addresses" or . == "ipv4" or . == "ipv6"
)] == []' <<<"${result}" >/dev/null; then
  :
else
  echo "FAIL FS-540 warning record contains address fields" >&2
  exit 1
fi

echo "PASS FS-540 local-only DNS authority and renderer-equivalent contract"
