#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-020-SDS-010-SMS-050
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

labs_path="${NETWORK_LABS_ROOT:-}"
if [[ -z "${labs_path}" && -d "${repo_root}/../network-labs/current-lab" ]]; then
  labs_path="$(cd "${repo_root}/../network-labs" && pwd)"
fi

if [[ -z "${labs_path}" ]]; then
  archive_json="${tmp_dir}/archive.json"
  nix flake archive --json "path:${repo_root}" >"${archive_json}"
  labs_path="$(
    ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
      let
        archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
        labs = archived.inputs."network-labs" or null;
        labsPath = if labs == null then null else labs.path or null;
      in
        if labsPath == null then throw "FS-380 active-lab upstream selector egress: missing network-labs input path" else labsPath
    '
  )"
fi

selection_trace="$(
  LABS_PATH="${labs_path}" nix eval --impure --raw --expr '
    let current = import ((builtins.getEnv "LABS_PATH") + "/current-lab");
    in current.selection.traceId or ""
  '
)"
if [[ "${selection_trace}" != "FS-380-HDS-020-SDS-010" ]]; then
  echo "FAIL FS-380 active-lab upstream selector egress: current-lab must be selected to SIT FS-380-HDS-020-SDS-010, got ${selection_trace}" >&2
  exit 1
fi

check_inventory() {
  local label="$1"
  local inventory="$2"
  local output_json="${tmp_dir}/${label}.json"

  nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
    "${labs_path}/current-lab/intent.nix" \
    "${labs_path}/current-lab/${inventory}" \
    "${output_json}" >/dev/null

  jq -e --arg label "${label}" '
    def route_list($iface; $family):
      if $family == 4 then ($iface.routes.ipv4 // []) else ($iface.routes.ipv6 // []) end;

    def lane($iface):
      ($iface.backingRef.lane // {})
      | if type == "object" then . else {} end;

    def has_unscoped_rule($rules; $from; $to):
      any($rules[]?;
        (.fromInterface // "") == $from
        and (.toInterface // "") == $to
        and ((.sourcePrefixes // []) | length) == 0
        and ((.relationCardinality.unit // "") == "selector-forwarding-rule")
      );

    def has_return_route4($core; $via):
      any(route_list($core; 4)[]?;
        (.dst // "") == "10.20.20.0/24"
        and (.via4 // "") == $via
        and (.policyOnly // false) == true
        and (.reason // "") == "policy-table-internal-reachability"
        and (.intent.policyTableComplement // false) == true
        and (.intent.source // "") == "policy-default-lane"
        and (.lane.access // "") == "client-edge"
      );

    def has_return_route6($core; $via):
      any(route_list($core; 6)[]?;
        (.dst // "") == "fd42:0380:0020:0000:0000:0000:0000:0000/64"
        and (.via6 // "") == $via
        and (.policyOnly // false) == true
        and (.reason // "") == "policy-table-internal-reachability"
        and (.intent.policyTableComplement // false) == true
        and (.intent.source // "") == "policy-default-lane"
        and (.lane.access // "") == "client-edge"
      );

    def has_default_route4($iface; $via; $uplink):
      any(route_list($iface; 4)[]?;
        (.dst // "") == "0.0.0.0/0"
        and (.via4 // "") == $via
        and (.policyOnly // false) == true
        and (.reason // "") == "policy-table-default-reachability"
        and (.intent.policyTableDefaultComplement // false) == true
        and (.intent.source // "") == "policy-default-lane"
        and (.lane.access // "") == "client-edge"
        and (.lane.uplink // "") == $uplink
      );

    def has_default_route6($iface; $via; $uplink):
      any(route_list($iface; 6)[]?;
        (.dst // "") == "::/0"
        and (.via6 // "") == $via
        and (.policyOnly // false) == true
        and (.reason // "") == "policy-table-default-reachability"
        and (.intent.policyTableDefaultComplement // false) == true
        and (.intent.source // "") == "policy-default-lane"
        and (.lane.access // "") == "client-edge"
        and (.lane.uplink // "") == $uplink
      );

	    .control_plane_model.data."mini-smt"."internet-mode-verification" as $site
	    | [
	        ($site.runtimeTargets // {}) | to_entries[]?
	        | .value as $target
	        | (($target.effectiveRuntimeRealization.interfaces // {}) | to_entries[]?)
	        | select((.value.interfaceClass // null) == null)
	        | { target: $target.role, interface: .key, sourceKind: (.value.sourceKind // null), backingRef: (.value.backingRef // null) }
	      ] as $missingInterfaceClasses
	    | $site.runtimeTargets."mini-smt-internet-mode-verification-upstream-selector" as $upstream
	    | ($upstream.effectiveRuntimeRealization.interfaces // {}) as $interfaces
    | ($upstream.forwardingIntent.rules // []) as $rules
    | [
        $interfaces[]?
        | select(
            ((.backingRef.uplinks // []) | index("internet-vlan4") != null)
            and ((.backingRef.uplinks // []) | index("internet-vlan5") != null)
            and ((.backingRef.lane // null) == "default" or (lane(.).kind // null) == null)
          )
      ] as $cores
    | [
        $interfaces[]?
        | select(
            (lane(.).kind // "") == "access-uplink"
            and (lane(.).access // "") == "client-edge"
            and (lane(.).uplink // "") == "internet-vlan4"
          )
      ] as $vlan4
    | [
        $interfaces[]?
        | select(
            (lane(.).kind // "") == "access-uplink"
            and (lane(.).access // "") == "client-edge"
            and (lane(.).uplink // "") == "internet-vlan5"
          )
      ] as $vlan5
    | ($cores[0] // {}) as $core
    | ($vlan4[0] // {}) as $policy4
    | ($vlan5[0] // {}) as $policy5
    | {
        label: $label,
        coreRuntimeIfName: ($core.runtimeIfName // null),
        vlan4RuntimeIfName: ($policy4.runtimeIfName // null),
        vlan5RuntimeIfName: ($policy5.runtimeIfName // null),
	        selectorRuleCount: ($rules | length),
	        missingInterfaceClasses: $missingInterfaceClasses,
	        ok:
	          ($missingInterfaceClasses | length) == 0
	          and ($cores | length) == 1
          and ($vlan4 | length) == 1
          and ($vlan5 | length) == 1
          and ($core.interfaceClass.coreFacing // false) == true
          and ($policy4.interfaceClass.exitFacing // false) == true
          and ($policy5.interfaceClass.exitFacing // false) == true
          and has_unscoped_rule($rules; $policy4.runtimeIfName; $core.runtimeIfName)
          and has_unscoped_rule($rules; $core.runtimeIfName; $policy4.runtimeIfName)
          and has_unscoped_rule($rules; $policy5.runtimeIfName; $core.runtimeIfName)
          and has_unscoped_rule($rules; $core.runtimeIfName; $policy5.runtimeIfName)
          and has_return_route4($core; "10.10.0.6")
          and has_return_route4($core; "10.10.0.8")
          and has_return_route6($core; "fd42:380:ff:0:0:0:0:6")
          and has_return_route6($core; "fd42:380:ff:0:0:0:0:8")
          and has_default_route4($policy4; "10.10.0.4"; "internet-vlan4")
          and has_default_route4($policy5; "10.10.0.4"; "internet-vlan5")
          and has_default_route6($policy4; "fd42:380:ff:0:0:0:0:4"; "internet-vlan4")
          and has_default_route6($policy5; "fd42:380:ff:0:0:0:0:4"; "internet-vlan5")
      }
    | select(.ok)
  ' "${output_json}" >/dev/null || {
	    echo "FAIL FS-380 active-lab upstream selector egress (${label}): CPM must emit explicit interfaceClass for every runtime interface plus upstream-selector policy/core forwarding and policy-table tenant return routes for internet-vlan4 and internet-vlan5" >&2
	    jq '
	      .control_plane_model.data."mini-smt"."internet-mode-verification" as $site
	      | $site.runtimeTargets."mini-smt-internet-mode-verification-upstream-selector" as $upstream
	      | {
	          missingInterfaceClasses: [
	            ($site.runtimeTargets // {}) | to_entries[]?
	            | .value as $target
	            | (($target.effectiveRuntimeRealization.interfaces // {}) | to_entries[]?)
	            | select((.value.interfaceClass // null) == null)
	            | { target: $target.role, interface: .key, sourceKind: (.value.sourceKind // null), backingRef: (.value.backingRef // null) }
	          ],
	          rules: [
            ($upstream.forwardingIntent.rules // [])[]?
            | { relationId, direction, fromInterface, toInterface, sourcePrefixes, relationCardinality }
          ],
          interfaces:
            ($upstream.effectiveRuntimeRealization.interfaces // {})
            | with_entries({
                key,
                value: {
                  runtimeIfName: .value.runtimeIfName,
                  interfaceClass: .value.interfaceClass,
                  backingRef: .value.backingRef,
                  routes4: .value.routes.ipv4,
                  routes6: .value.routes.ipv6
                }
              })
        }
    ' "${output_json}" >&2
    exit 1
  }
}

check_inventory "nixos" "inventory-nixos.nix"
check_inventory "clab" "inventory-clab.nix"

echo "PASS FS-380 active-lab upstream selector egress"
