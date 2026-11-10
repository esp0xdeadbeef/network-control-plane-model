#!/usr/bin/env bash
# GAMP-ID: FS-470-HDS-010-SDS-010-SMS-090
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-470-HDS-010-SDS-010-SMS-090.md
# OWNER:  network-control-plane-model
#
# Predicates: derive each WireGuard overlay's tunnel MTU from the overlay
# declaration, and bind that MTU onto the access advertisements of the matching
# source access scope. The MTU must come from the upstream/tunnel interface, never
# from a client-side route or a hardcoded constant.
# Not executed before commit.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

fail() { echo "FAIL wireguard-mtu-binding: $*" >&2; exit 1; }

search=( "${repo_root}/src/cpm" )

if ! grep -rqiE 'wireguard' "${search[@]}" --include=*.nix 2>/dev/null; then
  fail "P1 no WireGuard overlay surface exists, so a tunnel MTU cannot be derived"
fi

# P1: the tunnel MTU must be derived from the overlay declaration.
if ! grep -rqiE 'tunnelMtu|overlay.*mtu|mtu.*overlay' "${search[@]}" --include=*.nix 2>/dev/null; then
  fail "P1 no tunnel MTU derivation from the overlay declaration exists"
fi

# P2: the MTU must be bound onto access advertisements.
if ! grep -rqiE 'advertisements?' "${search[@]}" --include=*.nix 2>/dev/null; then
  fail "P2 no access-advertisement surface exists to bind the MTU onto"
fi

# P3: the MTU must not be a hardcoded constant or take the client-side route as
# its source. A literal MTU is the defect the FS names.
if grep -rqE 'mtu\s*=\s*[0-9]{3,5}\s*;' "${search[@]}" --include=*.nix 2>/dev/null; then
  fail "P3 a hardcoded MTU literal exists; the MTU must derive from the upstream/tunnel interface"
fi

echo "PASS wireguard-mtu-binding"
