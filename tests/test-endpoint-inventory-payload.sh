#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
labs_repo="${NETWORK_LABS_REPO:-$(nix flake archive --json "path:${repo_root}" | jq -er '.inputs["network-labs"].path')}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

out_json="${tmp_dir}/cpm.json"

nix run --no-write-lock-file "${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_repo}/examples/policy-any-to-any-fw/intent.nix" \
  "${labs_repo}/examples/policy-any-to-any-fw/inventory-clab.nix" \
  "${out_json}" >/dev/null

# Intent carries the translation decision (FS-171/FS-350-SMS-110: translation
# mode is modelled authority), the endpoint inventory carries only the mechanics
# a renderer needs to realize it. Assert both at their owning boundary.
jq -e '
  .control_plane_model
  and (.endpointInventory.deployment.hosts["lab-host"].bridgeNetworks | type == "object")
  and (.deploymentHosts["lab-host"].bridgeNetworks | type == "object")
  and (.endpointInventory.deployment.hosts["lab-host"].uplinks.uplink0.mode == "nat")
  and (.endpointInventory.deployment.hosts["lab-host"].uplinks.uplink0.dhcpServer == true)
  and (.endpointInventory.deployment.hosts["lab-host"].uplinks.uplink0 | has("masquerade") | not)
  and (.endpointInventory.deployment.hosts["lab-host"].uplinks.uplink0.ipv4.address == "198.51.100.1/24")
  and (.endpointInventory.deployment.hosts["lab-host"].uplinks.uplink0.ipv4.clientAddress == "198.51.100.2")
  and (.endpointInventory.deployment.hosts["lab-host"].uplinks.uplink0.ipv4.dhcpPoolOffset == 100)
  and (.endpointInventory.deployment.hosts["lab-host"].uplinks.uplink0.ipv4.dhcpPoolSize == 100)
  and (
    .control_plane_model.data
    | [.. | objects | .egressIntent?.nat44? | objects | to_entries[] | select(.value.mode == "nat44")]
    | length > 0
  )
' "${out_json}" >/dev/null

echo "PASS endpoint inventory payload is available to renderers with explicit NAT bridge authority"
