#!/usr/bin/env bash
# GAMP-ID: FS-870-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/state-contracts-test.sh"

state_assert_true explicitEphemeralContract "FS-870 explicit ephemeral contract"
state_assert_true restartTolerantPersistenceContract "FS-870 restart-tolerant durability contract"
state_assert_true persistentSummaryNotEphemeral "FS-870 persistent summary is not silently ephemeral"
state_assert_fails invalidDurabilityClassThrows 'durabilityClass' "FS-870 invalid durability class diagnostic"

echo "PASS FS-870-HDS-010-SDS-010-SMS-010 ephemeral state selection"
