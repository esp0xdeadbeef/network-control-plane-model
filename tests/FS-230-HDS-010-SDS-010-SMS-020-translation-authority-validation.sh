#!/usr/bin/env bash
set -euo pipefail
# GAMP-ID: FS-230-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
# Construction test: CPM consumes and preserves the explicit public-ingress
# translation decision, failing closed on invalid/unrecognized/ambiguous
# translation fields before policy evaluation.

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
    printf 'FAIL [%s]: invalid translation authority was accepted: %s\n' "$label" "$output" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    printf 'FAIL [%s]: expected diagnostic %q\n%s\n' "$label" "$expected" "$output" >&2
    exit 1
  fi
  echo "PASS [${label}]: rejected with diagnostic containing \"${expected}\""
}

# Explicit no-translation decision is consumed and preserved (accepted).
assert_accepts "no-translation decision" \
  '[{"id":"none-decision","action":"allow","from":"any","to":"any","publicIngressTupleAuthority":{"returnBehavior":"stateful-return","translationMode":"none","sourcePreservation":"preserve-source"}}]'
# Translation-capable mode with explicit source binding is accepted.
assert_accepts "napt translation contract" \
  '[{"id":"napt-decision","action":"allow","from":"any","to":"any","publicIngressTupleAuthority":{"returnBehavior":"stateful-return","translationMode":"napt","sourcePreservation":"rewritten"}}]'
assert_accepts "provider-port-forward translation contract" \
  '[{"id":"ppf-decision","action":"allow","from":"any","to":"any","publicIngressTupleAuthority":{"returnBehavior":"stateful-return","translationMode":"provider-port-forward","sourcePreservation":"provider-napt"}}]'
# Relations with no public-ingress translation authority are unaffected.
assert_accepts "no translation authority" \
  '[{"id":"plain-allow","action":"allow","from":"any","to":"any","returnBehavior":"one-way"}]'

# Seeded negatives: fail closed before policy evaluation.
assert_rejects "unrecognized translationMode" \
  '[{"id":"bad-mode","action":"allow","from":"any","to":"any","publicIngressTupleAuthority":{"returnBehavior":"stateful-return","translationMode":"hairpin-magic","sourcePreservation":"rewritten"}}]' \
  "allow relation 'bad-mode' has an unrecognized publicIngressTupleAuthority.translationMode 'hairpin-magic'"
assert_rejects "empty translationMode" \
  '[{"id":"empty-mode","action":"allow","from":"any","to":"any","publicIngressTupleAuthority":{"returnBehavior":"stateful-return","translationMode":"","sourcePreservation":"rewritten"}}]' \
  "allow relation 'empty-mode' has an invalid publicIngressTupleAuthority.translationMode"
assert_rejects "translation without sourcePreservation" \
  '[{"id":"ambiguous-source","action":"allow","from":"any","to":"any","publicIngressTupleAuthority":{"returnBehavior":"stateful-return","translationMode":"napt"}}]' \
  "allow relation 'ambiguous-source' requests translationMode 'napt' without an explicit publicIngressTupleAuthority.sourcePreservation"
assert_rejects "unrecognized sourcePreservation" \
  '[{"id":"bad-preservation","action":"allow","from":"any","to":"any","publicIngressTupleAuthority":{"returnBehavior":"stateful-return","translationMode":"napt","sourcePreservation":"maybe"}}]' \
  "allow relation 'bad-preservation' has an unrecognized publicIngressTupleAuthority.sourcePreservation 'maybe'"

echo "PASS FS-230-HDS-010-SDS-010-SMS-020 translation-authority validation"
