#!/usr/bin/env bash
# GAMP-ID: FS-260-HDS-010-SDS-010-SMS-015
# GAMP-SCOPE: hardware-acceptance-test
# RaTM: HAT probe for policy container nft forward rules bidirectional symmetry.
#
# Two modes:
#   default  : parse nft list ruleset output from file/stdin and verify
#              bidirectional symmetry (intended for live CLAB execution)
#   CPM_VERIFY=1 : CPM construction-level verification using nix eval
#              to prove D18-NEW resolution at the CPM layer
#
# SMS Module Responsibilities covered: MR1-MR5 (see SMS lines 26-38)
# SMS Failure Conditions covered: FC4-FC10 (see SMS lines 56-70)
# SMS Seeded Negatives covered: SN1-SN2 (see SMS lines 81-88)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

# ── Mode selection ──────────────────────────────────────────────────────────

if [[ "${CPM_VERIFY:-0}" == "1" ]]; then
  mode="cpm_verify"
elif [[ -n "${NFT_RULESET_FILE:-}" ]]; then
  mode="nft_file"
elif [[ -n "${CLAB_HOST:-}" ]]; then
  mode="clab_live"
else
  mode="nft_stdin"
fi

# ── Helper functions ────────────────────────────────────────────────────────

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

check_fail() {
  echo "CHECK-FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

check_pass() {
  echo "CHECK-PASS: $*"
}

# ── nft text parsing engine ─────────────────────────────────────────────────

parse_nft_ruleset() {
  local ruleset_text="$1"
  local tmpfile
  tmpfile="$(mktemp)"
  echo "$ruleset_text" > "$tmpfile"

  FORWARD_CHAIN=""
  FORWARD_POLICY=""
  FORWARD_RULE_COUNT=0
  FORWARD_PAIRS=()
  REVERSE_PAIRS_SET=""

  local in_forward=0
  local forward_done=0
  local chain_name=""

  while IFS= read -r line; do
    # Handle both nft output formats:
    #   Old: chain ip filter forward {
    #   New: chain forward {   (type/hook/priority on next line)
    if [[ "$line" =~ ^[[:space:]]*chain[[:space:]]+([^[:space:]]+)[[:space:]]*\{ ]]; then
      # Single-name format: chain <name> {
      chain_name="${BASH_REMATCH[1]}"
      if [[ "$chain_name" == "forward" && $forward_done -eq 0 ]]; then
        in_forward=1
        FORWARD_CHAIN="$chain_name"
      fi
    elif [[ "$line" =~ ^[[:space:]]*chain[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]*\{ ]]; then
      # Three-word format: chain <family> <type> <name> {
      chain_name="${BASH_REMATCH[3]}"
      if [[ "$chain_name" == "forward" && $forward_done -eq 0 ]]; then
        in_forward=1
        FORWARD_CHAIN="$chain_name"
      fi
    fi

    if [[ $in_forward -eq 1 ]]; then
      if [[ "$line" =~ policy[[:space:]]+([^;]+) ]]; then
        FORWARD_POLICY="${BASH_REMATCH[1]}"
      fi
      if [[ "$line" =~ iifname[[:space:]]+\"([^\"]+)\".*oifname[[:space:]]+\"([^\"]+)\".*accept ]]; then
        local iif="${BASH_REMATCH[1]}"
        local oif="${BASH_REMATCH[2]}"
        if [[ "$iif" =~ ^(down-|up-|ens) ]] || [[ "$oif" =~ ^(down-|up-|ens) ]]; then
          FORWARD_RULE_COUNT=$((FORWARD_RULE_COUNT + 1))
          FORWARD_PAIRS+=("${iif}->${oif}")
          REVERSE_PAIRS_SET+="${oif}->${iif}"$'\n'
        fi
      fi
    fi

    if [[ $in_forward -eq 1 && "$line" =~ ^[[:space:]]*\} ]]; then
      in_forward=0
      forward_done=1
    fi
  done < "$tmpfile"

  rm -f "$tmpfile"

  # Dedup forward pairs
  local deduped=()
  local seen=""
  for pair in "${FORWARD_PAIRS[@]}"; do
    if [[ ! " $seen " =~ " $pair " ]]; then
      deduped+=("$pair")
      seen+=" $pair "
    fi
  done
  FORWARD_PAIRS=("${deduped[@]}")
  REVERSE_PAIRS_LOOKUP="$REVERSE_PAIRS_SET"
}

# ── Probe checks against parsed state ───────────────────────────────────────

run_probe_checks() {
  FAILURES=0

  # FC4: No forward chain
  if [[ -z "${FORWARD_CHAIN:-}" ]]; then
    check_fail "FC4: no forward chain exists in nft ruleset"
    return 1
  else
    check_pass "FC4: forward chain '${FORWARD_CHAIN}' found"
  fi

  # FC5: Forward chain policy must be drop
  if [[ "${FORWARD_POLICY:-}" == "accept" ]]; then
    check_fail "FC5: forward chain policy is 'accept' (must be 'drop')"
  elif [[ "${FORWARD_POLICY:-}" == "drop" ]]; then
    check_pass "FC5: forward chain policy is 'drop'"
  else
    check_fail "FC5: forward chain policy is '${FORWARD_POLICY:-<unknown>}' (must be 'drop')"
  fi

  # FC6: Zero forward rules
  if [[ "${FORWARD_RULE_COUNT:-0}" -eq 0 ]]; then
    check_fail "FC6: forward chain has zero rules"
    return 1
  else
    check_pass "FC6: forward chain has ${FORWARD_RULE_COUNT} rules"
  fi

  # MR3/FC7: Count ens* forward pairs
  local ens_fwd_count=${#FORWARD_PAIRS[@]}
  if [[ "$ens_fwd_count" -eq 0 ]]; then
    check_fail "FC7/MR3: zero ens* forward rule pairs found"
    return 1
  else
    check_pass "FC7/MR3: ${ens_fwd_count} unique ens* forward rule pairs"
  fi

  # MR4/MR5/FC10: Bidirectional symmetry check
  local missing_reverse=()
  for pair in "${FORWARD_PAIRS[@]}"; do
    local iif="${pair%%->*}"
    local oif="${pair##*->}"
    local reverse_pair="${oif}->${iif}"
    if ! echo "$REVERSE_PAIRS_LOOKUP" | grep -qF "$reverse_pair"; then
      missing_reverse+=("$pair (no reverse: $reverse_pair)")
    fi
  done

  if [[ ${#missing_reverse[@]} -gt 0 ]]; then
    check_fail "FC10/D18-NEW: ${#missing_reverse[@]} forward rule pair(s) lack return-path reverse rules:"
    for gap in "${missing_reverse[@]}"; do
      echo "  D18-NEW GAP: $gap" >&2
    done
  else
    check_pass "FC10/MR4: all ${ens_fwd_count} forward pairs have corresponding reverse rules"
  fi

  return $FAILURES
}

# ── CPM verification mode ───────────────────────────────────────────────────

run_cpm_verify() {
  echo "=== FS-260-HDS-010-SDS-010-SMS-015: CPM verify mode ==="
  echo "Verifying CPM policy.nix relationRules generates correct bidirectional rules"
  echo "with post-NFM-fix returnBehavior=symmetric injection."
  echo ""

  source "${REPO_ROOT}/tests/lib/direct-test-guard.sh"

  local result_json nix_file
  result_json="$(mktemp)"
  nix_file="${REPO_ROOT}/tests/fs260-hds010-sds010-sms015-hat-probe-cpm-verify.nix"

  # Evaluate the nix expression
  nix eval --impure --expr "(import ${nix_file} { repoRoot = \"${REPO_ROOT}\"; })" --json > "${result_json}" 2>&1 || {
    echo "FAIL test-hat-policy-nft-rules (CPM verify mode)" >&2
    echo "nix eval error:" >&2
    cat "${result_json}" >&2
    rm -f "${result_json}"
    return 1
  }

  local failed_checks
  failed_checks="$(jq -r '. | to_entries[] | select(.value != true) | .key' "${result_json}")"

  if [[ -n "${failed_checks}" ]]; then
    echo "FAIL test-hat-policy-nft-rules (CPM verify mode)" >&2
    echo "failed checks:" >&2
    while IFS= read -r check; do
      echo "  ${check}" >&2
    done <<< "${failed_checks}"
    echo "full result:" >&2
    jq -S . "${result_json}" >&2
    rm -f "${result_json}"
    return 1
  fi

  rm -f "${result_json}"
  echo ""
  echo "PASS test-hat-policy-nft-rules (CPM verify mode)"
  echo "All D18-NEW trafficTypes verified: any, dns, icmp, nebula, ipp → bidirectional rules"
  echo "Tenant-to-tenant exclusion verified: no reverse rules injected"
  echo "Explicit one-way preserved: no reverse rules injected"
  return 0
}

# ── nft file mode ───────────────────────────────────────────────────────────

run_nft_file() {
  echo "=== FS-260-HDS-010-SDS-010-SMS-015: nft ruleset file mode ==="
  echo "File: ${NFT_RULESET_FILE}"
  echo ""

  if [[ ! -f "${NFT_RULESET_FILE}" ]]; then
    fail "NFT_RULESET_FILE '${NFT_RULESET_FILE}' not found"
  fi

  local ruleset_text
  ruleset_text="$(cat "${NFT_RULESET_FILE}")"
  parse_nft_ruleset "$ruleset_text"

  echo "Forward chain: ${FORWARD_CHAIN:-<none>}"
  echo "Forward policy: ${FORWARD_POLICY:-<unknown>}"
  echo "Forward rule count: ${FORWARD_RULE_COUNT}"
  echo "Unique ens* forward pairs: ${#FORWARD_PAIRS[@]}"
  echo ""

  run_probe_checks
  local result=$?

  if [[ $result -eq 0 ]]; then
    echo ""
    echo "PASS test-hat-policy-nft-rules (nft file mode)"
  else
    echo ""
    echo "FAIL test-hat-policy-nft-rules (nft file mode)"
  fi
  return $result
}

# ── nft stdin mode ──────────────────────────────────────────────────────────

run_nft_stdin() {
  echo "=== FS-260-HDS-010-SDS-010-SMS-015: nft ruleset stdin mode ==="
  echo "Reading nft list ruleset from stdin..."
  echo ""

  local ruleset_text
  ruleset_text="$(cat)"
  parse_nft_ruleset "$ruleset_text"

  echo "Forward chain: ${FORWARD_CHAIN:-<none>}"
  echo "Forward policy: ${FORWARD_POLICY:-<unknown>}"
  echo "Forward rule count: ${FORWARD_RULE_COUNT}"
  echo "Unique ens* forward pairs: ${#FORWARD_PAIRS[@]}"
  echo ""

  run_probe_checks
  local result=$?

  if [[ $result -eq 0 ]]; then
    echo ""
    echo "PASS test-hat-policy-nft-rules (nft stdin mode)"
  else
    echo ""
    echo "FAIL test-hat-policy-nft-rules (nft stdin mode)"
  fi
  return $result
}

# ── CLAB live mode ──────────────────────────────────────────────────────────

run_clab_live() {
  echo "=== FS-260-HDS-010-SDS-010-SMS-015: CLAB live mode ==="
  echo "CLAB host: ${CLAB_HOST}"
  echo ""

  local ssh_test
  if ! ssh_test="$(ssh -o ConnectTimeout=5 -o BatchMode=yes "root@${CLAB_HOST}" 'echo OK' 2>&1)"; then
    check_fail "FC1: SSH to CLAB host '${CLAB_HOST}' failed: ${ssh_test}"
    return 1
  fi
  check_pass "FC1: SSH to CLAB host '${CLAB_HOST}' OK"

  local policy_container
  policy_container="$(ssh "root@${CLAB_HOST}" 'docker ps --format "{{.Names}}" 2>/dev/null | grep -E "clab-fabric-.*-policy$" | head -1' 2>/dev/null || true)"
  if [[ -z "${policy_container}" ]]; then
    check_fail "FC2: no policy container matching 'clab-fabric-.*-policy$' found on ${CLAB_HOST}"
    return 1
  fi
  check_pass "FC2: policy container '${policy_container}' found"

  local ruleset_text
  if ! ruleset_text="$(ssh "root@${CLAB_HOST}" "docker exec ${policy_container} nft list ruleset" 2>&1)"; then
    check_fail "FC3: nft list ruleset failed in container '${policy_container}': ${ruleset_text}"
    return 1
  fi
  check_pass "FC3: nft list ruleset captured from '${policy_container}'"

  parse_nft_ruleset "$ruleset_text"

  echo "Forward chain: ${FORWARD_CHAIN:-<none>}"
  echo "Forward policy: ${FORWARD_POLICY:-<unknown>}"
  echo "Forward rule count: ${FORWARD_RULE_COUNT}"
  echo "Unique ens* forward pairs: ${#FORWARD_PAIRS[@]}"
  echo ""

  run_probe_checks
  local result=$?

  if [[ $result -eq 0 ]]; then
    echo ""
    echo "PASS test-hat-policy-nft-rules (CLAB live mode)"
  else
    echo ""
    echo "FAIL test-hat-policy-nft-rules (CLAB live mode)"
  fi
  return $result
}

# ── Main ────────────────────────────────────────────────────────────────────

case "$mode" in
  cpm_verify)
    run_cpm_verify
    ;;
  nft_file)
    run_nft_file
    ;;
  clab_live)
    run_clab_live
    ;;
  nft_stdin)
    if [[ -t 0 ]]; then
      echo "Usage:" >&2
      echo "  NFT_RULESET_FILE=/path/to/nft-ruleset.txt $0" >&2
      echo "  cat nft-ruleset.txt | $0" >&2
      echo "  CPM_VERIFY=1 $0" >&2
      echo "  CLAB_HOST=hostname $0" >&2
      exit 1
    fi
    run_nft_stdin
    ;;
esac
