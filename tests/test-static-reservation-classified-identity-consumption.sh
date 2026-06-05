#!/usr/bin/env bash
# GAMP-ID: FS-970-HDS-010-SDS-020-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

write_inventory() {
  local path="$1"
  local dhcp4_reservations="$2"
  local dhcpv6_reservations="$3"
  cat >"${path}" <<EOF
let
  base = import ./base.nix;
  nodeName = "esp0xdeadbeef-site-a-s-router-access-client";
  node = base.realization.nodes.\${nodeName};
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      \${nodeName} = node // {
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
              reservations = ${dhcp4_reservations};
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
              reservations = ${dhcpv6_reservations};
            };
          };
        };
      };
    };
  };
}
EOF
}

compile_inventory() {
  local inventory_path="$1"
  nix eval --impure --json --expr '
    let
      flake = builtins.getFlake "'"path:${repo_root}"'";
      out = flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
        inputPath = "'"${intent_path}"'";
        inventoryPath = "'"${inventory_path}"'";
      };
    in
      out
  '
}

valid_inventory="${tmp_dir}/inventory-valid.nix"
write_inventory "${valid_inventory}" '[
  {
    name = "client-fixed-10";
    hostname = "client-fixed-10";
    mac = "02:10:20:00:00:10";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "static-dhcp-reservation";
      source = "public-inventory";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 10;
    ipv6.hostOffset = 16;
  }
]' '[
  {
    name = "client-fixed-10";
    hostname = "client-fixed-10";
    mac = "02:10:20:00:00:10";
    macSource = {
      accepted = true;
      disposable = true;
      purpose = "dhcpv6-reservation";
      source = "public-inventory";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 10;
    ipv6.hostOffset = 16;
  }
]'

output_json="${tmp_dir}/out.json"
compile_inventory "${valid_inventory}" >"${output_json}"

if ! OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    target = site.runtimeTargets."esp0xdeadbeef-site-a-s-router-access-client";
    dhcp4 = builtins.head target.advertisements.dhcp4;
    dhcpv6 = builtins.head target.advertisements.dhcpv6;
    reservation4 = builtins.elemAt dhcp4.reservations 0;
    reservation6 = builtins.elemAt dhcpv6.reservations 0;
  in
    reservation4.mac == "02:10:20:00:00:10"
    && reservation4.identitySource.classifier == "FS-720-HDS-010-SDS-030-SMS-010"
    && reservation4.identitySource.accepted == true
    && reservation4.identitySource.purpose == "static-dhcp-reservation"
    && reservation4.identitySource.sourceClass == "public-synthetic-lab"
    && reservation4.identitySource.source == "public-inventory"
    && reservation6.mac == "02:10:20:00:00:10"
    && reservation6.identitySource.classifier == "FS-720-HDS-010-SDS-030-SMS-010"
    && reservation6.identitySource.accepted == true
    && reservation6.identitySource.purpose == "dhcpv6-reservation"
    && reservation6.identitySource.sourceClass == "public-synthetic-lab"
' | grep -qx true; then
  echo "FAIL static-reservation-classified-identity-consumption: CPM did not consume accepted classifier output" >&2
  exit 1
fi

missing_classifier_inventory="${tmp_dir}/inventory-missing-classifier.nix"
write_inventory "${missing_classifier_inventory}" '[
  { mac = "02:10:20:00:00:10"; ipv4.hostOffset = 10; ipv6.hostOffset = 16; }
]' '[
  { mac = "02:10:20:00:00:10"; ipv4.hostOffset = 10; ipv6.hostOffset = 16; }
]'

if compile_inventory "${missing_classifier_inventory}" >"${tmp_dir}/missing-classifier.out" 2>"${tmp_dir}/missing-classifier.err"; then
  echo "FAIL static-reservation-classified-identity-consumption: unclassified reservation identity was accepted" >&2
  exit 1
fi
grep -F "requires accepted MAC source classification from FS-720-HDS-010-SDS-030-SMS-010" \
  "${tmp_dir}/missing-classifier.err" >/dev/null || {
    echo "FAIL static-reservation-classified-identity-consumption: missing-classifier diagnostic was not concise" >&2
    cat "${tmp_dir}/missing-classifier.err" >&2
    exit 1
  }

rejected_classifier_inventory="${tmp_dir}/inventory-rejected-classifier.nix"
write_inventory "${rejected_classifier_inventory}" '[
  {
    mac = "02:10:20:00:00:10";
    macSource = {
      accepted = false;
      disposable = true;
      purpose = "static-dhcp-reservation";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 10;
    ipv6.hostOffset = 16;
  }
]' '[
  {
    mac = "02:10:20:00:00:10";
    macSource = {
      accepted = false;
      disposable = true;
      purpose = "dhcpv6-reservation";
      sourceClass = "public-synthetic-lab";
    };
    ipv4.hostOffset = 10;
    ipv6.hostOffset = 16;
  }
]'

if compile_inventory "${rejected_classifier_inventory}" >"${tmp_dir}/rejected-classifier.out" 2>"${tmp_dir}/rejected-classifier.err"; then
  echo "FAIL static-reservation-classified-identity-consumption: rejected classifier output was accepted" >&2
  exit 1
fi
grep -F "must be accepted by FS-720-HDS-010-SDS-030-SMS-010 before reservation identity consumption" \
  "${tmp_dir}/rejected-classifier.err" >/dev/null || {
    echo "FAIL static-reservation-classified-identity-consumption: rejected-classifier diagnostic was not concise" >&2
    cat "${tmp_dir}/rejected-classifier.err" >&2
    exit 1
  }

echo "PASS static-reservation-classified-identity-consumption"
