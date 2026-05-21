#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

output_json="$(mktemp)"
checks_json="$(mktemp)"
trap 'rm -f "${output_json}" "${checks_json}"' EXIT

nix_args=()
if [[ -n "${NETWORK_FORWARDING_MODEL_OVERRIDE:-}" ]]; then
  nix_args+=(--override-input network-forwarding-model "${NETWORK_FORWARDING_MODEL_OVERRIDE}")
fi

nix eval "${nix_args[@]}" \
  --extra-experimental-features 'nix-command flakes' \
  --impure --json "path:${repo_root}#lib.x86_64-linux.compileAndBuildFromPaths" \
  --apply 'f: (f {
    inputPath = "/home/deadbeef/github/network-labs/labs/lab-s-sigma/s-router-test-three-site/intent.nix";
    inventoryPath = "/home/deadbeef/github/network-labs/labs/lab-s-sigma/s-router-test-three-site/inventory.nix";
  }).control_plane_model.data' > "${output_json}"

OUTPUT_JSON="${output_json}" nix eval --impure --json --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    hasAll = expected: actual:
      builtins.all (value: builtins.elem value actual) expected;
    warningMentionsNat66 = nat:
      builtins.any (warning: builtins.match ".*NAT66.*" warning != null) (nat.warnings or [ ]);
    nixos = data.esp.nixos.runtimeTargets;
    clab = data.esp.clab.runtimeTargets;
    hetz = data.esp.hetz.runtimeTargets;
    ispA = nixos."esp-nixos-router-core-isp-a".natIntent;
    ispB = nixos."esp-nixos-router-core-isp-b".natIntent;
    clabIsp = clab."esp-clab-router-core-simulated-isp".natIntent;
    hetzCore = hetz."esp-hetz-router-core".natIntent;
    hostileAccess = nixos."esp-nixos-router-access-hostile".advertisements.ipv6Ra;
    hostileRouted =
      builtins.concatMap
        (entry: builtins.map (prefix: prefix.ipv6 or "") (entry.routedPrefixes or [ ]))
        hostileAccess;
    normalNixosPrefixes = [
      "fd42:dead:beef:10::/64"
      "fd42:dead:beef:15::/64"
      "fd42:dead:beef:20::/64"
      "fd42:dead:beef:50::/64"
    ];
  in {
    nixosIspAEnablesNat66 = ispA.families.ipv6 == true;
    nixosIspBEnablesNat66 = ispB.families.ipv6 == true;
    nixosIspAWarns = warningMentionsNat66 ispA;
    nixosIspBWarns = warningMentionsNat66 ispB;
    nixosIspAScopesNormalUla = hasAll normalNixosPrefixes (ispA.masqueradeSourcePrefixes6 or [ ]);
    nixosIspBScopesNormalUla = hasAll normalNixosPrefixes (ispB.masqueradeSourcePrefixes6 or [ ]);
    nixosIspADoesNotNatHostileUla = !(builtins.elem "fd42:dead:beef:70::/64" (ispA.masqueradeSourcePrefixes6 or [ ]));
    nixosIspBDoesNotNatHostileUla = !(builtins.elem "fd42:dead:beef:70::/64" (ispB.masqueradeSourcePrefixes6 or [ ]));
    nixosIspADoesNotNatHostileGua = builtins.all (prefix: !(builtins.elem prefix (ispA.masqueradeSourcePrefixes6 or [ ]))) hostileRouted;
    nixosIspBDoesNotNatHostileGua = builtins.all (prefix: !(builtins.elem prefix (ispB.masqueradeSourcePrefixes6 or [ ]))) hostileRouted;
    clabSimulatedIspEnablesNat66 = clabIsp.families.ipv6 == true;
    clabSimulatedIspWarns = warningMentionsNat66 clabIsp;
    hetzRoutedCoreDoesNotNat66 = hetzCore.families.ipv6 == false;
    hetzRoutedCoreHasNoNat66Sources = (hetzCore.masqueradeSourcePrefixes6 or [ ]) == [ ];
  }
' > "${checks_json}"

failed_checks="$(jq -r 'to_entries[] | select(.value != true) | .key' "${checks_json}")"
if [[ -n "${failed_checks}" ]]; then
  echo "FAIL lab-sigma-simulated-isp-nat66" >&2
  echo "failed checks:" >&2
  while IFS= read -r failed_check; do
    echo "  ${failed_check}" >&2
  done <<< "${failed_checks}"
  echo "natIntent evidence:" >&2
  OUTPUT_JSON="${output_json}" nix eval --impure --json --expr '
    let
      data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
      rt = data.esp.nixos.runtimeTargets;
      clabRt = data.esp.clab.runtimeTargets;
      hetzRt = data.esp.hetz.runtimeTargets;
      compact = target: {
        egressNat66 = target.egressIntent.nat66 or {};
        natIntent = target.natIntent or {};
      };
    in {
      nixosIspA = compact rt."esp-nixos-router-core-isp-a";
      nixosIspB = compact rt."esp-nixos-router-core-isp-b";
      clabSimulatedIsp = compact clabRt."esp-clab-router-core-simulated-isp";
      hetzCore = compact hetzRt."esp-hetz-router-core";
    }
  ' | gron >&2 || true
  exit 1
fi

echo "PASS lab-sigma-simulated-isp-nat66"
