#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

input_fixture="${repo_root}/fixtures/passing/default-egress-reachability/input.nix"
inventory_fixture="${repo_root}/fixtures/passing/default-egress-reachability/inventory.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cat > "${tmp_dir}/input.nix" <<EOF
import ${input_fixture}
EOF

cat > "${tmp_dir}/inventory.nix" <<EOF
let
  base = import ${inventory_fixture};
in
base
// {
  realization =
    base.realization
    // {
      nodes =
        base.realization.nodes
        // {
          access-runtime =
            base.realization.nodes.access-runtime
            // {
              services.dns = {
                listen = [
                  "10.20.0.1"
                  "fd00:20::1"
                ];
                allowFrom = [
                  "10.20.0.0/24"
                  "fd00:20::/64"
                ];
                forwarders = [ "1.1.1.1" ];
                localZones = [
                  {
                    name = "printer.";
                    type = "static";
                  }
                  {
                    name = "home-users.";
                  }
                ];
                localRecords = [
                  {
                    name = "test-machine-01.printer.";
                    a = [ "10.20.0.10" ];
                    aaaa = [ "fd00:20::10" ];
                  }
                  {
                    name = "tv-01.home-users.";
                    a = [ "10.20.0.20" ];
                  }
                ];
              };
            };
        };
    };
}
EOF

output_json="${tmp_dir}/output.json"

nix eval \
  --impure \
  --json \
  --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      builder = flake.lib.${system}.build;
      input = import ${tmp_dir}/input.nix;
      inventory = import ${tmp_dir}/inventory.nix;
    in
      builder { inherit input inventory; }
  " > "${output_json}"

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    dns = data.control_plane_model.data.acme.ams.runtimeTargets.access-runtime.services.dns;
    localZones = dns.localZones or [ ];
    localRecords = dns.localRecords or [ ];
    printerRecord =
      builtins.head (
        builtins.filter
          (record: builtins.isAttrs record && (record.name or null) == "test-machine-01.printer.")
          localRecords
      );
    homeUsersRecord =
      builtins.head (
        builtins.filter
          (record: builtins.isAttrs record && (record.name or null) == "tv-01.home-users.")
          localRecords
      );
  in
    builtins.length localZones == 2
    && builtins.any (zone: zone.name == "printer." && zone.type == "static") localZones
    && builtins.any (zone: zone.name == "home-users." && zone.type == "static") localZones
    && builtins.elem "10.20.0.10" (printerRecord.a or [ ])
    && builtins.elem "fd00:20::10" (printerRecord.aaaa or [ ])
    && builtins.elem "10.20.0.20" (homeUsersRecord.a or [ ])
' >/dev/null || {
  echo "FAIL dns-local-records" >&2
  exit 1
}

echo "PASS dns-local-records"
