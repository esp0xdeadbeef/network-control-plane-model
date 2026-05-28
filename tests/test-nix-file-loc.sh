#!/usr/bin/env bash
# GAMP-ID: RTM-GUARD-CPM-LOC-001
# GAMP-SCOPE: guard-only; not SMT acceptance evidence
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
limit="${NIX_LOC_LIMIT:-200}"
hard_limit="${NIX_LOC_HARD_LIMIT:-500}"

mapfile -t oversized < <(
  cd "$repo_root"
  git ls-files -z '*.nix' \
    | xargs -0 -r wc -l \
    | awk -v limit="$limit" '
      $2 != "total" &&
      $2 != "flake.nix" &&
      $2 != "flake.lock" &&
      $2 !~ /(^|\/)(tests?|fixtures)\// &&
      $1 > limit {
        print $1 " " $2
      }' \
    | sort -nr
)

((${#oversized[@]} == 0)) && exit 0

printf 'Nix implementation files over %s lines must be split; flake.nix and flake.lock are excluded as API/lock shims.\n' "$limit" >&2
printf '%s\n' "${oversized[@]}" >&2
exit 1
