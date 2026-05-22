#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

archive_json="$(mktemp)"
work_dir="$(mktemp -d)"
trap 'rm -f "${archive_json}"; rm -rf "${work_dir}"' EXIT

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

lab_dir="${labs_path}/labs/lab-s-sigma/s-router-test-three-site"
inventory_nix="${work_dir}/inventory.nix"
output_json="${work_dir}/cpm.json"

cat >"${inventory_nix}" <<EOF
import ${lab_dir}/getResolvedInventory.nix { renderer = "nixos"; }
EOF

nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${lab_dir}/intent.nix" \
  "${inventory_nix}" \
  "${output_json}" >/dev/null

jq -e '
  def default4: map(select(.dst == "0.0.0.0/0"));
  def default6: map(select(.dst == "::/0"));
  def lanes($uplink):
    map(select((.lane.uplink // "") == $uplink and (.lane.access // null) != null) | .lane.access) | sort;
  def defaultLaneAccesses($uplink):
    map(select(
      (.dst // "") == "::/0"
      and (.policyOnly // false) == true
      and (.intent.kind // "") == "default-reachability"
      and (.lane.uplink // "") == $uplink
      and (.lane.access // null) != null
    ) | .lane.access) | sort;
  def laneComplements($access; $destination):
    map(select(
      (.policyOnly // false) == true
      and (.reason // "") == "policy-table-internal-reachability"
      and (.lane.access // "") == $access
      and (.dst // "") == $destination
    ) | .via4) | sort;
  def hasRoute($destination; $via):
    any(.dst == $destination and ((.via4 // null) == $via or (.via6 // null) == $via));
  def noRoute($destination; $via):
    all(.dst != $destination or (((.via4 // null) != $via) and ((.via6 // null) != $via)));
  def expect($actual; $expected):
    if $actual == $expected then true
    else error("expected " + ($expected | @json) + " got " + ($actual | @json))
    end;

  . as $root
  | .control_plane_model.data.esp.nixos.runtimeTargets."esp-nixos-router-upstream"
    .effectiveRuntimeRealization.interfaces as $ifs
  | ($ifs."p2p-nixos-router-core-isp-a-nixos-router-upstream".routes.ipv4 | default4) as $a4
  | ($ifs."p2p-nixos-router-core-isp-a-nixos-router-upstream".routes.ipv6 | default6) as $a6
  | ($ifs."p2p-nixos-router-core-isp-b-nixos-router-upstream".routes.ipv4 | default4) as $b4
  | ($ifs."p2p-nixos-router-core-isp-b-nixos-router-upstream".routes.ipv6 | default6) as $b6
  | ($ifs."p2p-nixos-router-core-nebula-nixos-router-upstream".routes.ipv4 | default4) as $ew4
  | ($ifs."p2p-nixos-router-core-nebula-nixos-router-upstream".routes.ipv6 | default6) as $ew6
  | ["nixos-router-access-admin", "nixos-router-access-client", "nixos-router-access-mgmt", "nixos-router-access-streaming"] as $normalAccess
  | expect(($a4 | lanes("isp-a")); $normalAccess)
  | expect(($a6 | lanes("isp-a")); $normalAccess)
  | expect(($b4 | lanes("isp-b")); $normalAccess)
  | expect(($b6 | lanes("isp-b")); $normalAccess)
  | expect(($ew4 | lanes("east-west")); ["nixos-router-access-hostile"])
  | expect(($ew6 | lanes("east-west")); ["nixos-router-access-hostile"])
  | if ($ifs."p2p-nixos-router-policy-nixos-router-upstream--access-nixos-router-access-hostile--uplink-east-west".routes.ipv4
      | hasRoute("0.0.0.0/0"; "10.10.0.16")) then . else
      error("NixOS hostile upstream policy lane must default toward core-nebula, not back to policy")
    end
  | if ($ifs."p2p-nixos-router-policy-nixos-router-upstream--access-nixos-router-access-hostile--uplink-east-west".routes.ipv6
      | hasRoute("::/0"; "fd42:dead:beef:1000:0:0:0:10")) then . else
      error("NixOS hostile upstream policy lane must default toward core-nebula for IPv6, not back to policy")
    end
  | if ($ifs."p2p-nixos-router-policy-nixos-router-upstream--access-nixos-router-access-hostile--uplink-east-west".routes.ipv4
      | noRoute("0.0.0.0/0"; "10.10.0.38")) then . else
      error("NixOS hostile upstream policy lane must not install a default route back to its policy peer")
    end
  | if ($ifs."p2p-nixos-router-policy-nixos-router-upstream--access-nixos-router-access-hostile--uplink-east-west".routes.ipv6
      | noRoute("::/0"; "fd42:dead:beef:1000:0:0:0:26")) then . else
      error("NixOS hostile upstream policy lane must not install an IPv6 default route back to its policy peer")
    end

  | $root.control_plane_model.data.esp.clab.runtimeTargets."esp-clab-router-upstream"
      .effectiveRuntimeRealization.interfaces as $clabIfs
  | ($clabIfs."p2p-clab-router-core-simulated-isp-clab-router-upstream".routes.ipv4 | default4) as $clabWan4
  | ($clabIfs."p2p-clab-router-core-simulated-isp-clab-router-upstream".routes.ipv6 | default6) as $clabWan6
  | ($clabIfs."p2p-clab-router-core-nebula-clab-router-upstream".routes.ipv4 | default4) as $clabEw4
  | ($clabIfs."p2p-clab-router-core-nebula-clab-router-upstream".routes.ipv6 | default6) as $clabEw6
  | expect(($clabWan4 | lanes("wan")); ["clab-router-access-admin", "clab-router-access-client", "clab-router-access-mgmt", "clab-router-access-streaming"])
  | expect(($clabWan6 | lanes("wan")); ["clab-router-access-admin", "clab-router-access-client", "clab-router-access-mgmt", "clab-router-access-streaming"])
  | expect(($clabEw4 | lanes("east-west")); ["clab-router-access-hostile"])
  | expect(($clabEw6 | lanes("east-west")); ["clab-router-access-hostile"])
  | expect(($clabEw6 | defaultLaneAccesses("east-west")); ["clab-router-access-hostile"])

  | $root.control_plane_model.data.esp.clab.runtimeTargets."esp-clab-router-policy"
      .effectiveRuntimeRealization.interfaces as $clabPolicyIfs
  | expect(($clabPolicyIfs."p2p-clab-router-downstream-clab-router-policy--access-clab-router-access-streaming".routes.ipv4
      | laneComplements("clab-router-access-client"; "10.50.50.0/24")); ["10.50.0.26"])
  | expect(($clabPolicyIfs."p2p-clab-router-downstream-clab-router-policy--access-clab-router-access-client".routes.ipv4
      | laneComplements("clab-router-access-streaming"; "10.50.20.0/24")); ["10.50.0.18"])

  | $root.control_plane_model.data.esp.hetz.runtimeTargets."esp-hetz-router-upstream"
      .effectiveRuntimeRealization.interfaces as $hetzUpstreamIfs
  | if ($hetzUpstreamIfs."p2p-hetz-router-nebula-core-hetz-router-upstream".routes.ipv4
      | hasRoute("0.0.0.0/0"; "10.80.0.14")) then . else
      error("Hetz hostile IPv4 overlay ingress must policy-route via pol-dmz-ew, matching the live hotpatch that restored hostile egress")
    end
  | if ($hetzUpstreamIfs."p2p-hetz-router-nebula-core-hetz-router-upstream".routes.ipv6
      | hasRoute("::/0"; "fd42:dead:cafe:1000:0:0:0:e")) then . else
      error("Hetz hostile IPv6 overlay ingress must policy-route via the east-west policy lane")
    end
  | if ($hetzUpstreamIfs."p2p-hetz-router-nebula-core-hetz-router-upstream".routes.ipv6
      | noRoute("::/0"; "fd42:dead:cafe:1000:0:0:0:4")) then . else
      error("Hetz hostile IPv6 overlay ingress must not bypass policy with an unscoped default to core")
    end
  | $root.control_plane_model.data.esp.hetz.runtimeTargets."esp-hetz-router-core"
      .effectiveRuntimeRealization.interfaces as $hetzCoreIfs
  | if ($hetzCoreIfs."p2p-hetz-router-core-hetz-router-upstream".routes.ipv4
      | hasRoute("10.20.70.0/24"; "10.80.0.5")) then . else
      error("Hetz WAN core must retain the remote hostile IPv4 return route via upstream")
    end
' "${output_json}" >/dev/null

echo "PASS sigma-upstream-policy-defaults-preserved"
