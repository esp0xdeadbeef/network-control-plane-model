#!/usr/bin/env bash
# GAMP-ID: FS-890-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/state-contracts-test.sh"
state_assert_true operationalRecordIncompleteEvidenceClassification "state operational record incomplete evidence classification"
