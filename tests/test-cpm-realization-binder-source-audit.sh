#!/usr/bin/env bash
# GAMP-ID: FS-030-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-030-HDS-010-SDS-010-SMS-040
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

tmp_dir="${TMPDIR:-/tmp}/fs030-cpm-binder-audit-smt-high"
mkdir -p "${tmp_dir}"
rm -f "${tmp_dir}/base.nix" \
  "${tmp_dir}/inventory-with-reservations.nix" \
  "${tmp_dir}/out.json" \
  "${tmp_dir}/missing-audit.out" \
  "${tmp_dir}/missing-audit.err" \
  "${tmp_dir}/cross-stage.out" \
  "${tmp_dir}/cross-stage.err"

flake_input_path() {
  local input_name="$1"
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

example_root="$(flake_input_path network-labs)/examples/single-wan-uplink-static-egress"
intent_path="${example_root}/intent.nix"
inventory_source="${example_root}/inventory-nixos.nix"

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

cp "${inventory_source}" "${tmp_dir}/base.nix"
inventory_path="${tmp_dir}/inventory-with-reservations.nix"
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
                    source = "public-inventory";
                    sourceClass = "public-synthetic-lab";
                  };
                  ipv4.hostOffset = 10;
                  ipv6.hostOffset = 16;
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
compile_inventory "${inventory_path}" >"${output_json}"

if ! OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    target = site.runtimeTargets."esp0xdeadbeef-site-a-s-router-access-client";
    p2pIface = target.effectiveRuntimeRealization.interfaces.p2p-s-router-access-client-s-router-downstream-selector;
    tenantIface = target.effectiveRuntimeRealization.interfaces.tenant-client;
    reservation = builtins.head (builtins.head target.advertisements.dhcp4).reservations;
    hasAudit = record:
      record ? upstreamBehaviorRef
      && record ? binderSourceAudit
      && record.binderSourceAudit.stage == "control-plane-model"
      && record.binderSourceAudit.authority == "realization-binding"
      && record.binderSourceAudit.upstreamBehaviorRef == record.upstreamBehaviorRef;
  in
    hasAudit target.placement
    && hasAudit p2pIface
    && hasAudit tenantIface
    && hasAudit reservation
    && p2pIface.binderSourceAudit.sourceClass == "public-inventory"
    && tenantIface.binderSourceAudit.sourceClass == "runtime-facts"
    && reservation.binderSourceAudit.sourceClass == "public-inventory"
' | grep -qx true; then
  echo "FAIL cpm-realization-binder-source-audit: CPM realization bindings did not carry source audit and upstream behavior reference" >&2
  exit 1
fi

if ! nix eval --impure --expr '
  let
    lib = import '"${repo_root}"'/lib/utils.nix;
    helpers = import '"${repo_root}"'/src/cpm/cpm-contract-support.nix { inherit lib; };
    audit = import '"${repo_root}"'/src/cpm/binder-source-audit.nix {
      inherit helpers;
    };
  in
    audit.validate "ok" (audit.make {
      path = "ok";
      field = "runtimeTarget";
      binderSourceClass = "runtime-facts";
      binderSourcePath = "inventory.realization.nodes.router";
      upstreamBehaviorRef = "forwardingModel.enterprise.acme.site.ams.nodes.router";
    })
' | grep -qx true; then
  echo "FAIL cpm-realization-binder-source-audit: valid runtime-facts audit record did not validate" >&2
  exit 1
fi

if nix eval --impure --expr '
  let
    lib = import '"${repo_root}"'/lib/utils.nix;
    helpers = import '"${repo_root}"'/src/cpm/cpm-contract-support.nix { inherit lib; };
    audit = import '"${repo_root}"'/src/cpm/binder-source-audit.nix {
      inherit helpers;
    };
  in
    audit.validate "missing" {
      upstreamBehaviorRef = "forwardingModel.enterprise.acme.site.ams.nodes.router";
    }
' >"${tmp_dir}/missing-audit.out" 2>"${tmp_dir}/missing-audit.err"; then
  echo "FAIL cpm-realization-binder-source-audit: missing binder source audit was accepted" >&2
  exit 1
fi
grep -F "CPM binder source audit error" "${tmp_dir}/missing-audit.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: missing-audit diagnostic did not name CPM audit" >&2
  cat "${tmp_dir}/missing-audit.err" >&2
  exit 1
}

if nix eval --impure --expr '
  let
    lib = import '"${repo_root}"'/lib/utils.nix;
    helpers = import '"${repo_root}"'/src/cpm/cpm-contract-support.nix { inherit lib; };
    audit = import '"${repo_root}"'/src/cpm/binder-source-audit.nix {
      inherit helpers;
    };
  in
    audit.validate "cross-stage" {
      upstreamBehaviorRef = "forwardingModel.enterprise.acme.site.ams.nodes.router";
      binderSourceAudit = {
        stage = "renderer";
        authority = "realization-binding";
        sourceClass = "public-inventory";
        sourcePath = "inventory.realization.nodes.router";
        field = "runtimeTarget";
        upstreamBehaviorRef = "forwardingModel.enterprise.acme.site.ams.nodes.router";
      };
    }
' >"${tmp_dir}/cross-stage.out" 2>"${tmp_dir}/cross-stage.err"; then
  echo "FAIL cpm-realization-binder-source-audit: cross-stage audit authority was accepted" >&2
  exit 1
fi
grep -F "must be control-plane-model, not cross-stage compiler or renderer authority" "${tmp_dir}/cross-stage.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: cross-stage diagnostic did not name stage boundary" >&2
  cat "${tmp_dir}/cross-stage.err" >&2
  exit 1
}

echo "PASS cpm-realization-binder-source-audit"
