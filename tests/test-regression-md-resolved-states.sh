#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
regression="${repo_root}/regression.md"

if [[ ! -f "${regression}" ]]; then
  echo "FAIL regression.md state gate: missing ${regression}" >&2
  exit 1
fi

allowed_re='^(solved|fixed-locally|fixed-live|implemented-not-live-validated|still-broken|pending|unknown)$'
violations=()

while IFS=: read -r line text; do
  state="$(sed -n 's/.*state=\([^ |`]*\).*/\1/p' <<<"${text}")"
  [[ -n "${state}" ]] || continue

  if [[ ! "${state}" =~ ${allowed_re} ]]; then
    violations+=("${regression}:${line}: unsupported state=${state}: ${text}")
  elif [[ "${text}" != *"target="* || "${text}" != *"evidence="* || "${text}" != *"reason="* ]]; then
    violations+=("${regression}:${line}: state=${state} lacks target/evidence/reason: ${text}")
  fi
done < <(grep -n 'state=' "${regression}" || true)

if ((${#violations[@]} > 0)); then
  echo "FAIL regression.md state gate: regression entries must use a supported state and remain concrete." >&2
  echo "Use target=, evidence=, and reason= so unresolved entries are testable instead of vague session notes." >&2
  printf '%s\n' "${violations[@]}" >&2
  exit 1
fi

echo "PASS regression-md-resolved-states"
