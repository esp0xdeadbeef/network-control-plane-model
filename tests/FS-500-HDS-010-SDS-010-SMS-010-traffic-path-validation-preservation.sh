#!/usr/bin/env bash
set -euo pipefail
# GAMP-ID: FS-500-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

input_nix="${tmp_dir}/traffic-path-validation-input.nix"
inventory_nix="${tmp_dir}/traffic-path-validation-inventory.nix"
output_json="${tmp_dir}/traffic-path-validation-cpm.json"
fixture_input="${repo_root}/fixtures/passing/default-egress-reachability/input.nix"
fixture_inventory="${repo_root}/fixtures/passing/default-egress-reachability/inventory.nix"

cat >"${input_nix}" <<NIX
let
  base = import ${fixture_input};
  site = base.enterprise.acme.site.ams;
in
base // {
  enterprise = base.enterprise // {
    acme = base.enterprise.acme // {
      site = base.enterprise.acme.site // {
        ams = site // {
          trafficPathValidation = {
            validPathCount = 2;
            invalidPathCount = 1;
            validPaths = [
              {
                relationId = "allow-client-to-wan";
                action = "allow";
                decisionType = "payload-reachability";
                source = { kind = "tenant"; name = "tenant-a"; };
                destination = { kind = "external"; uplinks = [ "wan" ]; };
                nodePath = [ "access-1" "policy-1" "upstream-1" "core-1" ];
              }
              {
                relationId = "reject-client-to-management";
                action = "reject";
                decisionType = "management-reachability";
                source = { kind = "tenant"; name = "tenant-a"; };
                destination = { kind = "tenant"; name = "management"; };
                nodePath = [ "access-1" "policy-1" ];
              }
            ];
            invalidPaths = [
              {
                relationId = "missing-evidence-path";
                action = "allow";
                decisionType = "payload-reachability";
                source = { kind = "tenant"; name = "tenant-a"; };
                destination = { kind = "external"; uplinks = [ "wan" ]; };
                nodePath = [ "access-1" "policy-1" "upstream-1" "core-1" ];
              }
            ];
            diagnostics = {
              "traffic-path-evidence-diagnostic::0" = {
                id = "traffic-path-evidence-diagnostic::0";
                severity = "error";
                relatedPath = "missing-evidence-path";
                missingEvidence = true;
                contractContradiction = false;
                message = "traffic path missing-evidence-path has no matching evidence in communication contract";
              };
            };
          };
        };
      };
    };
  };
}
NIX

cat >"${inventory_nix}" <<NIX
let
  base = import ${fixture_inventory};
  dnsPolicy = ipv4: ipv6: {
    listen = [ ipv4 ipv6 ];
    allowFrom = [
      (builtins.replaceStrings [ ".1" ] [ ".0/24" ] ipv4)
      (builtins.replaceStrings [ "::1" ] [ "::/64" ] ipv6)
    ];
    forwarders = [ "1.1.1.1" "2606:4700:4700::1111" ];
  };
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime =
        base.realization.nodes.access-runtime
        // {
          services = (base.realization.nodes.access-runtime.services or { }) // {
            dns = dnsPolicy "10.20.0.1" "fd00:20::1";
          };
        };
      globex-nyc-access-runtime =
        base.realization.nodes.globex-nyc-access-runtime
        // {
          services = (base.realization.nodes.globex-nyc-access-runtime.services or { }) // {
            dns = dnsPolicy "10.30.0.1" "fd00:30::1";
          };
        };
      globex-lon-access-runtime =
        base.realization.nodes.globex-lon-access-runtime
        // {
          services = (base.realization.nodes.globex-lon-access-runtime.services or { }) // {
            dns = dnsPolicy "10.40.0.1" "fd00:40::1";
          };
        };
    };
  };
}
NIX

nix eval \
  --impure \
  --json \
  --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      builder = flake.lib.${system}.build;
      input = import ${input_nix};
      inventory = import ${inventory_nix};
    in
      builder { inherit input inventory; }
  " >"${output_json}"

jq -e '
  .control_plane_model.data.acme.ams.trafficPathValidation as $tv
  | ($tv.validPathCount == 2)
    and ($tv.invalidPathCount == 1)
    and ([ $tv.validPaths[] | select(.relationId == "allow-client-to-wan" and .action == "allow") ] | length == 1)
    and ([ $tv.validPaths[] | select(.relationId == "reject-client-to-management" and .action == "reject") ] | length == 1)
    and ([ $tv.invalidPaths[] | select(.relationId == "missing-evidence-path" and .action == "allow") ] | length == 1)
    and ($tv.diagnostics["traffic-path-evidence-diagnostic::0"].missingEvidence == true)
    and ($tv.diagnostics["traffic-path-evidence-diagnostic::0"].contractContradiction == false)
    and ($tv.diagnostics["traffic-path-evidence-diagnostic::0"].relatedPath == "missing-evidence-path")
' "${output_json}" >/dev/null || {
  echo "FAIL FS-500 CPM traffic-path validation preservation" >&2
  jq '.control_plane_model.data.acme.ams.trafficPathValidation' "${output_json}" >&2
  exit 1
}

echo "PASS FS-500 CPM traffic-path validation preservation"
