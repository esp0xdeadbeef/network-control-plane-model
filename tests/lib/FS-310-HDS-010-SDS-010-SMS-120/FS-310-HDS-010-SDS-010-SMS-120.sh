#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-010-SDS-010-SMS-120
# GAMP-SCOPE: software-module-test
# Focused construction test: CPM source scan for builtins.match naming-inference patterns.
# Scans all CPM .nix source files, classifies each builtins.match as
# platform-validation (permitted) or naming-inference (rejected).
# Fails if any naming-inference patterns are found.
# SMS-120: Renderers and CPM must not derive network meaning from name patterns.
# All classification must use explicit CPM metadata fields, not string matching.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

all_checks_passed=true
src_dir="${repo_root}/src"

echo "--- FS-310-HDS-010-SDS-010-SMS-120: CPM source scan for naming-inference ---"
echo ""

# ============================================================
# KNOWN PERMITTED builtins.match regex patterns
# (platform-validation / format checks, NOT naming inference)
# These are the exact Nix string literals as they appear in source.
# Additions require SMS-120 review: does this derive behavior from a name?
# ============================================================
PERMITTED_PATTERNS=(
  # --- IPv6 address detection (colon presence) ---
  '".*:.*"'

  # --- Host route detection ---
  '".*/32"'
  '".*/128"'
  '".*/32$"'
  '".*/128$"'
  '".*/3[12]"'
  '".*/12[78]"'

  # --- CIDR notation parsing ---
  '"([^/]+)/([0-9]+)"'
  '".*/([0-9]+)$"'

  # --- IPv4 octet extraction ---
  '"([0-9]+)\\.([0-9]+)\\.([0-9]+)\\.([0-9]+)"'
  '"([0-9]+)\\.([0-9]+)\\.([0-9]+)\\..*"'
  '"([0-9]+\\.[0-9]+\\.[0-9]+)\\.([0-9]+)/.*"'

  # --- IPv4 address / CIDR format ---
  '"([0-9]{1,3}\\.){3}[0-9]{1,3}"'
  '"^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+$"'
  '"^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/32$"'
  '"([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})/([0-9]{1,2})"'

  # --- IPv6 hex segment validation ---
  '"^[0-9A-Fa-f]{1,4}$"'

  # --- MAC address format ---
  '"([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}"'

  # --- IPv6 address format ---
  '"([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}"'
  '"([^:]+):([^:]+):([^:]+):([^:]+):.*"'

  # --- IPv6 character class validation ---
  '"[0-9A-Fa-f:.]+"'

  # --- RFC1918 private IPv4 ---
  '"10\\..*"'
  '"192\\.168\\..*"'
  '"172\\.(1[6-9]|2[0-9]|3[0-1])\\..*"'
  '"^(10\\..*|172\\.(1[6-9]|2[0-9]|3[0-1])\\..*|192\\.168\\..*)$"'

  # --- CGNAT 100.64/10 ---
  '"100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\..*"'

  # --- ULA prefix (fc00::/7, fd00::/8) ---
  '"^[fF][cCdD].*"'
  '"[fF][cCdD].*"'

  # --- GUA prefix (2000::/3, 3000::/4) ---
  '"^[23][0-9A-Fa-f]{3}:.*"'

  # --- Lowercase identifier validation (DNS-safe names) ---
  '"^[a-z][a-z0-9-]*$"'

  # --- Linux interface name constraints (max 15 chars, alphanum + . _ -) ---
  '"^[A-Za-z0-9_.-]{1,15}$"'

  # --- Structured prefix part format (source:... notation) ---
  '"source:.*"'

  # --- Dynamic IPv4 pattern (uses variable interpolation) ---
  '"${ipv4Octet}\\.${ipv4Octet}\\.${ipv4Octet}\\.${ipv4Octet}"'
)

# ============================================================
# Classification function
# ============================================================
classify_line() {
  local file="$1" line_num="$2" content="$3"

  # Extract the string between the first pair of double quotes after "builtins.match"
  local pattern
  pattern=$(echo "${content}" | sed -n 's/.*builtins\.match *"\([^"]*\)".*/\1/p' | head -1)

  if [[ -z "${pattern}" ]]; then
    return 0  # Can't extract, skip
  fi

  # Reconstruct the full quoted form for comparison
  local full_pattern="\"${pattern}\""

  # Check against permitted set
  local allowed
  for allowed in "${PERMITTED_PATTERNS[@]}"; do
    if [[ "${full_pattern}" == "${allowed}" ]]; then
      return 0  # Permitted — platform validation
    fi
  done

  # Not in permitted set → NAMING_INFERENCE
  echo "  NAMING_INFERENCE: ${file}:${line_num}: ${full_pattern}"
  return 1
}

# ============================================================
# Scan all CPM source .nix files for builtins.match
# ============================================================
echo "SCAN: Searching all CPM .nix source for builtins.match..."
echo ""

violations=0
scanned_count=0

while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  file=$(echo "${line}" | cut -d: -f1)
  line_num=$(echo "${line}" | cut -d: -f2)
  content=$(echo "${line}" | cut -d: -f3-)

  scanned_count=$((scanned_count + 1))
  classify_line "${file}" "${line_num}" "${content}" || violations=$((violations + 1))
done < <(grep -rn 'builtins\.match' "${src_dir}/" --include='*.nix' 2>/dev/null || true)

echo "Scanned ${scanned_count} builtins.match hits across CPM source."
echo ""

# ============================================================
# Check results
# ============================================================
if [[ "${violations}" -gt 0 ]]; then
  echo "FAIL: ${violations} naming-inference builtins.match pattern(s) found."
  echo "  SMS-120 requires all classification to use explicit CPM metadata fields."
  echo "  Replace name-pattern matches with structural metadata from common.nix"
  echo "  (isOverlayCoreInterface, backingRef.lane, sourceKind, etc.)."
  echo ""
  all_checks_passed=false
else
  echo "PASS: 0 naming-inference patterns found in CPM source."
  echo "  All builtins.match uses are platform-validation (IP/prefix/format checks)."
  echo ""
fi

# ============================================================
# Seeded negative: inject fake .nix with naming-inference patterns
# Six prohibited name-matching categories from SMS-120 §Module Failure Conditions.
# ============================================================
echo "--- FS-310-HDS-010-SDS-010-SMS-120: Seeded negative ---"
echo ""

fake_nix="${tmp_dir}/fake-naming-inference.nix"
cat > "${fake_nix}" <<'NIXEOF'
# Seeded negative for SMS-120: contains intentional naming-inference patterns.
# These use builtins.match on names/IDs to derive classification behavior —
# exactly what SMS-120 prohibits. All six should be flagged as NAMING_INFERENCE.
{
  # Renderer technology name in CPM (nebula)
  classifyByNebulaName = iface:
    builtins.match ".*nebula.*" (iface.backingRef.name or "") != null;
  # Renderer technology name in CPM (wireguard)
  classifyByWgName = node:
    builtins.match ".*wireguard-peer.*" (node.role or "") != null;
  # Renderer-specific naming convention (vlan4)
  classifyByVlan4Name = transit:
    builtins.match ".*vlan4.*" (transit.transitId or "") != null;
  # Relation ID prefix classification (selector-*)
  classifyBySelectorPrefix = rule:
    builtins.match ".*selector-.*" (rule.relationId or "") != null;
  # Core classification from interface name (core-upstream-*)
  classifyByCoreName = iface:
    builtins.match ".*core-upstream.*" (iface.backingRef.name or "") != null;
  # Host-facing from name substring (access-iot)
  classifyByAccessName = iface:
    builtins.match ".*access-iot.*" (iface.backingRef.name or "") != null;
}
NIXEOF

neg_violations=0
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  file=$(echo "${line}" | cut -d: -f1)
  line_num=$(echo "${line}" | cut -d: -f2)
  content=$(echo "${line}" | cut -d: -f3-)
  classify_line "${file}" "${line_num}" "${content}" || neg_violations=$((neg_violations + 1))
done < <(grep -Hrn 'builtins\.match' "${fake_nix}" 2>/dev/null || true)

if [[ "${neg_violations}" -ge 6 ]]; then
  echo "  Seeded negative PASS: ${neg_violations} injected violations correctly detected."
  echo "  Prohibited patterns caught:"
  echo "    - .*nebula.* (renderer technology name)"
  echo "    - .*wireguard-peer.* (renderer technology name)"
  echo "    - .*vlan4.* (renderer-specific naming convention)"
  echo "    - .*selector-.* (relation ID prefix classification)"
  echo "    - .*core-upstream.* (core name pattern matching)"
  echo "    - .*access-iot.* (host-facing name substring)"
else
  echo "  Seeded negative FAIL: expected >=6 detections, got ${neg_violations}"
  echo "  The classification function is not detecting naming-inference patterns."
  echo "  Check: PERMITTED_PATTERNS array, sed extraction, and comparison logic."
  all_checks_passed=false
fi
echo ""

# ============================================================
# Final
# ============================================================
if [[ "${all_checks_passed}" == "true" ]]; then
  echo "PASS FS-310-HDS-010-SDS-010-SMS-120"
  exit 0
else
  echo "FAIL FS-310-HDS-010-SDS-010-SMS-120"
  exit 1
fi
