#!/usr/bin/env bash
# GAMP-ID: USR-STATE-001-FS-001-HDS-001-SDS-001-001-SMS-001-002
# GAMP-ID: USR-STATE-001-FS-001-HDS-001-SDS-001-001-SMS-001-CMC-001-002
# GAMP-SCOPE: software-module-test
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/state-contracts-test.sh"
state_assert_true dhcp4PersistenceContract "state dhcp4 persistence contract"
