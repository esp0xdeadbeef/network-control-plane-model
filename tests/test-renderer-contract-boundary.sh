#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-FS140-FS150-FS160-RENDERER-CONTRACT-BOUNDARY-001
# GAMP-TRACE: FS-140-HDS-010-SDS-010-SMS-010
# GAMP-TRACE: FS-150-HDS-010-SDS-010-SMS-010
# GAMP-TRACE: FS-160-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

output_json="${work_dir}/renderer-contracts.json"

nix eval --impure --no-warn-dirty --json --expr '
  let
    flake = builtins.getFlake "path:'"${repo_root}"'";
    lib = flake.inputs.nixpkgs.lib;
    cpmLib = flake.libBySystem.x86_64-linux;
    labs = flake.inputs.network-labs;
    input = import "${labs}/examples/single-wan-with-nebula/intent.nix";
    baseInventory = import "${labs}/examples/single-wan-with-nebula/inventory-nixos.nix";
    inventory = lib.recursiveUpdate baseInventory {
      controlPlane.sites.esp0xdeadbeef.site-a.rendererTargets.nixos-dns-limited = {
        platform = "nixos";
        provider = "nebula";
        capabilityReason = "test target intentionally lacks DNS support";
        supports = {
          policy = true;
          reachability = true;
          addressAuthority = true;
          nat = true;
          routing = true;
          dns = false;
          serviceExposure = true;
          runtimeFacts = true;
        };
      };
      controlPlane.sites.esp0xdeadbeef.site-a.rendererTargets.nixos-nat-limited = {
        platform = "nixos";
        provider = "nebula";
        capabilityReason = "test target intentionally lacks NAT support";
        supports = {
          policy = true;
          reachability = true;
          addressAuthority = true;
          nat = false;
          routing = true;
          dns = true;
          serviceExposure = true;
          runtimeFacts = true;
        };
      };
      controlPlane.sites.esp0xdeadbeef.site-a.rendererTargets.nixos-supported = {
        platform = "nixos";
        provider = "nebula";
        capabilityReason = "test target declares support for all required capabilities";
        supports = {
          policy = true;
          reachability = true;
          addressAuthority = true;
          nat = true;
          routing = true;
          dns = true;
          serviceExposure = true;
          runtimeFacts = true;
        };
      };
    };
    built = cpmLib.compileAndBuild {
      inherit input inventory;
    };
  in
    built.control_plane_model.data.esp0xdeadbeef."site-a".rendererContracts
' >"${output_json}"

jq -e '
  .scopedArtifacts.runtimeTargets["esp0xdeadbeef-site-a-s-router-core-nebula"] as $target
  | .scopedArtifacts.providerProfiles.nebula__nebula as $provider
  | .portableMeaning as $portable
  | .rendererEmission.targets["nixos-dns-limited"] as $dnsDecision
  | .rendererEmission.targets["nixos-nat-limited"] as $natDecision
  | .rendererEmission.targets["nixos-supported"] as $supportedDecision
  | .limitations as $limitations
  | (
      $target.emissionStage == "control-plane-model-before-renderer"
      and $target.scope.kind == "runtimeTarget"
      and $target.scope.runtimeTarget == "esp0xdeadbeef-site-a-s-router-core-nebula"
      and $target.payloadRef == "control_plane_model.data.esp0xdeadbeef.site-a.runtimeTargets.esp0xdeadbeef-site-a-s-router-core-nebula"
      and $target.payload.logicalNode.name == "s-router-core-nebula"
      and ($target.payload | has("runtimeTargets") | not)
      and ($target.excluded.unrelatedRuntimeTargets | index("esp0xdeadbeef-site-a-s-router-upstream-selector"))
      and any($target.includedSharedMetadata[]; .classification == "required-shared-metadata" and .path == "runtimeTargets.esp0xdeadbeef-site-a-s-router-core-nebula")
      and any($target.includedSharedMetadata[]; .classification == "required-shared-metadata" and .path == "routing.mode")
    )
    and (
      $provider.scope.kind == "providerProfile"
      and $provider.scope.provider == "nebula"
      and $provider.scope.overlay == "nebula"
      and $provider.payload.provider == "nebula"
      and $provider.payload.nebula.role == "lighthouse"
      and ($provider.includedRuntimeTargets | index("esp0xdeadbeef-site-a-s-router-core-nebula"))
      and any($provider.includedSharedMetadata[]; .path == "overlays.nebula.provider")
    )
    and (
      $portable.comparisonAuthority == "control-plane-model"
      and $portable.requiredBehavior.routing.mode == "static"
      and ($portable.requiredBehavior.reachability.runtimeTargetNames | index("esp0xdeadbeef-site-a-s-router-core-nebula"))
      and ($portable.requiredBehavior.dns.serviceNames | index("dns-site"))
      and ($portable.comparisonInputs.requiredCapabilities | index("dns"))
      and $portable.requiredBehavior.translation.natRequired == true
      and ($portable.comparisonInputs.requiredCapabilities | index("nat"))
    )
    and (
      $dnsDecision.allowed == false
      and $dnsDecision.action == "block-renderer-emission"
      and .rendererEmission.blocked == true
      and any($limitations[];
        .unsupportedBehavior == "dns"
        and .decision == "block-renderer-emission"
        and .affectedScope.rendererTarget == "nixos-dns-limited"
        and (.requiredSourceFacts | index("services.*.dns"))
      )
    )
    and (
      $natDecision.allowed == false
      and $natDecision.action == "block-renderer-emission"
      and any($limitations[];
        .unsupportedBehavior == "nat"
        and .decision == "block-renderer-emission"
        and .affectedScope.rendererTarget == "nixos-nat-limited"
        and (.requiredSourceFacts | index("runtimeTargets.*.natIntent"))
      )
    )
    and (
      $supportedDecision.allowed == true
      and $supportedDecision.action == "allow-renderer-emission"
      and $supportedDecision.limitationCount == 0
      and (any($limitations[]; .affectedScope.rendererTarget == "nixos-supported") | not)
    )
  ' "${output_json}" >/dev/null

echo "PASS FS-140-HDS-010-SDS-010-SMS-010: scoped renderer contract boundary"
echo "PASS FS-150-HDS-010-SDS-010-SMS-010: portable meaning contract boundary"
echo "PASS FS-160-HDS-010-SDS-010-SMS-010: renderer limitation contract boundary"
