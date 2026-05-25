#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

flake_input_path() {
  local input_name="$1"
  nix flake archive --json "path:${repo_root}" |
    jq -er ".inputs[\"${input_name}\"].path"
}

labs_path="$(flake_input_path network-labs)"
output_json="$(mktemp)"
trap 'rm -f "${output_json}"' EXIT

nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_path}/examples/tri-site-s-router-overlay-egress/intent.nix" \
  "${labs_path}/examples/tri-site-s-router-overlay-egress/inventory.nix" \
  "${output_json}" >/dev/null

jq -e '
  (.control_plane_model.data | to_entries[].value | to_entries[].value | select(.siteName == "esp.home")).runtimeTargets as $targets
  | $targets["esp-home-example-router-core-nebula"].runtimeOriginEgress.sourcePrefixes as $sources
  | $targets["esp-home-example-router-access-mgmt"].services.dns.allowFrom as $allow
  | {
      ok:
        (($sources | map(.prefix) | index("10.19.0.8/32")) != null)
        and (($sources | map(.prefix) | index("fd42:dead:beef:1900:0:0:0:8/128")) != null)
        and ($allow | index("10.19.0.8/32") != null)
        and ($allow | index("fd42:dead:beef:1900:0:0:0:8/128") != null),
      runtimeOriginSourcePrefixes: $sources,
      accessMgmtDnsAllowFrom: $allow
    }
  | select(.ok == true)
' "${output_json}" >/dev/null || {
  echo "FAIL runtime-origin-dns-provider-allow-from: DNS providers used by runtime-origin core recursion must allow the runtime-origin loopback source prefixes" >&2
  jq '
    (.control_plane_model.data | to_entries[].value | to_entries[].value | select(.siteName == "esp.home")).runtimeTargets
    | {
        coreNebulaRuntimeOrigin: ."esp-home-example-router-core-nebula".runtimeOriginEgress.sourcePrefixes,
        accessMgmtDnsAllowFrom: ."esp-home-example-router-access-mgmt".services.dns.allowFrom
      }
  ' "${output_json}" >&2
  exit 1
}

echo "PASS runtime-origin-dns-provider-allow-from"
