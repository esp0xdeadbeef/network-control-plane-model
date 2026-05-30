#!/usr/bin/env bash
# GAMP-ID: RTM-GUARD-CPM-STRUCTURE-001
# GAMP-SCOPE: guard-only; not SMT acceptance evidence
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

matches_file="${tmp_dir}/structural-keyword-matches.tsv"
: >"${matches_file}"

fail() {
  printf 'FAIL structural-keyword-boundary: %s\n' "$*" >&2
}

scan_group() {
  local group="$1"
  local pattern="$2"

  rg \
    --no-heading \
    --line-number \
    --with-filename \
    --ignore-case \
    --glob '!fixtures/**' \
    --glob '!result/**' \
    --glob '!result-*' \
    --glob '!*.lock' \
    --glob '!*.json' \
    --glob '!*.jsonl' \
    --glob '!*.tsv' \
    --glob '!tests/test-structural-keyword-boundary.sh' \
    --regexp "${pattern}" \
    "${repo_root}/src" \
    "${repo_root}/lib" \
    "${repo_root}/invariants" \
    2>/dev/null \
    | while IFS=: read -r file line text; do
        if [[ "${text}" =~ ^[[:space:]]*(import|source|\.|#include)[[:space:]] ]]; then
          continue
        fi
        file="${file#"${repo_root}/"}"
        printf '%s\t%s\t%s\t%s\n' "${group}" "${file}" "${line}" "${text}"
      done >>"${matches_file}" || true
}

scan_group \
  "concrete-lab-identity" \
  '\b(esp0xdeadbeef|enterpriseA|enterpriseB|espbranch|site-a|site-b|site-c|s-router|b-router|c-router|hetzner|s-sigma)\b'

scan_group \
  "generated-topology-name-parser" \
  '(builtins\.(match|split)|hasInfix|hasPrefix|hasSuffix|replaceStrings|containsToken|suffixAfter).*(link::|adj::|access::|uplink::|p2p-|--access-|--uplink-|core-|policy-|upstream-|downstream-)'

scan_group \
  "hardcoded-example-endpoint-or-tenant" \
  '\b(tenant-a|tenant-b|site-dns-mgmt|sitec-dns-dmz|sitec-public-dns|dmz-nebula|web01|nebula01)\b'

if [[ ! -s "${matches_file}" ]]; then
  echo "PASS structural-keyword-boundary"
  exit 0
fi

fail "concrete lab identities, hardcoded example endpoints, or generated topology-name parsing were found in implementation files."
fail "The control-plane model may carry explicit role, lane, service, and protocol fields, but it must not recover structure by parsing generated names such as p2p-, link::, --access-, or --uplink-."
fail "Legitimate address/protocol parsers are covered by focused tests; this guard only blocks topology inference from rendered or generated strings."

awk -F '\t' '
  {
    key = $1 "\t" $2;
    count[key]++;
    groupCount[$1]++;
    fileCount[$2]++;
  }
  END {
    print "FAIL structural-keyword-boundary: grouped match counts:" > "/dev/stderr";
    for (group in groupCount) {
      printf "FAIL structural-keyword-boundary:   %s\t%d\n", group, groupCount[group] > "/dev/stderr";
    }
    print "FAIL structural-keyword-boundary: files with matches:" > "/dev/stderr";
    for (file in fileCount) {
      printf "FAIL structural-keyword-boundary:   %s\t%d\n", file, fileCount[file] > "/dev/stderr";
    }
  }
' "${matches_file}"

fail "full match list follows: group<TAB>file<TAB>line<TAB>text"
sed 's/^/FAIL structural-keyword-boundary:   /' "${matches_file}" >&2

exit 1
