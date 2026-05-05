#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

input_fixture="${repo_root}/fixtures/passing/default-egress-reachability/input.nix"
inventory_fixture="${repo_root}/fixtures/passing/default-egress-reachability/inventory.nix"

tmp_dir="$(mktemp -d)"
stderr_file="$(mktemp)"
trap 'rm -rf "${tmp_dir}"; rm -f "${stderr_file}"' EXIT

cat >"${tmp_dir}/inventory.nix" <<EOF
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
                listen = [ "10.20.0.1" ];
                allowFrom = [ "10.20.0.0/24" ];
                forwarders = [ "runtime-public-dns-ipv4-primary" ];
              };
            };
        };
    };
}
EOF

if nix eval \
  --impure \
  --json \
  --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      builder = flake.lib.${system}.build;
      input = import ${input_fixture};
      inventory = import ${tmp_dir}/inventory.nix;
    in
      builder { inherit input inventory; }
  " >/dev/null 2>"${stderr_file}"; then
  echo "FAIL dns-forwarder-address-validation: invalid runtime DNS placeholder was accepted" >&2
  exit 1
fi

if ! grep -Fq "resolve runtime placeholders before CPM" "${stderr_file}"; then
  echo "FAIL dns-forwarder-address-validation: missing explicit placeholder-resolution error" >&2
  cat "${stderr_file}" >&2
  exit 1
fi

echo "PASS dns-forwarder-address-validation"
