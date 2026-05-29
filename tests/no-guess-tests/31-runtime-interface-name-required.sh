#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-RUNTIME-IFNAME-REQUIRED-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

run_case \
  "runtime-interface-name-is-required" \
  "inventory.realization.nodes.access-runtime.ports.p2p0.interface.name is required" \
  "$(cat "${golden_input_file}")" \
  "$(mutate_inventory delete \
'              name = "ens3";
')"

finish_no_guess_tests
