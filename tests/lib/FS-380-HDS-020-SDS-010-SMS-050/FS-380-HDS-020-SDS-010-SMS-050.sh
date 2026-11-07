#!/usr/bin/env bash
# GAMP-ID: FS-380-HDS-020-SDS-010-SMS-050
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
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

labs_root="${NETWORK_LABS_ROOT:-${repo_root}/../network-labs}"
# FS-380-HDS-020-SDS-010-SMS-050: the internet-mode-verification lab is the SIT
# FS-380-HDS-020-SDS-010 selection. Generate it deterministically for this case
# rather than depending on the shared, single-valued current-lab selection.
mkdir -p "${tmp_dir}/lab"
ln -s "${labs_root}/GAMP" "${tmp_dir}/lab/GAMP"
NETWORK_LABS_CURRENT_LAB_DIR="${tmp_dir}/lab/current-lab" \
  bash "${labs_root}/scripts/select-current-lab.sh" SIT FS-380-HDS-020-SDS-010 >/dev/null
labs_path="${tmp_dir}/lab"

selection_ok="$(
  LABS_PATH="${labs_path}" nix eval --no-write-lock-file --impure --raw --expr '
    let selection = import ((builtins.getEnv "LABS_PATH") + "/current-lab/metadata.nix");
        selected =
          (
            (selection.layer or "") == "SIT"
            && (selection.selector or "") == "FS-380-HDS-020-SDS-010"
          )
          || (
            (selection.layer or "") == "SMT"
            && (selection.selector or "") == "internet-mode-verification"
          )
          || ((selection.traceId or "") == "FS-380-HDS-020-SDS-010-SMS-050");
    in if selected then "true" else "false"
  '
)"
selection_label="$(
  LABS_PATH="${labs_path}" nix eval --no-write-lock-file --impure --raw --expr '
    let selection = import ((builtins.getEnv "LABS_PATH") + "/current-lab/metadata.nix");
    in "${selection.layer or ""}:${selection.selector or ""}:${selection.traceId or ""}"
  '
)"
if [[ "${selection_ok}" != "true" ]]; then
  echo "FAIL FS-380 active-lab upstream selector egress: current-lab must be selected to SIT FS-380-HDS-020-SDS-010 or SMT internet-mode-verification, got ${selection_label}" >&2
  exit 1
fi

check_inventory() {
  local label="$1"
  local inventory="$2"
  local output_json="${tmp_dir}/${label}.json"

  nix run --no-write-lock-file "path:${repo_root}#compile-and-build-control-plane-model" -- \
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

    def has_return_route4($core; $uplink):
      any(route_list($core; 4)[]?;
        (.policyOnly // false) == true
        and (.reason // "") == "policy-table-internal-reachability"
        and (.intent.policyTableComplement // false) == true
        and (.intent.source // "") == "policy-default-lane"
        and (.lane.access // "") == "client-edge"
        and (.lane.uplink // "") == $uplink
      );

    def has_return_route6($core; $uplink):
      any(route_list($core; 6)[]?;
        (.policyOnly // false) == true
        and (.reason // "") == "policy-table-internal-reachability"
        and (.intent.policyTableComplement // false) == true
        and (.intent.source // "") == "policy-default-lane"
        and (.lane.access // "") == "client-edge"
        and (.lane.uplink // "") == $uplink
      );

    def has_default_route4($iface; $uplink):
      any(route_list($iface; 4)[]?;
        (.dst // "") == "0.0.0.0/0"
        and (.policyOnly // false) == true
        and (.reason // "") == "policy-table-default-reachability"
        and (.intent.policyTableDefaultComplement // false) == true
        and (.intent.source // "") == "policy-default-lane"
        and (.lane.access // "") == "client-edge"
        and (.lane.uplink // "") == $uplink
      );

    def has_default_route6($iface; $uplink):
      any(route_list($iface; 6)[]?;
        (.dst // "") == "::/0"
        and (.policyOnly // false) == true
        and (.reason // "") == "policy-table-default-reachability"
        and (.intent.policyTableDefaultComplement // false) == true
        and (.intent.source // "") == "policy-default-lane"
        and (.lane.access // "") == "client-edge"
        and (.lane.uplink // "") == $uplink
      );

    def fs380_site:
      .control_plane_model.data."mini-smt" as $sites
      | ($sites."internet-mode-verification" // $sites."FS-380-HDS-020-SDS-010-SMS-050");

    def fs380_target($site; $suffix):
      $site.runtimeTargets[("mini-smt-internet-mode-verification-" + $suffix)]
      // $site.runtimeTargets[("mini-smt-fs-380-hds-020-sds-010-sms-050-" + $suffix)];

	    . as $root
	    | fs380_site as $site
	    | [
	        ($site.runtimeTargets // {}) | to_entries[]?
	        | .value as $target
	        | (($target.effectiveRuntimeRealization.interfaces // {}) | to_entries[]?)
	        | select((.value.interfaceClass // null) == null)
	        | { target: $target.role, interface: .key, sourceKind: (.value.sourceKind // null), backingRef: (.value.backingRef // null) }
	      ] as $missingInterfaceClasses
	    | fs380_target($site; "upstream-selector") as $upstream
	    | ($upstream.effectiveRuntimeRealization.interfaces // {}) as $interfaces
    | ($upstream.forwardingIntent.rules // []) as $rules
    | [
        $interfaces[]?
        | select(
            ((.backingRef.uplinks // []) | length) == 2
            and ((.backingRef.lane // null) == "default" or (lane(.).kind // null) == null)
          )
      ] as $cores
    | ($cores[0] // {}) as $core
    | ($core.backingRef.uplinks // []) as $activeUplinks
    | [
        $interfaces[]?
        | . as $iface
        | select(
            (lane($iface).kind // "") == "access-uplink"
            and (lane($iface).access // "") == "client-edge"
            and (($activeUplinks | index(lane($iface).uplink // "")) != null)
          )
      ] as $uplinkInterfaces
    # FS-481/FS-322: the policy access-uplink lane set is the access scope
    # modeled selection, not the physical uplink inventory. The core being
    # eligible for both surfaces does not install a lane for a surface the
    # tenant did not select; copying the unselected lane would be a duplicate
    # route meaning (FS-315). Derive the expected surfaces from the compiled
    # selection and require exactly one lane, with both forwarding directions
    # and the policy-table return/default complements, per selected surface.
    | ($root.forwardingOut.enterprise."mini-smt".site."FS-380-HDS-020-SDS-010-SMS-050".nodes."client-edge".selects // []) as $selections
    | ([ $selections[]? | .surface // empty ] | unique) as $selectedUplinks
    | {
        label: $label,
        activeUplinks: $activeUplinks,
        selectedUplinks: $selectedUplinks,
        coreRuntimeIfName: ($core.runtimeIfName // null),
        laneInterfaces: [ $uplinkInterfaces[]? | {name: .runtimeIfName, uplink: lane(.).uplink} ],
	        selectorRuleCount: ($rules | length),
	        missingInterfaceClasses: $missingInterfaceClasses,
	        ok:
	          ($missingInterfaceClasses | length) == 0
	          and ($cores | length) == 1
          and ($selections | length) > 0
          and (($uplinkInterfaces | map(lane(.).uplink) | sort) == ($selectedUplinks | sort))
          and ($core.interfaceClass.coreFacing // false) == true
          and all($uplinkInterfaces[]; (.interfaceClass.exitFacing // false) == true)
          and all($uplinkInterfaces[] as $policy
            | has_unscoped_rule($rules; $policy.runtimeIfName; $core.runtimeIfName)
            and has_unscoped_rule($rules; $core.runtimeIfName; $policy.runtimeIfName)
            and has_return_route4($core; lane($policy).uplink)
            and has_return_route6($core; lane($policy).uplink)
            and has_default_route4($policy; lane($policy).uplink)
            and has_default_route6($policy; lane($policy).uplink))
      }
    | select(.ok)
    ' "${output_json}" >/dev/null || {
	    echo "FAIL FS-380 active-lab upstream selector egress (${label}): CPM must emit explicit interfaceClass for every runtime interface plus upstream-selector policy/core forwarding and policy-table tenant return/default routes for the selected active uplinks" >&2
	    jq '
        def fs380_site:
          .control_plane_model.data."mini-smt" as $sites
          | ($sites."internet-mode-verification" // $sites."FS-380-HDS-020-SDS-010-SMS-050");

        def fs380_target($site; $suffix):
          $site.runtimeTargets[("mini-smt-internet-mode-verification-" + $suffix)]
          // $site.runtimeTargets[("mini-smt-fs-380-hds-020-sds-010-sms-050-" + $suffix)];

	      fs380_site as $site
	      | fs380_target($site; "upstream-selector") as $upstream
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
