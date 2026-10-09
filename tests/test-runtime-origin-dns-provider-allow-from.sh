#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-DNS-RUNTIME-ALLOW-001
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
  | $targets["esp0xdeadbeef-site-a-s-router-core-nebula"].services.dns.outgoingInterfaces as $sources
  | $targets["esp0xdeadbeef-site-a-s-router-access-mgmt"].services.dns.allowFrom as $allow
  | {
      ok:
        # FS-540-HDS-010-SDS-010-SMS-020: a resolver that owns no modeled exit
        # binds its recursion source to its own modeled service identity (its
        # non-loopback resolver addresses), not its ownership loopback, and the
        # exit-side requester ACL agrees with that identity.
        (($sources | index("100.96.10.1")) != null)
        and (($sources | index("fd42:dead:beef:ee::1")) != null)
        and (($sources | index("10.19.0.8")) == null)
        and ($allow | index("100.96.10.1/32") != null)
        and ($allow | index("fd42:dead:beef:ee::1/128") != null)
        and ($allow | index("10.19.0.8/32") == null),
      recursionSourceInterfaces: $sources,
      accessMgmtDnsAllowFrom: $allow
    }
  | select(.ok == true)
' "${output_json}" >/dev/null || {
  echo "FAIL runtime-origin-dns-provider-allow-from: a resolver with no modeled exit must bind its recursion source to its non-loopback service identity and the provider ACL must agree" >&2
  jq '
    .control_plane_model.data.esp0xdeadbeef."site-a".runtimeTargets
    | {
        coreNebulaRecursionSource: ."esp0xdeadbeef-site-a-s-router-core-nebula".services.dns.outgoingInterfaces,
        accessMgmtDnsAllowFrom: ."esp0xdeadbeef-site-a-s-router-access-mgmt".services.dns.allowFrom
      }
  ' "${output_json}" >&2
  exit 1
}

echo "PASS runtime-origin-dns-provider-allow-from"
