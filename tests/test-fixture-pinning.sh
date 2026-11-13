#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-FIXTURE-PINNING-001
# GAMP-SCOPE: software-module-test
#
# Predicates: this repository's tests resolve their fixtures from the pinned
# flake inputs, and those pins are recorded in a tracked `flake.lock`.
#
# The goal this row exists for: "network-* repositories should not reference the
# `nixos` repository, and tests should pin (with flake.lock, and flake.nix
# follows without pins, so `nix flake update` will update the locks) the required
# network-* repositories."
#
# Three separate ways that can rot, each asserted here:
#
#   1. the lock stops being tracked, so CI resolves `main` at run time and a red
#      run cannot be reproduced;
#   2. the lock stops naming the fixtures the tests read, so a checkout happens
#      to pass while CI fails;
#   3. a test reintroduces a path into the `nixos` consumer repository.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
require_cmd git
require_cmd jq

fail() { echo "FAIL fixture-pinning: $*" >&2; exit 1; }

# P1: flake.lock is tracked. A gitignored lock means the pins live only on
# whichever machine ran `nix flake lock` last.
if ! git -C "${repo_root}" ls-files --error-unmatch flake.lock >/dev/null 2>&1; then
  fail "P1 flake.lock is not tracked, so the sibling input revisions are not pinned"
fi

# P1: flake.lock exists on disk and parses.
lock="${repo_root}/flake.lock"
[[ -f "${lock}" ]] || fail "P1 flake.lock is tracked but absent from the checkout"
jq -e . "${lock}" >/dev/null 2>&1 || fail "P1 flake.lock is not valid JSON"

# P2: the lock names the two inputs the fixtures come from, at a recorded
# revision. `network-labs` supplies every example the cases compile;
# `network-forwarding-model` and the compiler it follows supply the model.
for input in network-labs network-forwarding-model; do
  rev="$(jq -r --arg n "${input}" '.nodes[$n].locked.rev // ""' "${lock}")"
  if [[ -z "${rev}" ]]; then
    fail "P2 flake.lock records no revision for '${input}', so its checkout is unpinned"
  fi
  if [[ ! "${rev}" =~ ^[0-9a-f]{40}$ ]]; then
    fail "P2 flake.lock revision for '${input}' is not a full commit hash: ${rev}"
  fi
done

# P2: no case reads a path into the `nixos` consumer repository. That repository
# consumes these ones; a fixture read from it inverts the layering and cannot be
# satisfied on a runner that does not check it out.
# The checker itself names the pattern, so exclude it from its own scan.
nixos_refs="$(grep -rl 'nixos/prod-network' "${repo_root}/tests" 2>/dev/null \
  | grep -v 'test-fixture-pinning.sh$' || true)"
if [[ -n "${nixos_refs}" ]]; then
  echo "FAIL fixture-pinning: P2 tests read fixtures from the nixos consumer repository:" >&2
  printf '  %s\n' ${nixos_refs} >&2
  fail "P2 a test reads a fixture from the nixos consumer repository"
fi

# P2: and no test tells a reader to point at it via the retired NIXOS_SRC knob.
nixos_env="$(grep -rn 'NIXOS_SRC' "${repo_root}/tests" 2>/dev/null \
  | grep -v 'test-fixture-pinning.sh:' || true)"
if [[ -n "${nixos_env}" ]]; then
  echo "FAIL fixture-pinning: P2 NIXOS_SRC still appears under tests/:" >&2
  printf '  %s\n' ${nixos_env} >&2
  fail "P2 NIXOS_SRC still appears under tests/, so a reader is sent to the consumer repo"
fi

# SN1: the tracked-lock check must reject an untracked lock. Evaluate the same
# predicate against a file that is not under git.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
git -C "${tmp_dir}" init -q
: >"${tmp_dir}/flake.lock"
if git -C "${tmp_dir}" ls-files --error-unmatch flake.lock >/dev/null 2>&1; then
  fail "SN1 the tracked-lock predicate accepted an untracked flake.lock"
fi

# SN2: the revision predicate must reject a missing input rather than pass on an
# empty string.
if jq -e --arg n "not-an-input" '.nodes[$n].locked.rev // "" | length > 0' "${lock}" >/dev/null 2>&1; then
  fail "SN2 the revision predicate accepted an input the lock does not record"
fi

echo "PASS fixture-pinning"
