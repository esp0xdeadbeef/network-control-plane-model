#!/usr/bin/env bash
# GAMP-SCOPE: software-module-test
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/state-contracts-test.sh"
state_assert_true dnsExplicitInputOnly "state dns contracts require explicit dns service input"
