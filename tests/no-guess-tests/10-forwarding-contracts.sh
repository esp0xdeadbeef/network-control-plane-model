#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-NO-GUESS-FORWARDING-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

run_case \
  "missing-explicit-runtime-target-realization" \
  "inventory.nix must explicitly realize every control_plane_model runtime target" \
  "$(cat "${golden_input_file}")" \
  '{}'

run_case_from_golden \
  "pair-based-transit-ordering" \
  "transit.ordering must contain only stable adjacency IDs" \
  replace \
  '            ordering = [
              "adj::acme.ams::core-upstream"
              "adj::acme.ams::upstream-policy"
              "adj::acme.ams::policy-access"
            ];' \
  '            ordering = [
              [ "core-1" "upstream-1" ]
              [ "upstream-1" "policy-1" ]
              [ "policy-1" "access-1" ]
            ];'

run_case_from_golden \
  "missing-transit-adjacency-id" \
  "transit.adjacencies[0].id is required" \
  delete \
  '                id = "adj::acme.ams::core-upstream";
'

run_case_from_golden \
  "missing-link-id" \
  "links.link-core-upstream.id is required" \
  delete \
  '              id = "adj::acme.ams::core-upstream";
'

run_case_from_golden \
  "adjacency-link-id-mismatch" \
  "does not match links.link-core-upstream.id" \
  replace \
  '                id = "adj::acme.ams::core-upstream";' \
  '                id = "adj::acme.ams::wrong-core-upstream";'

finish_no_guess_tests
