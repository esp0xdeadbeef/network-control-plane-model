#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-030-SDS-030-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

sat_dir="/home/deadbeef/github/network-labs/sat"
intent_path="${sat_dir}/intent.nix"
inventory_path="${sat_dir}/inventory.nix"
provider_table_path="${sat_dir}/provider-access-fixture-table.nix"

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
  providerTable = import ${provider_table_path};
  baseNodes = base.realization.nodes;
  withPPPoEContract = nodes':
    let
      scenarios = base.controlPlane.providerAccess.scenarios;
      attachScenario = scenarioName: fixture: acc:
        let
          scenario = scenarios.\${scenarioName};
          runtime = scenario.runtime;
          handoff = runtime.handoff;
          server = runtime.servicePlacement.server;
          client = runtime.servicePlacement.client;
          credentials = scenario.credentials;
          serverNode = acc.\${server.node};
          clientNode = acc.\${client.node};
        in
        acc // {
          \${server.node} = serverNode // {
            advertisements = (serverNode.advertisements or { }) // {
              dhcp4 = {
                \${handoff.providerInterface} = {
                  enabled = false;
                };
              };
              ipv6Ra = {
                \${handoff.providerInterface} = {
                  enabled = false;
                };
              };
            };
            services = (serverNode.services or { }) // {
              pppoe = {
                server = {
                  inherit credentials;
                  customerAddress = fixture.publicFacing.ipv4.customerAddress;
                  implementation = scenario.accessConcentrator.implementation;
                  interface = handoff.link;
                  maxSessions = 32;
                  mtu = scenario.substrate.mtu;
                  providerAddress = fixture.publicFacing.ipv4.providerAddress;
                };
              };
            };
          };
          \${client.node} = clientNode // {
            services = (clientNode.services or { }) // {
              pppoe = {
                client = {
                  inherit credentials;
                  defaultRoute = client.defaultRoute;
                  interface = handoff.link;
                  mtu = scenario.substrate.mtu;
                  runtimeInterface = client.runtimeInterface;
                  usePeerDns = client.usePeerDns;
                };
              };
            };
          };
        };
    in
    attachScenario "pppoeClab" providerTable.pppoeClab
      (attachScenario "pppoeNixos" providerTable.pppoeNixos nodes');
  nodes = withPPPoEContract baseNodes;
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

write_inventory_case "${tmp_dir}/positive.nix" ""
build_cpm "${tmp_dir}/positive.nix" "${tmp_dir}/positive.json"

write_inventory_case "${tmp_dir}/provider-only.nix" '
      esp-nixos-router-core-isp-a =
        updateNode "esp-nixos-router-core-isp-a" {
          services = { };
        };
'

write_inventory_case "${tmp_dir}/customer-only.nix" '
      esp-nixos-router-upstream =
        updateNode "esp-nixos-router-upstream" {
          services = { };
        };
'

write_inventory_case "${tmp_dir}/opaque-pppoe-like.nix" '
      esp-nixos-router-upstream =
        updateNode "esp-nixos-router-upstream" {
          services = {
            pppoe = {
              like = {
                interface = "sat-pppoe-nixos-handoff";
              };
            };
          };
        };
'

write_inventory_case "${tmp_dir}/fallback-enabled.nix" '
      esp-nixos-router-upstream =
        updateNode "esp-nixos-router-upstream" {
          advertisements =
            (nodes.esp-nixos-router-upstream.advertisements or { })
            // {
              dhcp4 = {
                pppoe-server = {
                  dnsServers = [ "router-self" ];
                  domain = "provider.invalid.";
                  enabled = true;
                };
              };
              ipv6Ra = {
                pppoe-server = {
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
  "FS-800-HDS-030-SDS-030-SMS-010: PPPoE interface 'sat-pppoe-nixos-handoff' requires exactly one client and one server before renderer handoff"

expect_failure \
  "customer-only" \
  "${tmp_dir}/customer-only.nix" \
  "FS-800-HDS-030-SDS-030-SMS-010: PPPoE interface 'sat-pppoe-nixos-handoff' requires exactly one client and one server before renderer handoff"

expect_failure \
  "opaque-pppoe-like" \
  "${tmp_dir}/opaque-pppoe-like.nix" \
  "FS-800-HDS-030-SDS-030-SMS-010: must contain only 'client' or 'server' roles"

expect_failure \
  "fallback-enabled" \
  "${tmp_dir}/fallback-enabled.nix" \
  "FS-800-HDS-030-SDS-030-SMS-010: PPPoE server targets must explicitly disable DHCP4 and IPv6 RA/SLAAC fallback before renderer handoff"

echo "PASS provider-access-pppoe-negative-contract"
