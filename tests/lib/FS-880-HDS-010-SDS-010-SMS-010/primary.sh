#!/usr/bin/env bash
# GAMP-ID: FS-880-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-880-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq

flake_input_path() {
  local input_name="$1"
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

example_root="$(flake_input_path network-labs)/examples/single-wan-uplink-static-egress"
intent_path="${example_root}/intent.nix"
inventory_source="${example_root}/inventory-nixos.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cp "${inventory_source}" "${tmp_dir}/base.nix"

inventory_path="${tmp_dir}/inventory-fs880-reservations.nix"
cat >"${inventory_path}" <<'EOF'
let
  base = import ./base.nix;
  nodeName = "esp0xdeadbeef-site-a-s-router-access-client";
  node = base.realization.nodes.${nodeName};
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      ${nodeName} = node // {
        advertisements = node.advertisements // {
          dhcp4 = {
            tenant-client = {
              id = "client";
              subnet = "10.20.20.0/24";
              pool = {
                start = "10.20.20.100";
                end = "10.20.20.199";
              };
              router = "router-self";
              dnsServers = [ "router-self" ];
              domain = "lan.";
              reservations = [
                {
                  name = "client-fixed-10";
                  hostname = "client-fixed-10";
                  mac = "02:10:20:00:00:10";
                  macSource = {
                    accepted = true;
                    disposable = true;
                    purpose = "static-dhcp-reservation";
                    sourceClass = "public-synthetic-lab";
                  };
                  ipv4.hostOffset = 10;
                  ipv6.hostOffset = 10;
                  namespace = "tenant-client.lan.";
                  namespaceOwner = "tenant-client";
                  requesterScope = "tenant-client";
                  requesterScopes = [ "tenant-client" ];
                  recordClass = "A";
                  fallbackBehavior = "local-authority-before-recursion";
                  deniedClasses = [ "PUBLIC-RECURSION" ];
                  conflictBehavior = "fail-closed";
                  stale = {
                    present = true;
                    behavior = "suppress-stale-answer";
                    reason = "lease-marked-stale";
                  };
                  revocation = {
                    present = true;
                    behavior = "revoke-lease-and-suppress-answer";
                    reason = "lease-revoked";
                  };
                }
              ];
            };
          };
          dhcpv6 = {
            tenant-client = {
              id = "client";
              subnet = "fd42:dead:beef:20::/64";
              pool = {
                start = "fd42:dead:beef:20::100";
                end = "fd42:dead:beef:20::1ff";
              };
              serverAddress = "router-self";
              dnsServers = [ "router-self" ];
              domain = "lan.";
              reservations = [
                {
                  name = "client-fixed-16";
                  hostname = "client-fixed-16";
                  mac = "02:10:20:00:00:16";
                  macSource = {
                    accepted = true;
                    disposable = true;
                    purpose = "dhcpv6-reservation";
                    sourceClass = "public-synthetic-lab";
                  };
                  ipv4.hostOffset = 16;
                  ipv6.hostOffset = 16;
                  namespace = "tenant-client.lan.";
                  namespaceOwner = "tenant-client";
                  requesterScope = "tenant-client";
                  recordClass = "AAAA";
                  fallbackBehavior = "local-authority-before-recursion";
                  deniedRecordClasses = [ "PUBLIC-RECURSION" ];
                  conflictBehavior = "fail-closed";
                  staleBehavior = "suppress-stale-answer";
                  revocationBehavior = "revoke-lease-and-suppress-answer";
                }
              ];
            };
          };
        };
      };
    };
  };
}
EOF

output_json="${tmp_dir}/out.json"
nix eval --impure --json --expr '
  let
    flake = builtins.getFlake "'"path:${repo_root}"'";
    out = flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
      inputPath = "'"${intent_path}"'";
      inventoryPath = "'"${inventory_path}"'";
    };
  in
    out
' >"${output_json}"

if ! OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    target = site.runtimeTargets."esp0xdeadbeef-site-a-s-router-access-client";
    dhcp4 = builtins.head target.advertisements.dhcp4;
    dhcpv6 = builtins.head target.advertisements.dhcpv6;
    reservation4 = builtins.head dhcp4.reservations;
    reservation6 = builtins.head dhcpv6.reservations;
  in
    reservation4.namespace == "tenant-client.lan."
    && reservation4.namespaceOwner == "tenant-client"
    && reservation4.requesterScope == "tenant-client"
    && reservation4.requesterScopes == [ "tenant-client" ]
    && reservation4.recordClass == "A"
    && reservation4.fallbackBehavior == "local-authority-before-recursion"
    && reservation4.deniedClasses == [ "PUBLIC-RECURSION" ]
    && reservation4.conflictBehavior == "fail-closed"
    && reservation4.conflict.present == true
    && reservation4.conflict.behavior == "fail-closed"
    && reservation4.conflict.source == "inventory-realization"
    && reservation4.stale.present == true
    && reservation4.stale.behavior == "suppress-stale-answer"
    && reservation4.stale.reason == "lease-marked-stale"
    && reservation4.revocation.present == true
    && reservation4.revocation.behavior == "revoke-lease-and-suppress-answer"
    && reservation4.revocation.reason == "lease-revoked"
    && reservation6.namespace == "tenant-client.lan."
    && reservation6.namespaceOwner == "tenant-client"
    && reservation6.requesterScope == "tenant-client"
    && reservation6.recordClass == "AAAA"
    && reservation6.fallbackBehavior == "local-authority-before-recursion"
    && reservation6.deniedClasses == [ "PUBLIC-RECURSION" ]
    && reservation6.conflictBehavior == "fail-closed"
    && reservation6.conflict.behavior == "fail-closed"
    && reservation6.staleBehavior == "suppress-stale-answer"
    && reservation6.stale.present == true
    && reservation6.stale.behavior == "suppress-stale-answer"
    && reservation6.revocationBehavior == "revoke-lease-and-suppress-answer"
    && reservation6.revocation.present == true
    && reservation6.revocation.behavior == "revoke-lease-and-suppress-answer"
' | grep -qx true; then
  echo "FAIL fs880-static-reservation-namespace-fields: CPM did not preserve FS-880 reservation namespace values" >&2
  exit 1
fi

echo "PASS fs880-static-reservation-namespace-fields"
