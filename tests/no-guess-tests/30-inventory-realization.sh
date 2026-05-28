#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-NO-GUESS-INVENTORY-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

run_case \
  "link-port-missing-explicit-adapter-name" \
  "inventory.realization.nodes.access-runtime.ports.p2p0.adapterName is required" \
  "$(cat "${golden_input_file}")" \
  "$(mutate_inventory delete \
'            adapterName = "adp-access-runtime-p2p0";
')"

run_case \
  "link-port-adapter-name-must-be-unique-per-host" \
  "inventory.realization.nodes.*.ports.*.adapterName (must be unique per deployment host for link selectors) contains duplicate identities" \
  "$(cat "${golden_input_file}")" \
  "$(mutate_inventory replace \
'            adapterName = "adp-policy-runtime-p2p-access";' \
'            adapterName = "adp-access-runtime-p2p0";')"

run_case \
  "bgp-mode-without-explicit-asn" \
  "bgp mode requires integer 'asn'" \
  "$(cat "${golden_input_file}")" \
  "$(cat <<EOF
let
  base = import ${default_egress_inventory_file};
in
base // {
  controlPlane = {
    sites = {
      acme = {
        ams = {
          routing = {
            mode = "bgp";
            bgp = {
              topology = "policy-rr";
            };
          };
        };
      };
    };
  };
}
EOF
)"

run_case \
  "realized-link-interface-requires-explicit-matching-link" \
  "requires explicit port realization for backing link 'adj::acme.ams::policy-access'" \
  "$(cat "${golden_input_file}")" \
  "$(mutate_inventory delete \
'          p2p0 = {
            link = "link-policy-access";
            adapterName = "adp-access-runtime-p2p0";
            attach = {
              kind = "bridge";
              bridge = "br-transit";
            };
            interface = {
              name = "ens3";
            };
          };
')"

run_case \
  "realized-wan-interface-requires-explicit-upstream-addressing" \
  "requires explicit upstream addressing in inventory.deployment.hosts.hypervisor-a.uplinks.uplink0.ipv4 and/or ipv6" \
  "$(cat "${golden_input_file}")" \
  "$(mutate_inventory delete \
'            ipv4 = {
              method = "dhcp";
            };
            ipv6 = {
              method = "dhcp";
            };
')"

finish_no_guess_tests
