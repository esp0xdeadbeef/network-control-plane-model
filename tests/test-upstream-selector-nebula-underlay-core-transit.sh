#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
archive_json="$(mktemp)"
output_json="$(mktemp)"
violations_json="$(mktemp)"
overlay_policy_case="$(mktemp --suffix=.nix)"
overlay_policy_json="$(mktemp)"
trap 'rm -f "${archive_json}" "${output_json}" "${violations_json}" "${overlay_policy_case}" "${overlay_policy_json}"' EXIT

nix flake archive --json "path:${repo_root}" >"${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
      labsPath = if labs == null then null else labs.path or null;
    in
      if labsPath == null then throw "tests: missing archived network-labs input path" else labsPath
  '
)"

nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
  "${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
  "${output_json}" >/dev/null

jq -e '
  .control_plane_model.data
  | [
      to_entries[] as $enterprise
      | $enterprise.value
      | to_entries[] as $site
      | $site.value.runtimeTargets
      | to_entries[]
      | select((.value.role // "") == "upstream-selector")
      | (.value.forwardingIntent.rules // [])[]
      | select(
          (.action == "accept")
          and (.fromInterface == "core-nebula")
          and (.toInterface == "core-isp")
          and ((.trafficType // "any") == "any")
          and ((.sourceFiles // []) == [])
          and ((.sourcePrefixes // []) == [])
        )
    ]
  | length == 0
	' "${output_json}" >/dev/null || {
  cat >&2 <<'EOF'
FAIL upstream-selector nebula underlay core transit.

Overlay ingress must not get a broad upstream-selector firewall allowance to
the WAN core. Underlay endpoint reachability may only open the modeled Nebula
traffic type, and runtime-origin egress must be source-scoped to explicit
loopback host prefixes.
EOF
  exit 1
}

jq -e '
  .control_plane_model.data
  | [
      to_entries[] as $enterprise
      | $enterprise.value
      | to_entries[] as $site
      | $site.value.runtimeTargets
      | to_entries[]
      | select((.value.role // "") == "upstream-selector")
      | (.value.forwardingIntent.rules // [])[]
      | select(
          (.action == "accept")
          and (.fromInterface == "core-nebula")
          and (.toInterface == "core-isp")
          and (.trafficType == "nebula-storage")
          and (.relationId == "allow-siteb-nebula-underlay-to-wan")
          and (.intent.kind == "overlay-underlay-reachability")
          and (.intent.source == "overlay-underlay-endpoint")
          and (.intent.overlay == "east-west")
        )
    ]
  | length == 1
' "${output_json}" >/dev/null || {
  cat >&2 <<'EOF'
FAIL upstream-selector nebula underlay core transit.

Expected one narrow core-nebula -> core-isp firewall allowance for modeled
Nebula underlay endpoint reachability. The rule must carry the Nebula traffic
type and overlay-underlay endpoint intent so it cannot become a generic WAN
bypass.
EOF
	  exit 1
	}

cat >"${overlay_policy_case}" <<EOF
let
  common = {
    laneKind = iface: iface.laneKind or null;
    laneAccess = iface: iface.laneAccess or null;
    laneUplink = iface: iface.laneUplink or null;
    uplinks = iface: iface.uplinks or [ ];
  };
  endpointContext = import ${repo_root}/src/cpm/firewall-intent/rules/endpoint-context.nix {
    inherit common;
  } {
    services = [ ];
    endpointBindings = {
      tenants.client.runtimeBindings = [
        { logicalNode = "core-nebula"; }
      ];
      externals.east-west = {
        overlays = [ "east-west" ];
        runtimeBindings = [
          { logicalNode = "core-nebula"; }
        ];
      };
    };
    transitInterfaces = [
      {
        runtimeIfName = "pol-client-b";
        laneKind = "access-uplink";
        laneAccess = "core-nebula";
        laneUplink = "isp-a";
        uplinks = [ "isp-a" ];
      }
      {
        runtimeIfName = "core-a";
        laneKind = "uplink";
        uplinks = [ "isp-a" ];
        routes = {
          ipv4 = [
            {
              overlay = "east-west";
              proto = "underlay";
              intent.kind = "overlay-underlay-reachability";
            }
          ];
          ipv6 = [ ];
        };
      }
      {
        runtimeIfName = "core-b";
        laneKind = "uplink";
        uplinks = [ "isp-b" ];
        routes = { ipv4 = [ ]; ipv6 = [ ]; };
      }
    ];
  };
  relations = import ${repo_root}/src/cpm/firewall-intent/rules/upstream-selector-relations.nix {
    inherit common endpointContext;
  };
in
relations.overlayUnderlayTransitRule {
  action = "allow";
  id = "allow-nebula-underlay-policy-lane";
  priority = 100;
  trafficType = "nebula";
  from = {
    kind = "external";
    name = "east-west";
  };
  to = {
    kind = "external";
    uplinks = [ "isp-a" ];
  };
}
EOF

nix eval --impure --json --file "${overlay_policy_case}" >"${overlay_policy_json}"

jq -e '
  .
  | [
      .[]
      | select(
          (.action == "accept")
          and (.fromInterface == "pol-client-b")
          and (.toInterface == "core-a")
          and ((.trafficType == "nebula") or (.trafficType == "nebula-runtime"))
          and (.intent.kind == "overlay-underlay-reachability")
          and (.intent.source == "overlay-underlay-endpoint")
          and (.intent.overlay == "east-west")
        )
    ]
  | length == 1
' "${overlay_policy_json}" >/dev/null || {
  cat >&2 <<'EOF'
FAIL upstream-selector nebula underlay policy-lane transit.

When the overlay core is also a tenant client with DHCP/SLAAC underlay, its
public Nebula endpoint traffic reaches the upstream selector on that tenant's
policy lane. CPM must emit a narrow policy-lane -> selected-core Nebula
underlay rule; the renderer must not infer this firewall allowance from route
tables.
EOF
  exit 1
}

jq -e '
  .
  | [
      .[]
      | select(
          (.fromInterface == "pol-client-b")
          and (.toInterface == "core-a")
          and ((.trafficType // "any") == "any")
        )
    ]
  | length == 0
' "${output_json}" >/dev/null || {
  echo "FAIL upstream-selector nebula underlay policy-lane transit: policy lane gained broad core-a egress" >&2
  exit 1
}

echo "PASS upstream-selector-nebula-underlay-core-transit"
