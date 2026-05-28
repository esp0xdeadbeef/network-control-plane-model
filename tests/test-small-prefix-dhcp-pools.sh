#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-DHCP-SMALL-PREFIX-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
output_json="${tmp_dir}/cpm.json"

nix flake archive --json "path:${repo_root}" >"${archive_json}"
labs_root="$(jq -er '.inputs["network-labs"].path' "${archive_json}")"

nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_root}/examples/tri-site-dual-wan-overlay-integration-bgp/intent.nix" \
  "${labs_root}/examples/tri-site-dual-wan-overlay-integration-bgp/inventory-clab.nix" \
  "${output_json}" >/dev/null

jq -e '
  def dhcp_pool($tenant):
    [
      .. | objects
      | select(.tenant? == $tenant and .pool?)
      | .pool
    ][0];

  dhcp_pool("streaming") == { start: "10.90.50.2", end: "10.90.50.6" }
  and dhcp_pool("nas") == { start: "10.90.40.2", end: "10.90.40.6" }
  and dhcp_pool("printer") == { start: "10.90.30.2", end: "10.90.30.6" }
' "${output_json}" >/dev/null

echo "PASS small-prefix-dhcp-pools"
