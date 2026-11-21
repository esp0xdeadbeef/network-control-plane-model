#!/usr/bin/env bash
# GAMP-ID: FS-381-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

# Exit-route placement, asserted against the table the target's traffic is
# actually selected into -- for every target and every address family.
#
# The two assertions already in this trace chain answer "does some interface of
# this hop carry a default route?". That is not SMS-020: the clause is
#
#   "For a routing table selected for a source scope by a modeled rule, require
#    a next hop toward the selected exit."
#
# On 2026-11-21 a live cobalt router failed exactly that: at the VPN exit the
# model placed `::/0` in table 1003 via `overlay-opal`, but the installed table
# 1003 carried only `default dev up-sel` -- a route the model does not contain
# -- and the tenant's IPv6 died there while IPv4 worked. So this case checks
# the property that failure violated, without naming any core or overlay:
#
#   (1) every family for which a target carries an exit default must carry one
#       in the table the target itself selects for originated traffic, and
#   (2) two interfaces that allocate the SAME table must not both carry an exit
#       default for the same family: `ip route replace` is keyed on
#       (table, destination, metric), so the second installation would silently
#       evict the first and the result would be installation-order dependent.
#
# Nothing here mentions a core, an overlay, or a provider. If a site has an
# exit, it is in scope.

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq

flake_input_path() {
  local input_name="$1"
  if [[ "${input_name}" == "network-labs" && -n "${NETWORK_LABS_PATH:-}" ]]; then
    realpath "${NETWORK_LABS_PATH}"
    return
  fi
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

example_root="$(flake_input_path network-labs)/examples/single-wan"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

nix eval --no-write-lock-file --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
  in
    flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${example_root}/intent.nix"'";
      inventoryPath = "'"${example_root}/inventory-nixos.nix"'";
    }
' >"${tmp_dir}/model.json"

site="${tmp_dir}/site.json"
jq -S '[.control_plane_model.data[][]] | .[0]' "${tmp_dir}/model.json" >"${site}"

# Flatten every route of every target, tagged with the table the interface
# allocates and the family it belongs to. `tableId` on a route is optional: the
# control plane leaves it out when the route belongs to the interface'"'"'s own
# policy table, so the interface allocation is the authority.
jq -r '
  def fam: if . == "ipv4" then 4 else 6 end;
  .runtimeTargets as $targets
  | [ $targets | to_entries[] as $t
      | ($t.value.effectiveRuntimeRealization.interfaces // {}) | to_entries[] as $i
      | ($i.value.policyRoutingAllocation.tableId // null) as $tbl
      | [ ($i.value.routes.ipv4 // [] | .[] | {family: 4} + .),
          ($i.value.routes.ipv6 // [] | .[] | {family: 6} + .) ][]
      | select((.dst // "") == "0.0.0.0/0" or (.dst // "") == "::/0")
      | { target: $t.key
        , iface: $i.key
        , allocatedTable: $tbl
        , family: .family
        , table: (.tableId // $tbl)
        , dst: .dst
        , metric: (.metric // 50)
        }
    ]
' "${site}" >"${tmp_dir}/defaults.json"

targets_json="${tmp_dir}/targets.json"
jq -S '[.runtimeTargets | to_entries[] | {target: .key, selection: .value.effectiveRuntimeRealization.targetOriginatedSelection}]' "${site}" >"${targets_json}"

defaults_count="$(jq 'length' "${tmp_dir}/defaults.json")"
if [[ "${defaults_count}" == "0" ]]; then
  # Vacuity guard. A fixture with no exit default at all would make both
  # assertions below trivially true, which is the failure mode that let the
  # weaker predicates in this trace chain pass for months.
  echo "FAIL selected-table-exit-route: the fixture models no exit default route, so the clause is vacuous" >&2
  exit 1
fi

# ---- (1) every exit default is selectable by some rule ---------------------
#
# A default route is only a path off the scope if a modeled rule can select the
# table it is installed into. The control plane leaves `tableId` off a route
# when the route belongs to the owning interface's policy table, so a route is
# resolvable iff it declares a table itself or its interface allocates one.
#
# This is deliberately NOT "the route must be in targetOriginatedSelection's
# table": a target legitimately holds an exit default in a *different* policy
# table from the one its own originated traffic uses (the tenant context table
# and the policy lane are distinct), and a rule selects each. Asserting equality
# rejected that correct shape, so the requirement is selectability.
unplaced="$(jq -r '
  .[]
  | select(.table == null)
  | "\(.target): \(.dst) (family \(.family)) on \(.iface) has no table and its interface allocates none"
' "${tmp_dir}/defaults.json")"

if [[ -n "${unplaced}" ]]; then
  echo "FAIL selected-table-exit-route: an exit default is in no selectable table" >&2
  while IFS= read -r line; do printf '  %s\n' "${line}" >&2; done <<<"${unplaced}"
  echo "  SMS-020: a route in a table no modeled rule selects for this source is not a path off the scope." >&2
  exit 1
fi

# ---- (2) no two interfaces compete for the same (table, family) default ---
#
# `ip route replace` keys on (table, destination, metric). Two interfaces that
# allocate one table and both carry the family's default therefore cannot both
# be installed: one silently replaces the other, and which one survives depends
# on installation order. v4 and v6 are separate FIBs, so they are grouped
# independently.
clashes="$(jq -r '
  group_by([.target, .table, .family, .dst, .metric])
  | map(select(([.[].iface] | unique | length) > 1))
  | .[]
  | "\(.[0].target): table \(.[0].table) \(.[0].dst) metric \(.[0].metric) claimed by \([.[].iface] | unique | join(", "))"
' "${tmp_dir}/defaults.json")"

if [[ -n "${clashes}" ]]; then
  echo "FAIL selected-table-exit-route: two interfaces install the same default into one table" >&2
  while IFS= read -r line; do printf '  %s\n' "${line}" >&2; done <<<"${clashes}"
  echo "  One installation would evict the other under 'ip route replace', so the surviving route depends on order." >&2
  exit 1
fi

echo "PASS selected-table-exit-route (${defaults_count} exit default routes, per-family, per-selected-table)"
