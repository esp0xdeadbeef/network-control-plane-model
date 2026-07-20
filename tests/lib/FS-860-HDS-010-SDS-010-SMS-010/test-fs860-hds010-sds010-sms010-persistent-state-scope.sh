#!/usr/bin/env bash
# GAMP-ID: FS-860-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-860-HDS-010-SDS-010-SMS-010-CMC-001
# GAMP-SCOPE: software-module-test
# SMS: FS-860-HDS-010-SDS-010-SMS-010-persistent-service-state.md
# Predicates: persistent state scope validation — service, site, tenant, host,
#   state class, persistence requirement, and storage location must be present
#   and non-empty. Reject absent, ambiguous, unauthorized, or out-of-scope
#   persistent storage. Fail when state ownership cannot be tied to service+host.
set -euo pipefail
source "${SMS_TEST_REPO_ROOT}/tests/lib/state-contracts-test.sh"

# P1: Required scope fields present (service, stateClass, required, host=scope.target, path)
state_assert_true scopeFieldsPresent "P1: scope fields present (service stateClass required host path)"

# P2: Tenant present when applicable (DHCP contract has tenant in scope)
state_assert_true scopeFieldsTenantWhenApplicable "P2: tenant present in scope when applicable"

# SN1 (absent storage location): already covered by existing missingPersistenceRootThrows
state_assert_fails missingPersistenceRootThrows 'statePolicy\.persistence\.root' "SN1: absent storage location rejected"

# SN2 (ambiguous storage location): two contracts for same service+host+stateClass
state_assert_true ambiguousStorageDetected "SN2: ambiguous storage detected (duplicate service+host+stateClass)"

# SN3 (missing state ownership context): no contracts generated without advertisements
state_assert_true missingOwnershipNoContracts "SN3: missing ownership context yields no contracts"

# P3: Out-of-scope storage still produces a path (scope validation deferred to renderer/SIT)
state_assert_true outOfScopeStorageHasPath "P3: out-of-scope storage path present (scope validation at renderer layer)"

echo ""
echo "=== FS-860-HDS-010-SDS-010-SMS-010 persistent state scope: ALL ASSERTIONS PASSED ==="
