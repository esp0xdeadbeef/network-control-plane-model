#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-011-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

hat_dir="$(pinned_hat_dir)"
provider_table_path="$(pinned_sat_dir)/provider-access-fixture-table.nix"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

write_inventory_case() {
  local path="$1"
  local base_inventory="$2"
  local nixos_expr="$3"
  local clab_expr="$4"

  cat >"${path}" <<EOF
let
  base = import ${base_inventory};
  providerTable = import ${provider_table_path};
in
base
// {
  controlPlane = (base.controlPlane or { }) // {
    providerAccess = ((base.controlPlane or { }).providerAccess or { }) // {
      scenarios = {
        pppoeNixos = ${nixos_expr};
        pppoeClab = ${clab_expr};
      };
    };
  };
}
EOF
}

build_cpm() {
  local inventory="$1"
  local output="$2"

  nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
    "${hat_dir}/intent.nix" \
    "${inventory}" \
    "${output}" >/dev/null
}

assert_follow_source_dns() {
  local output="$1"
  local site="$2"
  local target="$3"
  local self_v4="$4"
  local self_v6="$5"
  local scenario="$6"

  jq -e \
    --arg site "${site}" \
    --arg target "${target}" \
    --arg self_v4 "${self_v4}" \
    --arg self_v6 "${self_v6}" \
    --arg scenario "${scenario}" '
      .control_plane_model.data.esp0xdeadbeef[$site].runtimeTargets[$target].services.dns as $dns
      | ($dns.forwarders // []) as $forwarders
      | ($dns.upstreamResolvers // []) as $records
      | ($dns.routeContracts // []) as $routes
      | ($dns.policyMatrix // []) as $policy
      | ($forwarders | index($self_v4) == null)
        and ($forwarders | index($self_v6) == null)
        and any($records[];
          .source == "provider-access-dns"
          and .upstreamSource == "follow-source"
          and .scenario == $scenario
          and .relationId == "allow-hat-site-dns-service-to-client-uplinks"
          and .failClosed == true
          and .fallbackToCustomerResolver == false
          and (.uplinks == [ "testnet-host-isp", "testnet-routed-isp" ])
        )
        and any($routes[];
          .source == "provider-access-dns"
          and .upstreamSource == "follow-source"
          and .scenario == $scenario
        )
        and any($policy[];
          .source == "provider-access-dns"
          and .upstreamSource == "follow-source"
          and .scenario == $scenario
        )
    ' "${output}" >/dev/null
}

write_inventory_case \
  "${tmp_dir}/inventory-nixos-follow-source.nix" \
  "${hat_dir}/inventory-nixos.nix" \
  'providerTable.pppoeNixos' \
  'providerTable.pppoeClab'

write_inventory_case \
  "${tmp_dir}/inventory-clab-follow-source.nix" \
  "${hat_dir}/inventory-clab.nix" \
  'providerTable.pppoeNixos' \
  'providerTable.pppoeClab'

build_cpm "${tmp_dir}/inventory-nixos-follow-source.nix" "${tmp_dir}/nixos.json"
build_cpm "${tmp_dir}/inventory-clab-follow-source.nix" "${tmp_dir}/clab.json"

assert_follow_source_dns \
  "${tmp_dir}/nixos.json" \
  "site-a" \
  "esp0xdeadbeef-site-a-nixos-access-client" \
  "10.20.20.1" \
  "fd42:dead:beef:20::1" \
  "pppoeNixos"

assert_follow_source_dns \
  "${tmp_dir}/clab.json" \
  "site-b" \
  "esp0xdeadbeef-site-b-clab-access-client" \
  "10.50.20.1" \
  "fd42:dead:feed:20::1" \
  "pppoeClab"

write_inventory_case \
  "${tmp_dir}/inventory-missing-source.nix" \
  "${hat_dir}/inventory-nixos.nix" \
  'providerTable.pppoeNixos // {
    dns = providerTable.pppoeNixos.dns // {
      resolver = builtins.removeAttrs providerTable.pppoeNixos.dns.resolver [ "upstreamSource" ];
    };
  }' \
  'providerTable.pppoeClab'

if build_cpm "${tmp_dir}/inventory-missing-source.nix" "${tmp_dir}/missing-source.json" 2>"${tmp_dir}/missing-source.stderr"; then
  echo "FAIL provider-access-dns-follow-source: missing upstreamSource unexpectedly evaluated" >&2
  exit 1
fi

if ! grep -Fq "provider-access required field 'dns.resolver.upstreamSource' must be present before CPM handoff" "${tmp_dir}/missing-source.stderr"; then
  echo "FAIL provider-access-dns-follow-source: missing upstreamSource diagnostic did not name follow-source source" >&2
  cat "${tmp_dir}/missing-source.stderr" >&2
  exit 1
fi

echo "PASS provider-access-dns-follow-source"
