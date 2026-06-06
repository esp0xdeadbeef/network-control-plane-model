#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/state-contracts-test.sh"
state_assert_fails invalidDurabilityClassThrows 'statePolicy\.persistence\.durabilityClass' "state invalid durability class diagnostic"
