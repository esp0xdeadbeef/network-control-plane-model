#!/usr/bin/env bash
# GAMP-ID: USR-STATE-001-FS-001-HDS-001-SDS-001-005-SMS-001-001
# GAMP-ID: USR-STATE-001-FS-001-HDS-001-SDS-001-005-SMS-001-CMC-001-001
# GAMP-SCOPE: software-module-test
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/state-contracts-test.sh"
state_assert_true dhcp4OperationalRecordContract "state dhcp4 operational record contract"
