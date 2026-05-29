#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-RUNTIME-IFNAME-UNIQUE-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

run_case \
  "runtime-interface-name-must-be-unique-per-target" \
  "inventory.realization.nodes.policy-runtime.ports.*.interface.name (must be unique per realized target) contains duplicate identities" \
  "$(cat "${golden_input_file}")" \
  "$(mutate_inventory replace \
'          p2p-upstream = {
            link = "link-upstream-policy";
            adapterName = "adp-policy-runtime-p2p-upstream";
            attach = {
              kind = "bridge";
              bridge = "br-transit";
            };
            interface = {
              name = "ens5";
            };
          };' \
'          p2p-upstream = {
            link = "link-upstream-policy";
            adapterName = "adp-policy-runtime-p2p-upstream";
            attach = {
              kind = "bridge";
              bridge = "br-transit";
            };
            interface = {
              name = "ens4";
            };
          };')"

finish_no_guess_tests
