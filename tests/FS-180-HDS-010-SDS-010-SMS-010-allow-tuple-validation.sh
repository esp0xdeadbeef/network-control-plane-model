#!/usr/bin/env bash
set -euo pipefail
# GAMP-ID: FS-180-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
# Construction test for CPM fail-closed modeled allow tuple validation.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
export CPM_REPO_ROOT="${repo_root}"
export CPM_RELATIONS_FILE="${tmpdir}/relations.json"

eval_relations() {
  local relations_json="$1"
  printf '%s' "$relations_json" >"${CPM_RELATIONS_FILE}"
  nix eval --impure --json --expr '
    let
      repoRoot = builtins.getEnv "CPM_REPO_ROOT";
      lib = import (repoRoot + "/lib/utils.nix");
      helpers = import (repoRoot + "/src/cpm/cpm-contract-support.nix") { inherit lib; };
      common = import (repoRoot + "/src/cpm/forwarding-validation/common.nix") { inherit helpers; };
      validator = import (repoRoot + "/src/cpm/forwarding-validation/communication-contract.nix") {
        inherit helpers common;
      };
      relations = builtins.fromJSON (builtins.readFile (builtins.getEnv "CPM_RELATIONS_FILE"));
      site = {
        communicationContract.allowedRelations = relations;
        policy.interfaceTags = { };
        domains = {
          tenants = [ ];
          externals = [ ];
        };
        uplinkNames = [ ];
      };
    in
      validator.validate "forwardingModel.enterprise.test.site.test" site
  '
}

assert_accepts() {
  local label="$1" relations_json="$2"
  local output
  output="$(eval_relations "$relations_json")"
  [[ "$output" == "true" ]] || {
    printf 'FAIL [%s]: expected true, got %s\n' "$label" "$output" >&2
    exit 1
  }
  echo "PASS [${label}]: accepted"
}

assert_rejects() {
  local label="$1" relations_json="$2" expected="$3"
  local output status
  set +e
  output="$(eval_relations "$relations_json" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    printf 'FAIL [%s]: invalid allow tuple was accepted: %s\n' "$label" "$output" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    printf 'FAIL [%s]: expected diagnostic %q\n%s\n' "$label" "$expected" "$output" >&2
    exit 1
  fi
  echo "PASS [${label}]: rejected with diagnostic containing \"${expected}\""
}

assert_accepts "explicit one-way" \
  '[{"id":"explicit-one-way","action":"allow","from":"any","to":"any","returnBehavior":"one-way"}]'
assert_accepts "explicit symmetric" \
  '[{"id":"explicit-symmetric","action":"allow","from":"any","to":"any","returnBehavior":"symmetric"}]'
assert_accepts "nested stateful return" \
  '[{"id":"nested-stateful","action":"allow","from":"any","to":"any","publicIngressTupleAuthority":{"returnBehavior":"stateful-return"}}]'
assert_accepts "matching top-level and nested authority" \
  '[{"id":"matching-stateful","action":"allow","from":"any","to":"any","returnBehavior":"stateful-return","publicIngressTupleAuthority":{"returnBehavior":"stateful-return"}}]'
assert_accepts "deny without return behavior" \
  '[{"id":"explicit-deny","action":"deny","from":"any","to":"any"}]'

assert_rejects "missing return behavior" \
  '[{"id":"missing-return","action":"allow","from":"any","to":"any"}]' \
  "allow relation 'missing-return' is missing required returnBehavior"
assert_rejects "implicit allow missing return behavior" \
  '[{"id":"implicit-allow","from":"any","to":"any"}]' \
  "allow relation 'implicit-allow' is missing required returnBehavior"
assert_rejects "empty top-level return behavior" \
  '[{"id":"empty-return","action":"allow","from":"any","to":"any","returnBehavior":""}]' \
  "allow relation 'empty-return' has an invalid top-level returnBehavior"
assert_rejects "empty nested return behavior" \
  '[{"id":"empty-nested","action":"allow","from":"any","to":"any","publicIngressTupleAuthority":{"returnBehavior":""}}]' \
  "allow relation 'empty-nested' has an invalid publicIngressTupleAuthority.returnBehavior"
assert_rejects "conflicting return behavior" \
  '[{"id":"conflicting-return","action":"allow","from":"any","to":"any","returnBehavior":"symmetric","publicIngressTupleAuthority":{"returnBehavior":"stateful-return"}}]' \
  "allow relation 'conflicting-return' has conflicting returnBehavior values 'symmetric' and 'stateful-return'"

echo "PASS FS-180-HDS-010-SDS-010-SMS-010 allow-tuple validation"
