#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-020-SMS-030
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

hat_dir="/home/deadbeef/github/network-labs/HAT/emulated-isp-residential-testnet"
intent_path="${hat_dir}/intent.nix"
inventory_path="${hat_dir}/inventory-nixos.nix"

build_cpm() {
  local inventory="$1"
  local output="$2"

  nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory}" \
    "${output}" >/dev/null
}

write_inventory_case() {
  local path="$1"
  local mutation="$2"

  cat >"${path}" <<EOF
let
  base = import ${inventory_path};
  nodes = base.realization.nodes;
  updateNode = name: attrs:
    nodes.\${name} // attrs;
in
base
// {
  realization = base.realization // {
    nodes = nodes // {
      ${mutation}
    };
  };
}
EOF
}

expect_failure() {
  local name="$1"
  local inventory="$2"
  local expected="$3"
  local stderr_path="${tmp_dir}/${name}.stderr"

  if build_cpm "${inventory}" "${tmp_dir}/${name}.json" 2>"${stderr_path}"; then
    echo "FAIL provider-access-pppoe-negative-contract: ${name} unexpectedly evaluated" >&2
    exit 1
  fi

  if ! grep -Fq "${expected}" "${stderr_path}"; then
    echo "FAIL provider-access-pppoe-negative-contract: ${name} missing diagnostic" >&2
    echo "expected substring: ${expected}" >&2
    cat "${stderr_path}" >&2
    exit 1
  fi
}

build_cpm "${inventory_path}" "${tmp_dir}/positive.json"

write_inventory_case "${tmp_dir}/provider-only.nix" '
      esp0xdeadbeef-site-a-nixos-core-testnet-host-isp =
        updateNode "esp0xdeadbeef-site-a-nixos-core-testnet-host-isp" {
          services = { };
        };
'

write_inventory_case "${tmp_dir}/customer-only.nix" '
      esp0xdeadbeef-site-a-nixos-provider-handoff-access-a =
        updateNode "esp0xdeadbeef-site-a-nixos-provider-handoff-access-a" {
          services = { };
        };
'

write_inventory_case "${tmp_dir}/opaque-pppoe-like.nix" '
      esp0xdeadbeef-site-a-nixos-provider-handoff-access-a =
        updateNode "esp0xdeadbeef-site-a-nixos-provider-handoff-access-a" {
          services = {
            pppoe = {
              like = nodes.esp0xdeadbeef-site-a-nixos-provider-handoff-access-a.services.pppoe.server;
            };
          };
        };
'

write_inventory_case "${tmp_dir}/fallback-enabled.nix" '
      esp0xdeadbeef-site-a-nixos-provider-handoff-access-a =
        updateNode "esp0xdeadbeef-site-a-nixos-provider-handoff-access-a" {
          advertisements =
            nodes.esp0xdeadbeef-site-a-nixos-provider-handoff-access-a.advertisements
            // {
              dhcp4 = {
                tenant-provider-handoff-a = {
                  dnsServers = [ "router-self" ];
                  domain = "provider.invalid.";
                  enabled = true;
                };
              };
              ipv6Ra = {
                tenant-provider-handoff-a = {
                  dnssl = [ "provider.invalid." ];
                  enabled = true;
                  rdnss = [ "router-self" ];
                };
              };
            };
        };
'

expect_failure \
  "provider-only" \
  "${tmp_dir}/provider-only.nix" \
  "PPPoE interface 'p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a' requires exactly one client and one server before renderer handoff"

expect_failure \
  "customer-only" \
  "${tmp_dir}/customer-only.nix" \
  "PPPoE interface 'p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a' requires exactly one client and one server before renderer handoff"

expect_failure \
  "opaque-pppoe-like" \
  "${tmp_dir}/opaque-pppoe-like.nix" \
  "services.pppoe: must contain only 'client' or 'server' roles"

expect_failure \
  "fallback-enabled" \
  "${tmp_dir}/fallback-enabled.nix" \
  "PPPoE server targets must explicitly disable DHCP4 and IPv6 RA/SLAAC fallback before renderer handoff"

echo "PASS provider-access-pppoe-negative-contract"
