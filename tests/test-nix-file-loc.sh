#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
limit="${NIX_LOC_LIMIT:-200}"
hard_limit="${NIX_LOC_HARD_LIMIT:-500}"
regression_note="${repo_root}/regression.md"
start_marker="<!-- nix-file-loc:start -->"
end_marker="<!-- nix-file-loc:end -->"

mapfile -t oversized < <(
  cd "$repo_root"
  git ls-files -z '*.nix' \
    | xargs -0 -r wc -l \
    | awk -v limit="$limit" '
      $2 != "total" && $2 !~ /(^|\/)(tests?|fixtures)\// && $1 > limit {
        print $1 " " $2
      }' \
    | sort -nr
)

((${#oversized[@]} == 0)) && exit 0

if [[ ! -f "$regression_note" ]]; then
  printf 'Nix files over %s lines require regression.md LOC state and reason notes.\n' "$limit" >&2
  printf '%s\n' "${oversized[@]}" >&2
  exit 1
fi

note_block="$(
  awk -v start="$start_marker" -v end="$end_marker" '
    $0 == start { in_block = 1; next }
    $0 == end { in_block = 0; next }
    in_block && $0 !~ /^#/ && $0 !~ /^$/ { print }
  ' "$regression_note"
)"

fail=0
hard_fail=0

for entry in "${oversized[@]}"; do
  lines="${entry%% *}"
  path="${entry#* }"
  note_line="$(printf '%s\n' "$note_block" | awk -v path="$path" '$2 == path { print; exit }')"

  if [[ -z "$note_line" ]]; then
    printf 'Missing regression.md LOC note for %s (%s lines).\n' "$path" "$lines" >&2
    fail=1
    continue
  fi

  noted_lines="$(awk '{ print $1 }' <<<"$note_line")"
  state="$(sed -n 's/.*|[[:space:]]*state=\([^|]*\).*/\1/p' <<<"$note_line" | xargs)"
  reason="$(sed -n 's/.*|[[:space:]]*reason=\(.*\)$/\1/p' <<<"$note_line" | xargs)"

  if [[ "$noted_lines" != "$lines" ]]; then
    printf 'Stale regression.md LOC note for %s: measured %s, noted %s.\n' "$path" "$lines" "$noted_lines" >&2
    fail=1
  fi

  if [[ -z "$state" || -z "$reason" ]]; then
    printf 'LOC note for %s must include state=... and reason=...\n' "$path" >&2
    fail=1
  fi

  if (( lines >= hard_limit )); then
    hard_fail=1
    if [[ "$state" != "split-required" ]]; then
      printf 'LOC note for %s must use state=split-required at or above %s lines.\n' "$path" "$hard_limit" >&2
      fail=1
    fi
  elif [[ "$state" != "watch" ]]; then
    printf 'LOC note for %s must use state=watch below %s lines.\n' "$path" "$hard_limit" >&2
    fail=1
  fi
done

if (( fail != 0 )); then
  printf '\nExpected format inside %s / %s:\n' "$start_marker" "$end_marker" >&2
  printf '<lines> <path> | state=watch|split-required | reason=<single responsibility or split target>\n' >&2
  exit 1
fi

if (( hard_fail != 0 )); then
  printf 'Tracked Nix files at or above %s lines must be split before this test can pass.\n' "$hard_limit" >&2
  printf '%s\n' "${oversized[@]}" | awk -v hard="$hard_limit" '$1 >= hard' >&2
  exit 1
fi
