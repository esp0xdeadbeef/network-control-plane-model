#!/usr/bin/env bash
# GAMP-ID: FS-770-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd diff
require_cmd jq
require_cmd nix

hat_dir="$(pinned_hat_dir)"
intent_path="${hat_dir}/intent.nix"
inventory_nixos="${hat_dir}/inventory-nixos.nix"
inventory_clab="${hat_dir}/inventory-clab.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

nixos_output="${tmp_dir}/cpm-nixos.json"
clab_output="${tmp_dir}/cpm-clab.json"

build_cpm() {
  local inventory="$1"
  local output="$2"

  nix run \
    --no-write-lock-file \
    --extra-experimental-features 'nix-command flakes' \
    "${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory}" \
    "${output}" >/dev/null
}

# ── Canonicalization jq filter ───────────────────────────────────
# Strips profile-specific realization detail, normalizing the output
# so that NixOS and CLAB profiles produce identical common-intent JSON.
canonical_filter='
# Recursively normalize profile-specific strings in values
def normalize_profile_strings:
  if type == "string" then
    . | sub("nixos"; "common"; "g")
      | sub("clab"; "common"; "g")
      | sub("site-a"; "site-common"; "g")
      | sub("site-b"; "site-common"; "g")
  elif type == "object" then
    with_entries(.value |= normalize_profile_strings)
  elif type == "array" then map(normalize_profile_strings)
  else . end;

def normalize_bridges:
  if type == "object" then
    with_entries(
      if .value | type == "string" then
        if (.key | test("bridge$"; "i")) then
          .value = (.value
            | sub("^stub-nixos-"; "")
            | sub("^stub-clab-"; ""))
        else . end
      else . end
    )
    | map_values(normalize_bridges)
  elif type == "array" then map(normalize_bridges)
  else . end;

def drop_vlans:
  if type == "object" then
    del(.vlan)
    | map_values(drop_vlans)
  elif type == "array" then map(drop_vlans)
  else . end;

def drop_runtime_targets:
  if type == "object" then
    del(.runtimeTargets)
    | map_values(drop_runtime_targets)
  elif type == "array" then map(drop_runtime_targets)
  else . end;

# Endpoint assignments carry per-profile fixture address delivery and
# validation diagnostics; FS-720 owns their exact contract.
def drop_endpoint_assignment:
  if type == "object" then
    del(.endpointAssignment)
    | del(.endpointAssignmentCheck)
    | map_values(drop_endpoint_assignment)
  elif type == "array" then map(drop_endpoint_assignment)
  else . end;

def normalize_data_keys:
  if type == "object" then
    with_entries(
      .key |= (sub("-nixos-"; "-common-") | sub("-clab-"; "-common-"))
      | .value |= normalize_data_keys
    )
  elif type == "array" then map(normalize_data_keys)
  else . end;

def drop_deployment:
  if type == "object" then
    del(.effectiveRuntimeRealization)
    | del(.deploymentRecord)
    | del(.deploymentTarget)
    | map_values(drop_deployment)
  elif type == "array" then map(drop_deployment)
  else . end;

.control_plane_model
| {
    data: (.data | normalize_data_keys | drop_runtime_targets | drop_deployment | drop_endpoint_assignment | normalize_bridges | drop_vlans),
    meta: .meta,
    version: .version,
    secretDeclarations: (.secretDeclarations // []),
    secretSources: (.secretSources // []),
    sourceBindings: (.sourceBindings // []),
    secretDeliveryRecords: (.secretDeliveryRecords // []),
    secretPolicyBoundary: (.secretPolicyBoundary // {}),
    secretAuthorization: (.secretAuthorization // {}),
    secretReadiness: (.secretReadiness // {}),
    secretPlaintextGuard: (.secretPlaintextGuard // {})
  }
| normalize_profile_strings
'

canonicalize() {
  local input="$1"
  local output="$2"
  jq "${canonical_filter}" "${input}" > "${output}"
}

# ── Main test ────────────────────────────────────────────────────
echo "--- Building CPM outputs ---"
build_cpm "${inventory_nixos}" "${nixos_output}"
build_cpm "${inventory_clab}" "${clab_output}"

# ── Seeded Negative 1: Raw diff (NO canonicalization) ──
# Without canonicalization the outputs MUST differ because of
# profile-specific bridge names, VLANs, and runtime targets.
# This proves the gap that canonicalization fills.
echo "--- Seeded Negative: raw diff (no canonicalization) ---"
raw_diff_lines=0
diff <(jq -S . "${nixos_output}") <(jq -S . "${clab_output}") > "${tmp_dir}/raw-diff.txt" 2>&1 && raw_identical=true || raw_identical=false

if [[ "${raw_identical}" == "true" ]]; then
  echo "FAIL: seeded negative — raw CPM outputs are unexpectedly identical" >&2
  echo "  Without canonicalization, profile-specific fields SHOULD differ" >&2
  exit 1
fi
raw_diff_lines=$(wc -l < "${tmp_dir}/raw-diff.txt")
echo "PASS: raw diff is non-empty (${raw_diff_lines} lines) — gap exists without canonicalization"

# ── Canonicalize ──
echo "--- Canonicalizing outputs ---"
canonicalize "${nixos_output}" "${tmp_dir}/nixos-canon.json"
canonicalize "${clab_output}" "${tmp_dir}/clab-canon.json"

nixos_size=$(wc -c < "${tmp_dir}/nixos-canon.json")
clab_size=$(wc -c < "${tmp_dir}/clab-canon.json")
echo "  nixos canonicalized: ${nixos_size} bytes"
echo "  clab canonicalized:  ${clab_size} bytes"

# ── Canonicalized equivalence check ──
echo "--- Diff canonicalized outputs ---"
if diff <(jq -S . "${tmp_dir}/nixos-canon.json") <(jq -S . "${tmp_dir}/clab-canon.json") > "${tmp_dir}/canon-diff.txt" 2>&1; then
  echo "PASS: canonicalized CPM outputs are identical"
  echo "  Cross-profile equivalence: NixOS == CLAB from same intent"
else
  diff_lines=$(wc -l < "${tmp_dir}/canon-diff.txt")
  echo "FAIL: canonicalized CPM outputs differ (${diff_lines} lines)" >&2
  echo "--- First 60 diff lines ---" >&2
  head -60 "${tmp_dir}/canon-diff.txt" >&2
  exit 1
fi

# ── Common-intent field presence check ──
echo "--- Common-intent field presence check ---"
jq -e '
  .data.esp0xdeadbeef["site-a"]
  | has("policy")
    and has("relations")
    and has("services")
    and has("forwardingSemantics")
    and has("routing")
    and has("overlays")
    and has("communicationContract")
    and has("rendererContracts")
    and has("domains")
    and has("addressPools")
    and has("egressIntent")
    and has("transit")
' "${tmp_dir}/nixos-canon.json" >/dev/null || {
  echo "FAIL: common-intent fields missing from nixos canonicalized output" >&2
  exit 1
}

jq -e '
  .data.esp0xdeadbeef["site-a"]
  | has("policy")
    and has("relations")
    and has("services")
    and has("forwardingSemantics")
    and has("routing")
    and has("overlays")
    and has("communicationContract")
    and has("rendererContracts")
    and has("domains")
    and has("addressPools")
    and has("egressIntent")
    and has("transit")
' "${tmp_dir}/clab-canon.json" >/dev/null || {
  echo "FAIL: common-intent fields missing from clab canonicalized output" >&2
  exit 1
}

echo "PASS hat-cross-profile-equivalence"
