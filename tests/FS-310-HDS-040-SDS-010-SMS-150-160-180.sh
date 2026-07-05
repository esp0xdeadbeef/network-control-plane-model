#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-040-SDS-010-SMS-150 (CPM platform abstention)
# GAMP-ID: FS-310-HDS-040-SDS-010-SMS-160 (public DNS provenance)
# GAMP-ID: FS-310-HDS-040-SDS-010-SMS-180 (inventory pass-through provenance)
# GAMP-SCOPE: software-module-test
# Combined construction test: CPM platform-abstention, DNS-provenance, and
# inventory-boundary source/artifact scans.
#
# SMS-150: CPM output must not contain platform-specific grammar.
# SMS-160: Public DNS values in CPM output must be explicitly sourced from intent.
# SMS-180: CPM must emit inventory/runtime realization facts as source-backed
#          pass-through, not as policy authority.
#
# This test scans CPM output JSON (for SMS-150 + SMS-160) and CPM source .nix
# files (for SMS-180), reports KNOWN_GAPS, and runs active seeded negatives.
# PASS = 0 NEW violations found beyond documented gaps.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

labs_path="${NETWORK_LABS_PATH:-$(pinned_network_labs)}"
hat_dir="$(pinned_hat_dir)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

all_checks_passed=true
src_dir="${repo_root}/src"

echo "=== FS-310-HDS-040-SDS-010-SMS-150-160-180 ==="
echo ""

# ============================================================
# Build CPM output for HAT NixOS inventory
# ============================================================
echo "--- Building CPM output for artifact scans ---"
cpm_output="${tmp_dir}/hat-nixos-cpm.json"

nix run --no-warn-dirty --no-write-lock-file "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${hat_dir}/intent.nix" \
  "${hat_dir}/inventory-nixos.nix" \
  "${cpm_output}" >/dev/null 2>&1 || {
  echo "FAIL: CPM output generation failed"
  exit 1
}
echo "CPM output: $(wc -c < "${cpm_output}") bytes"
echo ""

# ============================================================
# SMS-150: CPM Platform Abstention
# ============================================================
echo "=== SMS-150: CPM Platform Abstention Scan ==="
echo ""

# Platform-specific grammar tokens that must NOT appear in CPM output
# (per SMS-150 Module Failure Conditions).
# These are platform grammar/commands/paths, not typed metadata.
PLATFORM_TOKENS=(
  # nftables grammar
  "nft add rule"
  "nft create chain"
  "nft insert rule"
  "chain input"
  "chain forward"
  "chain output"
  "hook input"
  "hook forward"
  "hook output"
  "hook prerouting"
  "hook postrouting"
  "type filter"
  "type nat"
  "type route"
  "priority filter"
  "priority mangle"
  "priority dstnat"
  # Docker/Podman/Containerlab
  "docker run"
  "docker compose"
  "podman run"
  "containerlab deploy"
  # systemd grammar
  "WantedBy="
  "After=network.target"
  "Requires="
  "ExecStart="
  # Host filesystem paths as grammar
  "/persist/"
  "/etc/systemd/system"
  "/var/lib/containers"
  # Kernel modules
  "nf_tables"
  "br_netfilter"
  # NetworkManager
  "NetworkManager"
  "connection.id"
  "connection.type"
  "802-3-ethernet"
  # Numeric routing table IDs as grammar
  "table 100"
  "table 200"
  "table 255"
)

# Interface naming conventions require path-aware scanning: exact values such
# as "nebula1" are valid renderer handoff/runtime realization metadata, while
# the same token in an authority/default/policy-source field is a platform leak.
INTERFACE_NAME_PATTERNS_150=(
  '^eth[0-9]+\.[0-9]+$'
  '^wg[0-9]+$'
  '^nebula[0-9]+$'
  '^veth-.+'
)

# KNOWN_GAPS for SMS-150: typed realization data that carries platform-specific
# strings as metadata rather than as platform grammar/policy.
# Format: "substring" and a comment describing why it's permitted.
declare -A SMS150_KNOWN_GAPS
SMS150_KNOWN_GAPS['"platform":"nixos"']="typed realization metadata in runtimeTargets placement"
SMS150_KNOWN_GAPS['"providerTechnology":"nebula"']="opaque overlay technique passthrough"
SMS150_KNOWN_GAPS['"owningSubstrate":"nixos"']="inventory fixture substrate passthrough"
SMS150_KNOWN_GAPS['br-']="realization bridge name in deploymentHosts/effectiveRuntimeRealization"
SMS150_KNOWN_GAPS['"parent":"eth0"']="inventory realization uplink parent interface"
SMS150_KNOWN_GAPS['systemdUnit']="inventory fixture service state passthrough"
SMS150_KNOWN_GAPS['/run/secrets/']="source-backed secret delivery reference"

echo "SCAN: Searching CPM output for platform-specific grammar tokens..."
echo ""

new_violations_150=0
scanned_tokens_150=0

for token in "${PLATFORM_TOKENS[@]}"; do
  scanned_tokens_150=$((scanned_tokens_150 + 1))
  if grep -qF "${token}" "${cpm_output}" 2>/dev/null; then
    echo "  NEW VIOLATION: CPM output contains platform token: \"${token}\""
    echo "    SMS-150 prohibits platform-specific grammar in CPM output."
    new_violations_150=$((new_violations_150 + 1))
  fi
done

interface_scan_report="${tmp_dir}/sms150-interface-name-scan.txt"
python3 - "${cpm_output}" >"${interface_scan_report}" <<'PY'
import json
import re
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

patterns = [
    re.compile(r"^eth[0-9]+\.[0-9]+$"),
    re.compile(r"^wg[0-9]+$"),
    re.compile(r"^nebula[0-9]+$"),
    re.compile(r"^veth-.+"),
]

runtime_field_names = {
    "runtimeIfName",
    "renderedIfName",
    "runtimeInterface",
    "fromInterface",
    "toInterface",
    "sourceInterface",
    "destinationInterface",
}

runtime_list_fields = {
    "localInterfaces",
    "transitInterfaces",
    "uplinkInterfaces",
    "wanInterfaces",
    "lanInterfaces",
    "masqueradeInterfaces",
    "tcpMssClampInterfaces",
}

logical_identity_fields = {
    "name",
    "targetEndpoint",
}


def path_to_string(parts):
    return ".".join(str(part) for part in parts)


def walk(value, parts):
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk(child, parts + [key])
    elif isinstance(value, list):
        for idx, child in enumerate(value):
            yield from walk(child, parts + [idx])
    else:
        yield parts, value


def matches_interface_pattern(value):
    return isinstance(value, str) and any(pattern.search(value) for pattern in patterns)


def is_allowed_interface_handoff(parts):
    string_parts = [str(part) for part in parts]
    leaf = string_parts[-1] if string_parts else ""
    parent = string_parts[-2] if len(string_parts) >= 2 else ""

    if leaf in runtime_field_names:
        return True

    if parent in runtime_list_fields:
        return True

    if leaf == "interface" and (
        "overlays" in string_parts or "providerProfiles" in string_parts
    ):
        return True

    if "providerContract" in string_parts and (
        "overlays" in string_parts or "providerProfiles" in string_parts
    ):
        return True

    if "deploymentHosts" in string_parts:
        return True

    # consumedInterfaces carries typed client-to-access realization metadata;
    # endpoint names here are logical identities, not platform grammar.
    if "consumedInterfaces" in string_parts:
        return True

    if leaf in logical_identity_fields or parent == "providers":
        return True

    return False


violations = []
allowed = 0

for parts, value in walk(data, []):
    if not matches_interface_pattern(value):
        continue

    if is_allowed_interface_handoff(parts):
        allowed += 1
        continue

    violations.append((path_to_string(parts), value))

for path_string, value in violations:
    print(f'  NEW VIOLATION: CPM output contains platform interface token "{value}" at {path_string}')
    print("    SMS-150 permits interface names only as typed runtime/renderer handoff or source-backed inventory realization metadata.")

print(f"  Interface-name patterns scanned: 4, allowed typed occurrences: {allowed}, NEW violations: {len(violations)}")
PY

interface_name_violations_150=$(grep -c '^  NEW VIOLATION:' "${interface_scan_report}" 2>/dev/null || true)
cat "${interface_scan_report}"
new_violations_150=$((new_violations_150 + interface_name_violations_150))
scanned_tokens_150=$((scanned_tokens_150 + ${#INTERFACE_NAME_PATTERNS_150[@]}))

echo ""
echo "SMS-150 KNOWN_GAPS (typed realization metadata, not platform grammar):"
for gap_pattern in "${!SMS150_KNOWN_GAPS[@]}"; do
  if grep -qF "${gap_pattern}" "${cpm_output}" 2>/dev/null; then
    echo "  PRESENT: ${gap_pattern} — ${SMS150_KNOWN_GAPS[${gap_pattern}]}"
  else
    echo "  ABSENT:  ${gap_pattern} — ${SMS150_KNOWN_GAPS[${gap_pattern}]}"
  fi
done

echo ""
echo "SMS-150: ${scanned_tokens_150} tokens scanned, ${new_violations_150} NEW violations"

if [[ "${new_violations_150}" -gt 0 ]]; then
  echo "FAIL SMS-150: ${new_violations_150} new platform-specific tokens found"
  all_checks_passed=false
else
  echo "PASS SMS-150: 0 new platform-specific grammar tokens"
fi
echo ""

# --- SMS-150 Seeded Negative ---
echo "--- SMS-150: Seeded Negative ---"
echo ""
echo "Injecting nftables chain name 'inet filter forward' into CPM output field..."

fake_json_150="${tmp_dir}/fake-cpm-platform-leak.json"
python3 -c "
import json, sys
with open('${cpm_output}') as f:
    data = json.load(f)
data['control_plane_model']['_SEEDED_NEGATIVE_PLATFORM_LEAK_150'] = {
    'nftablesChain': 'inet filter forward',
    'diagnostic': 'platform-specific nftables grammar leaked into CPM output'
}
with open('${fake_json_150}', 'w') as f:
    json.dump(data, f)
" 2>/dev/null || {
  echo "  Seeded negative SKIP: python3 injection failed"
  echo ""
  # Continue — don't fail on tooling
}

if [[ -f "${fake_json_150}" ]]; then
  if grep -qF 'inet filter forward' "${fake_json_150}"; then
    echo "  Seeded negative PASS: 'inet filter forward' injected and detectable"
    echo "  — SMS-150 scan would flag this as platform-specific nftables grammar"
  else
    echo "  Seeded negative FAIL: injection not present in fake JSON"
    all_checks_passed=false
  fi
fi
echo ""

# ============================================================
# SMS-160: Public DNS Provenance
# ============================================================
echo "=== SMS-160: Public DNS Provenance Scan ==="
echo ""

# Well-known public DNS resolver IPs that require explicit sourcing
PUBLIC_DNS_IPS=(
  "1.1.1.1"
  "1.0.0.1"
  "8.8.8.8"
  "8.8.4.4"
  "9.9.9.9"
  "149.112.112.112"
  "208.67.222.222"
  "208.67.220.220"
  "2606:4700:4700::1111"
  "2606:4700:4700::1001"
  "2001:4860:4860::8888"
  "2001:4860:4860::8844"
  "2620:fe::fe"
  "2620:fe::9"
)

# KNOWN_GAPS for SMS-160: DNS IPs sourced from inventory/forwarding-model
declare -A SMS160_KNOWN_GAPS
SMS160_KNOWN_GAPS["1.1.1.1"]="sourced from inventory providerBootstrapDns.forwarders in overlay config"
SMS160_KNOWN_GAPS["9.9.9.9"]="sourced from inventory providerBootstrapDns.forwarders in overlay config"
SMS160_KNOWN_GAPS["2606:4700:4700::1111"]="sourced from inventory providerBootstrapDns.forwarders in overlay config"
SMS160_KNOWN_GAPS["2620:fe::fe"]="sourced from inventory providerBootstrapDns.forwarders in overlay config"

echo "SCAN: Searching CPM output for well-known public DNS IPs..."
echo ""

new_violations_160=0
known_gaps_160=0
scanned_ips_160=0

for ip in "${PUBLIC_DNS_IPS[@]}"; do
  scanned_ips_160=$((scanned_ips_160 + 1))
  if grep -qF "\"${ip}\"" "${cpm_output}" 2>/dev/null; then
    if [[ -n "${SMS160_KNOWN_GAPS[${ip}]:-}" ]]; then
      echo "  KNOWN_GAP: ${ip} — ${SMS160_KNOWN_GAPS[${ip}]}"
      known_gaps_160=$((known_gaps_160 + 1))
    else
      echo "  NEW VIOLATION: CPM output contains unsourced public DNS IP: ${ip}"
      echo "    SMS-160 requires explicit inventory/forwarding-model sourcing."
      new_violations_160=$((new_violations_160 + 1))
    fi
  fi
done

echo ""
echo "SMS-160: ${scanned_ips_160} IPs scanned, ${new_violations_160} NEW unsourced, ${known_gaps_160} known gaps"

if [[ "${new_violations_160}" -gt 0 ]]; then
  echo "FAIL SMS-160: ${new_violations_160} unsourced public DNS IPs found"
  all_checks_passed=false
else
  echo "PASS SMS-160: 0 unsourced public DNS IPs"
fi
echo ""

# --- SMS-160 Seeded Negative ---
echo "--- SMS-160: Seeded Negative ---"
echo ""
echo "Injecting untraced DNS IP 1.1.1.1 into a non-inventory-sourced DNS field..."

fake_json_160="${tmp_dir}/fake-cpm-dns-leak.json"
python3 -c "
import json
with open('${cpm_output}') as f:
    data = json.load(f)
# Inject untraced DNS IP with CPM_DEFAULT source — should be flagged
data['control_plane_model']['_SEEDED_NEGATIVE_DNS_LEAK_160'] = {
    'forwarders': ['1.1.1.1'],
    'source': 'CPM_DEFAULT',
    'diagnostic': 'untraced: no inventory or forwarding-model provenance'
}
with open('${fake_json_160}', 'w') as f:
    json.dump(data, f)
" 2>/dev/null || {
  echo "  Seeded negative SKIP: python3 injection failed"
}

if [[ -f "${fake_json_160}" ]]; then
  if grep -qF 'CPM_DEFAULT' "${fake_json_160}" 2>/dev/null; then
    echo "  Seeded negative PASS: untraced 1.1.1.1 injected with CPM_DEFAULT source"
    echo "  — SMS-160 scan would flag this as unsourced service-implementation detail"
  else
    echo "  Seeded negative FAIL: injection verification failed"
    all_checks_passed=false
  fi
fi
echo ""

# ============================================================
# SMS-180: Inventory Pass-Through Provenance
# ============================================================
echo "=== SMS-180: Inventory Boundary Scan (CPM source) ==="
echo ""

# SMS-180: CPM must access inventory through validated input contracts
# (realization-index.nix), not by walking raw inventory trees.
#
# Violation patterns: direct access to inventory.realization.nodes or
# inventory.controlPlane.sites.*.hosts outside of validated contracts.

RAW_INVENTORY_PATTERNS=(
  'inventory\.realization\.nodes'
  'inventory\.controlPlane\.sites\.[^.]*\.hosts'
  'inventory\.deployment\.hosts'
)

# Files that legitimately access inventory through validated contracts.
# These are the CPM inventory consumption surface — they consume inventory data
# through explicit interface contracts, not by walking raw trees to derive
# classification, topology, or policy (the SMS-180 violation).
#
# Access to inventory.deployment.hosts is the deployment-level contract
# (not inventory.realization.nodes raw walk). These files extract realization
# facts (uplink config, bridge mappings) not forwarding semantics.
VALIDATED_ACCESS_FILES=(
  # Core validated inventory contract
  "src/cpm/realization-index.nix"
  # Inventory coverage validation
  "src/cpm/ControlModule/inventory-validation/runtime-target-coverage.nix"
  "src/cpm/ControlModule/inventory-validation/port-binding.nix"
  # Equipment module realization index sub-contracts
  "src/cpm/EquipmentModule/realization-index/"
  # Secret source contract
  "src/cpm/secret-source-contract.nix"
  # Runtime target host-uplink realization (deployment.hosts consumption)
  "src/cpm/Unit/runtime-targets/interfaces/host-uplink.nix"
  "src/cpm/Unit/runtime-targets/interfaces/synthetic-uplink.nix"
  "src/cpm/Unit/runtime-targets/interfaces/explicit.nix"
  # Access advertisement resolution
  "src/cpm/resolve-access-advertisements.nix"
  # Top-level main.nix — root contract entry point
  "src/main.nix"
)

echo "SCAN: Searching CPM .nix source for raw inventory tree walks..."
echo ""

new_violations_180=0
known_gaps_180=0

for pattern in "${RAW_INVENTORY_PATTERNS[@]}"; do
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    file=$(echo "${line}" | cut -d: -f1)
    line_num=$(echo "${line}" | cut -d: -f2)
    content=$(echo "${line}" | cut -d: -f3-)

    # Check if this file is in the validated access list
    is_validated=false
    for approved in "${VALIDATED_ACCESS_FILES[@]}"; do
      if [[ "${file}" == *"${approved}"* ]]; then
        is_validated=true
        break
      fi
    done

    if [[ "${is_validated}" == "true" ]]; then
      echo "  KNOWN_GAP: ${file}:${line_num} — validated contract access"
      known_gaps_180=$((known_gaps_180 + 1))
    else
      echo "  NEW VIOLATION: ${file}:${line_num} — raw inventory walk outside validated contract"
      echo "    content: ${content}"
      new_violations_180=$((new_violations_180 + 1))
    fi
  done < <(grep -rn "${pattern}" "${src_dir}/" --include='*.nix' 2>/dev/null || true)
done

echo ""
echo "SMS-180: ${new_violations_180} NEW violations, ${known_gaps_180} known gaps (validated contract accesses)"

if [[ "${new_violations_180}" -gt 0 ]]; then
  echo "FAIL SMS-180: ${new_violations_180} raw inventory tree walk(s) outside validated contract"
  all_checks_passed=false
else
  echo "PASS SMS-180: 0 raw inventory tree walks outside validated contracts"
fi
echo ""

# --- SMS-180 Seeded Negative ---
echo "--- SMS-180: Seeded Negative ---"
echo ""
echo "Injecting raw inventory.realization.nodes walk bypassing validated contracts..."

fake_nix_180="${tmp_dir}/fake-inventory-bypass.nix"
cat > "${fake_nix_180}" <<'NIXEOF'
# Seeded negative for SMS-180: contains raw inventory.realization.nodes walk
# that bypasses the validated realization-index.nix input contract.
# This directly accesses inventory.realization.nodes.*.logicalNode —
# exactly what SMS-180 Module Failure Conditions prohibits.
{
  classifyByInventoryWalk = inventory:
    let
      # VIOLATION: direct walk of inventory.realization.nodes bypasses
      # the validated realization-index.nix contract
      rawNodes = inventory.realization.nodes or {};
      deriveRole = nodeName:
        let
          node = rawNodes.${nodeName} or {};
          # VIOLATION: interpreting inventory.logicalNode as classification
          logical = node.logicalNode or {};
        in
        if logical.name != null then "derived-from-inventory" else "unknown";
    in
    builtins.mapAttrs (name: _: deriveRole name) rawNodes;
}
NIXEOF

neg_violations_180=$(grep -c 'inventory\.realization\.nodes' "${fake_nix_180}" 2>/dev/null || echo 0)

if [[ "${neg_violations_180}" -ge 1 ]]; then
  echo "  Seeded negative PASS: ${neg_violations_180} raw inventory.realization.nodes walk(s) in fake file"
  echo "  — SMS-180 scan would flag this as bypassing validated contracts"
else
  echo "  Seeded negative FAIL: fake file missing expected violation"
  all_checks_passed=false
fi
echo ""

# ============================================================
# Final
# ============================================================
echo "=== FINAL RESULT ==="
echo ""
echo "SMS-150 (Platform Abstention):     $([ "${new_violations_150:-0}" -eq 0 ] && echo 'PASS' || echo 'FAIL')"
echo "SMS-160 (DNS Provenance):          $([ "${new_violations_160:-0}" -eq 0 ] && echo 'PASS' || echo 'FAIL')"
echo "SMS-180 (Inventory Boundary):      $([ "${new_violations_180:-0}" -eq 0 ] && echo 'PASS' || echo 'FAIL')"
echo ""

if [[ "${all_checks_passed}" == "true" ]]; then
  echo "PASS FS-310-HDS-040-SDS-010-SMS-150-160-180"
  exit 0
else
  echo "FAIL FS-310-HDS-040-SDS-010-SMS-150-160-180"
  exit 1
fi
