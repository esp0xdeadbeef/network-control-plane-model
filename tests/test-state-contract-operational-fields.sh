#!/usr/bin/env bash
# GAMP-ID: FS-890-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/state-contracts-test.sh"
state_assert_true operationalRecordContextFields "state operational record context fields"
