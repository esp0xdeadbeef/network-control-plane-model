#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-DNS-RUNTIME-ALLOW-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-008-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-009-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-008-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-009-SMS-001-CMC-001-003
# GAMP-SCOPE: software-module-test
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
tmp_dir="$(mktemp -d)"
inventory_nix="${tmp_dir}/inventory-runtime-origin-dns-forwarders.nix"
output_json="${tmp_dir}/output.json"
trap 'rm -rf "${tmp_dir}"' EXIT

cat >"${inventory_nix}" <<EOF
let
  base = import ${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix;
  nodeName = "esp0xdeadbeef-site-a-s-router-core-nebula";
  node = base.realization.nodes.\${nodeName};
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      \${nodeName} = node // {
        services = (node.services or { }) // {
          dns = ((node.services or { }).dns or { }) // {
            forwarders = [ "10.20.10.1" "fd42:dead:beef:10::1" ];
          };
        };
      };
    };
  };
}
EOF

nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
  "${inventory_nix}" \
  "${output_json}" >/dev/null

jq -e '
  .control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets as $targets
  | $targets["esp0xdeadbeef-site-a-s-router-core-nebula"].runtimeOriginEgress.sourcePrefixes as $sources
  | $targets["esp0xdeadbeef-site-a-s-router-access-mgmt"].services.dns.allowFrom as $allow
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
    .control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets
    | {
        coreNebulaRuntimeOrigin: ."esp0xdeadbeef-site-a-s-router-core-nebula".runtimeOriginEgress.sourcePrefixes,
        coreNebulaDns: ."esp0xdeadbeef-site-a-s-router-core-nebula".services.dns,
        accessMgmtDnsAllowFrom: ."esp0xdeadbeef-site-a-s-router-access-mgmt".services.dns.allowFrom
      }
  ' "${output_json}" >&2
  exit 1
}

echo "PASS runtime-origin-dns-provider-allow-from"
