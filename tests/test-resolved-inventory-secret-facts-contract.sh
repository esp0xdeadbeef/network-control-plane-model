#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive_json="$(mktemp)"
tmp_dir="$(mktemp -d)"
trap 'rm -f "${archive_json}"; rm -rf "${tmp_dir}"' EXIT

nix flake archive --json "path:${repo_root}" > "${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
    in
      if labs == null || !(labs ? path) then
        throw "tests: missing archived network-labs input path"
      else
        labs.path
  '
)"

intent_path="${labs_path}/examples/dual-wan-branch-overlay/intent.nix"
inventory_path="${labs_path}/examples/dual-wan-branch-overlay/inventory-nixos.nix"
positive_inventory="${tmp_dir}/inventory-source-metadata.nix"
missing_source_inventory="${tmp_dir}/inventory-missing-source.nix"
out_of_pool_inventory="${tmp_dir}/inventory-out-of-pool.nix"
output_json="${tmp_dir}/output.json"
source_stderr="${tmp_dir}/missing-source.stderr"
pool_stderr="${tmp_dir}/out-of-pool.stderr"

write_inventory() {
  local mode="$1"
  local target="$2"

  cat >"${target}" <<EOF
let
  recursiveUpdate =
    lhs: rhs:
    lhs // builtins.mapAttrs
      (name: value:
        if builtins.isAttrs value && builtins.isAttrs (lhs.\${name} or null) then
          recursiveUpdate lhs.\${name} value
        else
          value)
      rhs;
  baseInventory = import ${inventory_path};
  sourceFor = nodeName: {
    addr4SourceClass = "sops-runtime";
    addr4SecretName = "overlay-\${nodeName}-addr4";
    addr6SourceClass = "sops-runtime";
    addr6SecretName = "overlay-\${nodeName}-addr6";
  };
  policy = {
    addressSourcePolicy = {
      required = true;
      allowedClasses = [ "sops-runtime" ];
    };
  };
  sourcePatch = {
    controlPlane.sites = {
      enterpriseA.site-a.overlays.east-west =
        policy
        // {
          ipam.nodes = {
            hetzner-nebula-prodtest-01 = sourceFor "hetzner-nebula-prodtest-01";
            nebula-core = sourceFor "nebula-core";
            s-router-core-nebula = sourceFor "s-router-core-nebula";
          };
        };
      enterpriseB.site-b.overlays.east-west =
        policy
        // {
          ipam.nodes = {
            b-router-core-nebula = sourceFor "b-router-core-nebula";
            branch-node01 = sourceFor "branch-node01";
            hetzner-nebula-prodtest-01 = sourceFor "hetzner-nebula-prodtest-01";
          };
        };
    };
  };
in
EOF

  case "${mode}" in
    positive)
      cat >>"${target}" <<'EOF'
recursiveUpdate baseInventory sourcePatch
EOF
      ;;
    missing-source)
      cat >>"${target}" <<'EOF'
recursiveUpdate baseInventory {
  controlPlane.sites.enterpriseA.site-a.overlays.east-west.addressSourcePolicy = {
    required = true;
    allowedClasses = [ "sops-runtime" ];
  };
}
EOF
      ;;
    out-of-pool)
      cat >>"${target}" <<'EOF'
recursiveUpdate baseInventory (
  recursiveUpdate sourcePatch {
    controlPlane.sites.enterpriseA.site-a.overlays.east-west.ipam.nodes.s-router-core-nebula.addr4 = "100.97.10.1/32";
  }
)
EOF
      ;;
    *)
      echo "unknown inventory mode: ${mode}" >&2
      return 1
      ;;
  esac
}

write_inventory positive "${positive_inventory}"
write_inventory missing-source "${missing_source_inventory}"
write_inventory out-of-pool "${out_of_pool_inventory}"

nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${intent_path}" \
  "${positive_inventory}" \
  "${output_json}" >/dev/null

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    siteA = data.control_plane_model.data.enterpriseA."site-a";
    siteB = data.control_plane_model.data.enterpriseB."site-b";
    nodeA = siteA.overlays."east-west".nodes."s-router-core-nebula";
    nodeB = siteB.overlays."east-west".nodes."branch-node01";
  in
    nodeA.addr4 == "100.96.10.1/32"
    && nodeA.addr4Source.class == "sops-runtime"
    && nodeA.addr6Source.secretName == "overlay-s-router-core-nebula-addr6"
    && nodeB.addr6 == "fd42:dead:beef:ee::20/128"
    && nodeB.addr6Source.class == "sops-runtime"
' >/dev/null || {
  echo "FAIL resolved-inventory-secret-facts-contract: CPM did not preserve overlay address source metadata" >&2
  exit 1
}

if nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${intent_path}" \
  "${missing_source_inventory}" \
  "${tmp_dir}/missing-source.json" >/dev/null 2>"${source_stderr}"; then
  echo "FAIL resolved-inventory-secret-facts-contract: missing source metadata unexpectedly evaluated" >&2
  exit 1
fi

if ! grep -Fq "source class is required by overlay addressSourcePolicy" "${source_stderr}"; then
  echo "FAIL resolved-inventory-secret-facts-contract: missing source metadata failed without path-specific error" >&2
  cat "${source_stderr}" >&2
  exit 1
fi

if nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${intent_path}" \
  "${out_of_pool_inventory}" \
  "${tmp_dir}/out-of-pool.json" >/dev/null 2>"${pool_stderr}"; then
  echo "FAIL resolved-inventory-secret-facts-contract: out-of-pool overlay address unexpectedly evaluated" >&2
  exit 1
fi

if ! grep -Fq "is outside overlay pool" "${pool_stderr}"; then
  echo "FAIL resolved-inventory-secret-facts-contract: out-of-pool overlay address failed without path-specific error" >&2
  cat "${pool_stderr}" >&2
  exit 1
fi

echo "PASS resolved-inventory-secret-facts-contract"
