#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-RUNTIME-IFNAME-LINUX-COMPATIBLE-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

run_case \
  "linux-runtime-interface-name-must-be-realizable" \
  "linux target platform 'linux' requires a runtime interface name matching ^[A-Za-z0-9_.-]{1,15}$" \
  "$(cat "${golden_input_file}")" \
  "$(mutate_inventory replace \
'              name = "ens3";' \
'              name = "abcdefghijklmnop";')"

finish_no_guess_tests
