#!/usr/bin/env bash
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-001-SMS-001-001
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-001-SMS-001-002
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-001-SMS-001-003
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-001-SMS-001-CMC-001-001
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-001-SMS-001-CMC-001-002
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-001-SMS-001-CMC-001-003
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-004-SMS-001-001
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-004-SMS-001-002
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-004-SMS-001-CMC-001-001
# GAMP-ID: USR-INET-002-FS-001-HDS-001-SDS-001-004-SMS-001-CMC-001-002
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

output_json="$(mktemp)"
trap 'rm -f "${output_json}"' EXIT

example_root="${repo_root}/../network-labs/examples/single-wan-uplink-static-egress"

nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${example_root}/intent.nix" \
  "${example_root}/inventory-nixos.nix" \
  "${output_json}" >/dev/null

jq -e '
  [
    .control_plane_model.data[][]?.runtimeTargets[]?
  ] as $targets
  | ([
      $targets[]
      | select((.natIntent.families.ipv6 // false) == true)
    ] | length == 0)
  and ([
      $targets[]
      | select(((.natIntent.masqueradeSourcePrefixes6 // []) | length) > 0)
    ] | length == 0)
  and ([
      $targets[]
      | .effectiveRuntimeRealization.interfaces[]?.routes.ipv6[]?
      | select((.dst // "") == "::/0")
      | select(((.intent // {}).kind // "") == "default-reachability")
    ] | length == 0)
' "${output_json}" >/dev/null || {
  echo "FAIL ula-only-no-ipv6-egress-contract: IPv4-only static egress must not emit IPv6 default reachability or NAT66 for ULA-only clients" >&2
  exit 1
}

echo "PASS ula-only-no-ipv6-egress-contract"
