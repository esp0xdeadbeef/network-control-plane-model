#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd gron
require_cmd jq
require_cmd nix
require_cmd rg

flake_input_path() {
  local input_name="$1"
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

labs_path="$(flake_input_path network-labs)"
output_json="$(mktemp)"
gron_txt="$(mktemp)"
trap 'rm -f "${output_json}" "${gron_txt}"' EXIT

nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_path}/examples/tri-site-s-router-overlay-egress/intent.nix" \
  "${labs_path}/examples/tri-site-s-router-overlay-egress/inventory.nix" \
  "${output_json}" >/dev/null

gron "${output_json}" >"${gron_txt}"

require_gron_regex() {
  local pattern="$1"
  if ! rg -q "${pattern}" "${gron_txt}"; then
    echo "FAIL runtime-origin-loopback-egress: missing gron regex: ${pattern}" >&2
    exit 1
  fi
}

require_gron_regex 'runtimeOriginEgress\.enabled = true;'
require_gron_regex '\.runtimeOriginEgress\.sourcePrefixes\[[0-9]+\]\.prefix = "([^"]+/32|[^"]+/128)";'
require_gron_regex '\.routes\.ipv[46]\[[0-9]+\]\.preferredSource = "[^"]+";'

jq -e '
  def prefix_addr:
    split("/")[0];
  def family($prefix):
    if ($prefix | contains(":")) then 6 else 4 end;
  def default_route($family):
    if $family == 4 then "0.0.0.0/0" else "::/0" end;
  def routes_for($iface; $family):
    if $family == 4 then ($iface.value.routes.ipv4 // []) else ($iface.value.routes.ipv6 // []) end;
  def default_preferred_routes($target; $source):
    ($target.effectiveRuntimeRealization.interfaces // {})
    | to_entries
    | map(
        . as $iface
        | routes_for($iface; family($source.prefix))
        | map(select(
            (.dst // null) == default_route(family($source.prefix))
            and (.preferredSource // null) == ($source.prefix | prefix_addr)
          ))
        | length
      )
    | add // 0;
  def default_routes_with_preferred_source($target):
    ($target.effectiveRuntimeRealization.interfaces // {})
    | to_entries
    | [
        .[] as $iface
        | (($iface.value.routes.ipv4 // []) + ($iface.value.routes.ipv6 // []))[]
        | select((.dst == "0.0.0.0/0" or .dst == "::/0") and (.preferredSource // null) != null)
      ];
  [
    .control_plane_model.data
    | to_entries[] as $enterprise
    | $enterprise.value
    | to_entries[] as $site
    | ($site.value.runtimeTargets // {})
    | to_entries[]
    | select((.value.runtimeOriginEgress.enabled // false) == true)
  ] as $targets
  | ($targets | length) > 0
  and all($targets[];
    .value as $target
    |
    (.value.runtimeOriginEgress.sourcePrefixes // []) as $sources
    | ($sources | length) > 0
    and all($sources[]; default_preferred_routes($target; .) == 1)
    and (default_routes_with_preferred_source($target) | length) == ($sources | length)
  )
' "${output_json}" >/dev/null || {
  echo "FAIL runtime-origin-loopback-egress: every runtime-origin source must annotate exactly one existing default route with preferredSource, without synthesizing extra preferred-source defaults" >&2
  exit 1
}

echo "PASS runtime-origin-loopback-egress"
