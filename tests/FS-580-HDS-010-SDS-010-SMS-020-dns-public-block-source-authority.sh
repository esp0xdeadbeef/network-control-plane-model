#!/usr/bin/env bash
# GAMP-ID: FS-580-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-580-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

labs_path="${NETWORK_LABS_PATH:-$(pinned_network_labs)}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

single_wan_dir="${labs_path}/examples/single-wan-with-nebula-any-to-any-fw"
hat_dir="${labs_path}/HAT/emulated-isp-residential-testnet"
single_output="${tmp_dir}/single-wan.json"
hat_output="${tmp_dir}/hat.json"

for source_path in \
  "${single_wan_dir}/intent.nix" \
  "${single_wan_dir}/inventory-nixos.nix" \
  "${hat_dir}/intent.nix" \
  "${hat_dir}/inventory-nixos.nix"
do
  if rg -n "deniedResolverCidrs|blockPublicResolvers|deny-direct-public-dns" "${source_path}" >/dev/null; then
    echo "FAIL dns-public-block-source-authority: ${source_path} explicitly models public DNS blocking; update this regression scope" >&2
    exit 1
  fi
done

nix run --no-warn-dirty --no-write-lock-file "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${single_wan_dir}/intent.nix" \
  "${single_wan_dir}/inventory-nixos.nix" \
  "${single_output}" >/dev/null

nix run --no-warn-dirty --no-write-lock-file "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${hat_dir}/intent.nix" \
  "${hat_dir}/inventory-nixos.nix" \
  "${hat_output}" >/dev/null

jq -e '
  def dns($enterprise; $site; $target):
    .control_plane_model.data[$enterprise][$site].runtimeTargets[$target].services.dns;
  def no_public_block($dns):
    ($dns.killSwitch.blockPublicResolvers == false)
    and (($dns.deniedResolverCidrs // []) == []);
  no_public_block(dns("esp0xdeadbeef"; "site-a"; "esp0xdeadbeef-site-a-s-router-access-admin"))
' "${single_output}" >/dev/null || {
  echo "FAIL dns-public-block-source-authority: single-wan access target gained public DNS blocking without source policy" >&2
  exit 1
}

jq -e '
  def dns($enterprise; $site; $target):
    .control_plane_model.data[$enterprise][$site].runtimeTargets[$target].services.dns;
  def no_public_block($dns):
    ($dns.killSwitch.blockPublicResolvers == false)
    and (($dns.deniedResolverCidrs // []) == []);
  no_public_block(dns("esp0xdeadbeef"; "site-a"; "esp0xdeadbeef-site-a-nixos-access-client"))
' "${hat_output}" >/dev/null || {
  echo "FAIL dns-public-block-source-authority: HAT access target gained public DNS blocking without source policy" >&2
  exit 1
}

echo "PASS dns-public-block-source-authority"
