#!/usr/bin/env bash

if [[ "${NETWORK_REPO_SWEEP:-0}" != "1" && "${NETWORK_REPO_DIRECT_TEST_OK:-0}" != "1" ]]; then
  script_name="${BASH_SOURCE[1]:-${0}}"
  echo "FAIL: ${script_name} is a direct repo spot test. Set NETWORK_REPO_DIRECT_TEST_OK=1 for an intentional focused run, or NETWORK_REPO_SWEEP=1 from the locked full network-* sweep." >&2
  exit 1
fi
