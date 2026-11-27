#!/usr/bin/env bash
# GAMP-ID: FS-381-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

# Exit-route placement, asserted against the table a target's traffic is
# actually selected into -- for every target, every address family, and every
# kind of exit.
#
# The assertions already in this trace chain ask "does some interface of this
# hop carry a default route?". That is not SMS-020. The clause is
#
#   "For a routing table selected for a source scope by a modeled rule, require
#    a next hop toward the selected exit."
#
# On 2026-11-21 a live cobalt router failed exactly that, at a provider-overlay
# exit: table 1003 ended up carrying a default the model does not contain
# instead of the one it does, and tenant IPv6 died while IPv4 worked.
#
# So this case asserts the properties that failure violated, with no reference
# to a core, an overlay, or a provider. It runs over TWO fixtures on purpose:
#
#   single-wan                  -- an ISP WAN uplink, no overlay node at all
#   wireguard-provider-overlay  -- provider (overlay) uplinks, the shape the
#                                 live failure occurred on
#
# A predicate that only holds for one of those is a predicate about that
# fixture, not about the model. Both must satisfy it, and the test fails if
# either kind of exit is absent (so it cannot pass by only exercising one).
#
# Assertions, per fixture, per target, per family:
#
#   (1) selectability -- a default must be in the table its own interface
#       allocates (the allocation IS the modelled rule; no separate rule list is
#       emitted), and a core must have exactly ONE table shared by all its
#       interfaces so forwarded payload reaches the exit default. "The interface
#       allocates a slot somewhere" is NOT the assertion.
#   (2) no cross-device competition -- two interfaces must not install the same
#       (table, destination, metric) default for one family. `ip route replace`
#       keys on that tuple, so the second installation would silently evict the
#       first and the surviving route would depend on order. This is the
#       mechanism that lost the IPv6 exit route on 2026-11-21.

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
  flake-archive-offline --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

labs_root="$(flake_input_path network-labs)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

# ISP uplink (no overlay) and provider-overlay uplink. Both must pass.
fixtures=(single-wan wireguard-provider-overlay)

compile_fixture() {
  local fixture="$1" out="$2"
  nix eval --no-write-lock-file --impure --json --expr '
    let
      flake = builtins.getFlake "'"path:${repo_root}"'";
    in
      flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
        inputPath = "'"${labs_root}/examples/${fixture}/intent.nix"'";
        inventoryPath = "'"${labs_root}/examples/${fixture}/inventory-nixos.nix"'";
      }
  ' >"${out}"
}

# Flatten every default route of every target, tagged with the table the
# interface allocates. A route may leave `tableId` out when it belongs to the
# interface's own policy table, so the interface allocation is the authority.
flatten_defaults() {
  jq -r '
    [ .control_plane_model.data[][] ][0] as $site
    | $site.runtimeTargets as $targets
    | [ $targets | to_entries[] as $t
        | ($t.value.effectiveRuntimeRealization.targetOriginatedSelection.tableId // null) as $sel
        | ([ ($t.value.effectiveRuntimeRealization.interfaces // {}) | .[] | (.routeSelectionRules // []) | .[] | .tableId ]
           | map(select(. != null))) as $ruleTables
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
          , selectionTable: $sel
          , ruleTables: $ruleTables
          , dst: .dst
          , metric: (.metric // 50)
          , policyOnly: (.policyOnly // false)
          , intentKind: (.intent.kind // null)
          }
      ]
  ' "$1"
}

total_defaults=0
saw_plain_isp=0
saw_overlay=0

for fixture in "${fixtures[@]}"; do
  model="${tmp_dir}/${fixture}.json"
  compile_fixture "${fixture}" "${model}"

  defaults="${tmp_dir}/${fixture}-defaults.json"
  flatten_defaults "${model}" >"${defaults}"

  count="$(jq 'length' "${defaults}")"
  if [[ "${count}" == "0" ]]; then
    echo "FAIL selected-table-exit-route: fixture ${fixture} models no exit default route, so the clause is vacuous there" >&2
    exit 1
  fi
  total_defaults=$((total_defaults + count))

  # Record which kinds of exit this fixture actually exercises. `single-wan`
  # has no overlay interface; the provider fixture has overlay interfaces.
  # Both counters must be non-zero at the end, or the test proved only one
  # shape and would not have caught a defect specific to the other.
  if jq -e 'any(.[]; (.iface | startswith("overlay")) | not)' "${defaults}" >/dev/null; then
    saw_plain_isp=$((saw_plain_isp + 1))
  fi
  if jq -e 'any(.[]; .iface | startswith("overlay"))' "${defaults}" >/dev/null; then
    saw_overlay=$((saw_overlay + 1))
  fi

  # ---- (1) the modelled selection reaches the exit default -------------------
  #
  # Two predicates, both about the table a modelled lookup actually selects.
  # Confirmed by measurement on this model: `routeSelectionRules` is not emitted
  # at all -- an interface's `policyRoutingAllocation` (priority + tableId) IS
  # the modelled rule. So "named by a routeSelectionRules entry" cannot be
  # checked here; the allocation is the rule, and the assertions below use it.
  #
  #   1a. A default installed by an interface must be in THAT interface's own
  #       allocated table. A default placed into another scope's table is reachable
  #       only by looking up someone else's selection.
  #
  #   1b. On a CORE, every interface must share ONE table. The core's fabric
  #       handoff and its exit deliberately share a slot so payload forwarded in
  #       from the fabric reaches the exit's default. If the exit gets a table of
  #       its own (measured: overlay-wg-egress 1005 while the fabric ingress and
  #       the target-originated selection were 1003), the forwarded path selects
  #       1003 and the exit default is unreachable -- the exit is "modelled" but
  #       nothing selects it. That is the 2026-11-21 cobalt IPv6 failure.
  #
  # Per-lane tables on `policy` and the selectors are correct and are NOT
  # splits: each lane has its own rule, and 1a makes its default reachable.
  unplaced="$(jq -r '
    .[]
    | select(.table != null and .table != .allocatedTable)
    | "\(.target): \(.dst) (family \(.family)) on \(.iface) is in table \(.table), but that interface allocates \(.allocatedTable)"
  ' "${defaults}")"
  coreSplit="$(jq -r '
    .control_plane_model.data[][] as $site
    | $site.runtimeTargets | to_entries[]
    | select(.value.role == "core")
    | .key as $t
    | [ .value.effectiveRuntimeRealization.interfaces // {} | to_entries[]
        | { iface: .key, table: (.value.policyRoutingAllocation.tableId // null) } ] as $ifs
    | ([ $ifs[].table ] | unique) as $tables
    | select(($tables | length) > 1)
    | "\($t) is a core whose interfaces select \($tables | join(", ")) -- the fabric ingress selects one and an exit default may live in another"
  ' "${model}")"
  nullTable="$(jq -r '
    .[]
    | select(.table == null)
    | "\(.target): \(.dst) (family \(.family)) on \(.iface) has no table and its interface allocates none"
  ' "${defaults}")"
  unplaced="$(printf '%s\n%s\n%s\n' "${unplaced}" "${coreSplit}" "${nullTable}" | sed '/^$/d')"
  if [[ -n "${unplaced}" ]]; then
    echo "FAIL selected-table-exit-route [${fixture}]: an exit default is in no selectable table" >&2
    while IFS= read -r line; do printf '  %s\n' "${line}" >&2; done <<<"${unplaced}"
    echo "  SMS-020: a route in a table no modeled rule selects for this source is not a path off the scope." >&2
    exit 1
  fi

  # ---- (2) no two interfaces compete for one (table, family) default -----
  clashes="$(jq -r '
    group_by([.target, .table, .family, .dst, .metric])
    | map(select(([.[].iface] | unique | length) > 1))
    | .[]
    | "\(.[0].target): table \(.[0].table) \(.[0].dst) metric \(.[0].metric) claimed by \([.[].iface] | unique | join(", "))"
  ' "${defaults}")"

  if [[ -n "${clashes}" ]]; then
    echo "FAIL selected-table-exit-route [${fixture}]: two interfaces install the same default into one table" >&2
    while IFS= read -r line; do printf '  %s\n' "${line}" >&2; done <<<"${clashes}"
    echo "  'ip route replace' keys on (table, destination, metric): one installation evicts the other and the result depends on order." >&2
    exit 1
  fi

  echo "  ok ${fixture}: ${count} exit default routes"
done

# Vacuity guards: the clause must have been exercised for BOTH kinds of exit,
# otherwise a green run says nothing about the shape it never saw.
if [[ "${saw_plain_isp}" == "0" ]]; then
  echo "FAIL selected-table-exit-route: no fixture exercised a non-overlay (ISP) exit, so that shape is unproven" >&2
  exit 1
fi
if [[ "${saw_overlay}" == "0" ]]; then
  echo "FAIL selected-table-exit-route: no fixture exercised an overlay (provider) exit, so that shape is unproven" >&2
  exit 1
fi

echo "PASS selected-table-exit-route (${total_defaults} exit default routes across ${#fixtures[@]} fixtures: ISP and provider-overlay exits both exercised)"
