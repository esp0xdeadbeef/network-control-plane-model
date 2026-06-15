#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-020-SMS-030
# GAMP-SCOPE: software-module-test
# Focused CMC construction test: PPPoE pairing fallback rejection with SAT
# fixture mutations. Proves the CPM rejects:
#   SN1: missing-handoff (mismatched interface → unpaired)
#   SN2: wrong-address (null customerAddress in server config)
#   SN3: missing-credentials (empty credentials attrset)
#   SN4: killswitch-bypass (DHCP/SLAAC fallback not explicitly disabled)
#   PC: positive control (valid paired PPPoE compiles)
#
# SMS-030 Acceptance Predicates (FS-800-HDS-010-SDS-020-SMS-030):
#   - Reject provider-only / customer-only / unpaired PPPoE rows
#   - Reject opaque PPPoE-like service roles
#   - Reject fallback-enabled DHCP/SLAAC on PPPoE servers
#   - Distinguish missing-provider, missing-customer, ambiguous, opaque, fallback
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

sat_dir="$(pinned_sat_dir)"
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
    echo "FAIL sat-pppoe-pairing-fallback-rejection: ${name} unexpectedly evaluated" >&2
    exit 1
  fi

  if ! grep -Fq "${expected}" "${stderr_path}"; then
    echo "FAIL sat-pppoe-pairing-fallback-rejection: ${name} missing diagnostic" >&2
    echo "expected substring: ${expected}" >&2
    cat "${stderr_path}" >&2
    exit 1
  fi
}

# ── Positive control: valid paired PPPoE compiles ──
echo "--- PC: valid paired PPPoE (positive control) ---"
write_inventory_case "${tmp_dir}/positive.nix" ""
build_cpm "${tmp_dir}/positive.nix" "${tmp_dir}/positive.json"
echo "PASS: positive control — valid PPPoE pairing compiles"

# ── SN1: missing-handoff — mismatched interface names → unpaired rejection ──
echo "--- SN1: missing-handoff (mismatched server/client interfaces) ---"
write_inventory_case "${tmp_dir}/sn1-missing-handoff.nix" '
      esp-nixos-router-core-isp-a =
        updateNode "esp-nixos-router-core-isp-a" {
          services = (nodes.esp-nixos-router-core-isp-a.services or { }) // {
            pppoe = {
              client = (nodes.esp-nixos-router-core-isp-a.services.pppoe.client or { }) // {
                interface = "sat-pppoe-nixos-handoff-MISMATCHED";
              };
            };
          };
        };
'
expect_failure \
  "sn1-missing-handoff" \
  "${tmp_dir}/sn1-missing-handoff.nix" \
  "FS-800-HDS-010-SDS-020-SMS-030: PPPoE interface '"

# ── SN2: wrong-address — null customerAddress in server config ──
echo "--- SN2: wrong-address (null customerAddress) ---"
write_inventory_case "${tmp_dir}/sn2-wrong-address.nix" '
      esp-nixos-router-upstream =
        updateNode "esp-nixos-router-upstream" {
          services = (nodes.esp-nixos-router-upstream.services or { }) // {
            pppoe = {
              server = (nodes.esp-nixos-router-upstream.services.pppoe.server or { }) // {
                customerAddress = null;
              };
            };
          };
        };
'
expect_failure \
  "sn2-wrong-address" \
  "${tmp_dir}/sn2-wrong-address.nix" \
  "customerAddress is required"

# ── SN3: missing-credentials — empty credentials attrset ──
echo "--- SN3: missing-credentials (empty credentials {}) ---"
write_inventory_case "${tmp_dir}/sn3-missing-credentials.nix" '
      esp-nixos-router-upstream =
        updateNode "esp-nixos-router-upstream" {
          services = (nodes.esp-nixos-router-upstream.services or { }) // {
            pppoe = {
              server = (nodes.esp-nixos-router-upstream.services.pppoe.server or { }) // {
                credentials = { };
              };
            };
          };
        };
'
expect_failure \
  "sn3-missing-credentials" \
  "${tmp_dir}/sn3-missing-credentials.nix" \
  "must define username/password or usernameFile/passwordFile"

# ── SN4: killswitch-bypass — DHCP/SLAAC fallback not explicitly disabled ──
echo "--- SN4: killswitch-bypass (DHCP/SLAAC not disabled) ---"
write_inventory_case "${tmp_dir}/sn4-killswitch-bypass.nix" '
      esp-nixos-router-upstream =
        updateNode "esp-nixos-router-upstream" {
          advertisements = { };
        };
'
expect_failure \
  "sn4-killswitch-bypass" \
  "${tmp_dir}/sn4-killswitch-bypass.nix" \
  "FS-800-HDS-010-SDS-020-SMS-030: PPPoE server targets must explicitly disable DHCP4 and IPv6 RA/SLAAC fallback before renderer handoff"

echo ""
echo "PASS: FS-800-HDS-010-SDS-020-SMS-030-sat-pppoe-pairing-fallback-rejection (4/4 seeded negatives + positive control)"
