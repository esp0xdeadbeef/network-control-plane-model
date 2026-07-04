#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
labs_repo="${NETWORK_LABS_REPO:-/home/deadbeef/github/network-labs}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

out_json="${tmp_dir}/cpm.json"

nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_repo}/examples/policy-any-to-any-fw/intent.nix" \
  "${labs_repo}/examples/policy-any-to-any-fw/inventory-clab.nix" \
  "${out_json}" >/dev/null

jq -e '
  .control_plane_model
  and (.endpointInventory.deployment.hosts["lab-host"].bridgeNetworks | type == "object")
  and (.deploymentHosts["lab-host"].bridgeNetworks | type == "object")
  and (.endpointInventory.deployment.hosts["lab-host"].uplinks.uplink0.mode == "nat")
  and (.endpointInventory.deployment.hosts["lab-host"].uplinks.uplink0.dhcpServer == true)
  and (.endpointInventory.deployment.hosts["lab-host"].uplinks.uplink0.masquerade == "ipv4")
  and (.endpointInventory.deployment.hosts["lab-host"].uplinks.uplink0.ipv4.address == "198.51.100.1/24")
  and (.endpointInventory.deployment.hosts["lab-host"].uplinks.uplink0.ipv4.clientAddress == "198.51.100.2")
  and (.endpointInventory.deployment.hosts["lab-host"].uplinks.uplink0.ipv4.dhcpPoolOffset == 100)
  and (.endpointInventory.deployment.hosts["lab-host"].uplinks.uplink0.ipv4.dhcpPoolSize == 100)
' "${out_json}" >/dev/null

echo "PASS endpoint inventory payload is available to renderers with explicit NAT bridge authority"
