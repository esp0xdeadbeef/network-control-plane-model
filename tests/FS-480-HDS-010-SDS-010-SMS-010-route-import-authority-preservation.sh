#!/usr/bin/env bash
set -euo pipefail
# GAMP-ID: FS-480-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

input_nix="${tmp_dir}/route-import-authority-input.nix"
inventory_nix="${tmp_dir}/route-import-authority-inventory.nix"
output_json="${tmp_dir}/route-import-authority-cpm.json"
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
          prefixAuthority = {
            routeImportConstraints = {
              explicit-runtime-route-import = {
                id = "explicit-runtime-route-import";
                gampId = "FS-480-HDS-010-SDS-010-SMS-010";
                authorityId = "prefix-authority::access-1::4|10.20.0.0/24";
                routePrefix = "10.20.0.0/24";
                allowedPrefixes = [ "10.20.0.0/24" ];
                sourcePeerOrProvider = "wan-bgp-peer";
                allowedSources = [ "wan-bgp-peer" ];
                routePurpose = "remote-site";
                allowedPurposes = [ "remote-site" ];
                destinationOwner = "access-1";
                allowedDestinationOwners = [ "access-1" ];
                maximumScope = "remote-site";
                routeScope = "remote-site";
                exportRequested = true;
                exportEligible = true;
                rejectionBehavior = "reject";
                allowed = true;
                reachabilityClassification = "allowed";
                diagnostic = null;
              };
            };
            deniedRouteImportConstraints = {
              missing-authority-runtime-route = {
                id = "missing-authority-runtime-route";
                gampId = "FS-480-HDS-010-SDS-010-SMS-040";
                authorityId = "prefix-authority::missing::4|203.0.113.48/32";
                routePrefix = "203.0.113.48/32";
                allowedPrefixes = [ "203.0.113.48/32" ];
                sourcePeerOrProvider = "wan-bgp-peer";
                allowedSources = [ "wan-bgp-peer" ];
                routePurpose = "provider-prefix";
                allowedPurposes = [ "provider-prefix" ];
                destinationOwner = "provider-wan";
                allowedDestinationOwners = [ "provider-wan" ];
                maximumScope = "provider";
                routeScope = "provider";
                exportRequested = false;
                exportEligible = false;
                rejectionBehavior = "reject";
                allowed = false;
                reachabilityClassification = "ambiguous";
                diagnosticCode = "MISSING_ROUTE_IMPORT_AUTHORITY";
                diagnostic = {
                  code = "MISSING_ROUTE_IMPORT_AUTHORITY";
                  routePrefix = "203.0.113.48/32";
                  sourcePeerOrProvider = "wan-bgp-peer";
                };
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
  .control_plane_model.data.acme.ams.prefixAuthority as $pa
  | $pa.routeImportConstraints["explicit-runtime-route-import"] as $allowed
  | $pa.deniedRouteImportConstraints["missing-authority-runtime-route"] as $denied
  | ($allowed.allowed == true)
    and ($allowed.gampId == "FS-480-HDS-010-SDS-010-SMS-010")
    and ($allowed.routePrefix == "10.20.0.0/24")
    and ($allowed.sourcePeerOrProvider == "wan-bgp-peer")
    and ($allowed.reachabilityClassification == "allowed")
    and ($allowed.diagnostic == null)
    and ($denied.allowed == false)
    and ($denied.gampId == "FS-480-HDS-010-SDS-010-SMS-040")
    and ($denied.diagnosticCode == "MISSING_ROUTE_IMPORT_AUTHORITY")
    and ($denied.reachabilityClassification == "ambiguous")
    and ($denied.diagnostic.routePrefix == "203.0.113.48/32")
' "${output_json}" >/dev/null || {
  echo "FAIL FS-480 CPM route-import authority preservation" >&2
  jq '.control_plane_model.data.acme.ams.prefixAuthority' "${output_json}" >&2
  exit 1
}

echo "PASS FS-480 CPM route-import authority preservation"
