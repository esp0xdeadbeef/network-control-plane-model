#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/state-contracts-test.sh"
state_assert_true restartTolerantPersistenceContract "state durability class separation"
