#!/usr/bin/env bash
# GAMP-SCOPE: software-module-test
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/state-contracts-test.sh"
state_assert_true dhcp4ExplicitInputOnly "state dhcp4 lease contracts require explicit input"
