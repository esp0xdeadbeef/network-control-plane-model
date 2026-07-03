#!/usr/bin/env bash
# GAMP-ID: FS-030-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-030-HDS-010-SDS-010-SMS-040
# GAMP-ID: FS-040-HDS-010-SDS-010-SMS-010
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
  "${tmp_dir}/inventory-with-static-egress.nix" \
  "${tmp_dir}/inventory-with-unauthorized-egress.nix" \
  "${tmp_dir}/out.json" \
  "${tmp_dir}/static-egress.json" \
  "${tmp_dir}/unauthorized-egress.out" \
  "${tmp_dir}/unauthorized-egress.err" \
  "${tmp_dir}/untraceable-route.out" \
  "${tmp_dir}/untraceable-route.err" \
  "${tmp_dir}/missing-audit.out" \
  "${tmp_dir}/missing-audit.err" \
  "${tmp_dir}/missing-upstream.out" \
  "${tmp_dir}/missing-upstream.err" \
  "${tmp_dir}/cross-stage.out" \
  "${tmp_dir}/cross-stage.err"

flake_input_path() {
  local input_name="$1"
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

example_root="$(flake_input_path network-labs)/examples/single-wan"
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
    common = import '"${repo_root}"'/src/cpm/Site/build-data/common.nix {
      inherit helpers;
      ipam = import '"${repo_root}"'/src/cpm/ipam.nix { inherit lib; };
      enterpriseRoot = { };
    };
    inventoryAttrs = {
      controlPlane.sites.esp0xdeadbeef.site-a.uplinks.wan.egress = {
        mode = "static";
        static.routes = {
          ipv4 = [
            {
              prefix = "0.0.0.0/0";
              via = "192.0.2.1";
            }
          ];
          ipv6 = [ ];
        };
      };
    };
    siteAttrs = {
      nodes.s-router-core-wan.uplinks.wan.ipv4 = [ "0.0.0.0/0" ];
    };
    controlPlane = import '"${repo_root}"'/src/cpm/Site/build-data/control-plane.nix {
      inherit helpers common inventoryAttrs siteAttrs;
      sitePath = "forwardingModel.enterprise.esp0xdeadbeef.site.site-a";
      enterpriseName = "esp0xdeadbeef";
      siteName = "site-a";
      uplinkNames = [ "wan" ];
    };
    staticUplinkRoutes = import '"${repo_root}"'/src/cpm/Unit/runtime-targets/interfaces/uplink-static-routes.nix {
      inherit helpers common;
    };
    route = builtins.head ((staticUplinkRoutes controlPlane.uplinkRouting.wan).ipv4 or [ ]);
  in
    route.dst == "0.0.0.0/0"
    && route.traceBackRef == "forwardingModel.enterprise.esp0xdeadbeef.site.site-a.nodes.s-router-core-wan.uplinks.wan.ipv4[0]"
    && route.upstreamBehaviorRef == route.traceBackRef
    && route.binderSourceAudit.stage == "control-plane-model"
    && route.binderSourceAudit.authority == "realization-binding"
    && route.binderSourceAudit.sourceClass == "public-inventory"
    && route.binderSourceAudit.sourcePath == "inventory.controlPlane.sites.esp0xdeadbeef.site-a.uplinks.wan.egress.static.routes.ipv4[0]"
' | grep -qx true; then
  echo "FAIL cpm-realization-binder-source-audit: authorized static egress route did not carry route trace/audit" >&2
  exit 1
fi

if nix eval --impure --expr '
  let
    lib = import '"${repo_root}"'/lib/utils.nix;
    helpers = import '"${repo_root}"'/src/cpm/cpm-contract-support.nix { inherit lib; };
    common = import '"${repo_root}"'/src/cpm/Site/build-data/common.nix {
      inherit helpers;
      ipam = import '"${repo_root}"'/src/cpm/ipam.nix { inherit lib; };
      enterpriseRoot = { };
    };
    inventoryAttrs = {
      controlPlane.sites.esp0xdeadbeef.site-a.uplinks.wan.egress = {
        mode = "static";
        static.routes = {
          ipv4 = [
            {
              prefix = "203.0.113.0/24";
              via = "203.0.113.1";
            }
          ];
          ipv6 = [ ];
        };
      };
    };
    siteAttrs = {
      nodes.s-router-core-wan.uplinks.wan.ipv4 = [ "0.0.0.0/0" ];
    };
    controlPlane = import '"${repo_root}"'/src/cpm/Site/build-data/control-plane.nix {
      inherit helpers common inventoryAttrs siteAttrs;
      sitePath = "forwardingModel.enterprise.esp0xdeadbeef.site.site-a";
      enterpriseName = "esp0xdeadbeef";
      siteName = "site-a";
      uplinkNames = [ "wan" ];
    };
  in
    builtins.deepSeq controlPlane.uplinkRouting.wan true
' >"${tmp_dir}/unauthorized-egress.out" 2>"${tmp_dir}/unauthorized-egress.err"; then
  echo "FAIL cpm-realization-binder-source-audit: unauthorized inventory-created WAN egress route was accepted" >&2
  exit 1
fi
grep -F "UNAUTHORIZED_BEHAVIOR_FROM_INVENTORY" "${tmp_dir}/unauthorized-egress.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: unauthorized route diagnostic did not name behavior source" >&2
  cat "${tmp_dir}/unauthorized-egress.err" >&2
  exit 1
}
grep -F "prefix=203.0.113.0/24" "${tmp_dir}/unauthorized-egress.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: unauthorized route diagnostic did not name prefix" >&2
  cat "${tmp_dir}/unauthorized-egress.err" >&2
  exit 1
}
grep -F "gateway=203.0.113.1" "${tmp_dir}/unauthorized-egress.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: unauthorized route diagnostic did not name gateway" >&2
  cat "${tmp_dir}/unauthorized-egress.err" >&2
  exit 1
}

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
    audit.validateRouteBinding "site-b.route" {
      scope = "site-b";
      dst = "10.20.0.0/24";
      via4 = "192.168.50.1";
      upstreamBehaviorRef = "policyAllow.allow-ab-443";
      binderSourceAudit = {
        stage = "control-plane-model";
        authority = "realization-binding";
        sourceClass = "public-inventory";
        sourcePath = "inventory.realization.route";
        field = "routes.ipv4[]";
        upstreamBehaviorRef = "policyAllow.allow-ab-443";
      };
    }
' >"${tmp_dir}/untraceable-route.out" 2>"${tmp_dir}/untraceable-route.err"; then
  echo "FAIL cpm-realization-binder-source-audit: route without traceBackRef was accepted" >&2
  exit 1
fi
grep -F "UNTRACEABLE_ROUTE" "${tmp_dir}/untraceable-route.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: untraceable route diagnostic missing" >&2
  cat "${tmp_dir}/untraceable-route.err" >&2
  exit 1
}
grep -F "destination=10.20.0.0/24" "${tmp_dir}/untraceable-route.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: untraceable route diagnostic did not name destination" >&2
  cat "${tmp_dir}/untraceable-route.err" >&2
  exit 1
}
grep -F "nextHop=192.168.50.1" "${tmp_dir}/untraceable-route.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: untraceable route diagnostic did not name next-hop" >&2
  cat "${tmp_dir}/untraceable-route.err" >&2
  exit 1
}

if ! nix eval --impure --expr '
  let
    lib = import '"${repo_root}"'/lib/utils.nix;
    helpers = import '"${repo_root}"'/src/cpm/cpm-contract-support.nix { inherit lib; };
    audit = import '"${repo_root}"'/src/cpm/binder-source-audit.nix {
      inherit helpers;
    };
  in
    audit.validateRouteBinding "site-b.route" (audit.makeRoute {
      path = "site-b.route";
      field = "routes.ipv4[]";
      binderSourceClass = "public-inventory";
      binderSourcePath = "inventory.realization.route";
      upstreamBehaviorRef = "policyAllow.allow-ab-443";
      route = {
        scope = "site-b";
        dst = "10.20.0.0/24";
        via4 = "192.168.50.1";
      };
    })
' | grep -qx true; then
  echo "FAIL cpm-realization-binder-source-audit: trace-backed route recovery did not validate" >&2
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
      field = "inventory.sites.site-a.interfaces.wan0";
      expectedBinderSourceClass = "public-inventory";
      ownerRecord = "site-a.interface.wan0";
      upstreamBehaviorRef = "forwardingModel.enterprise.acme.site.ams.nodes.router";
    }
' >"${tmp_dir}/missing-audit.out" 2>"${tmp_dir}/missing-audit.err"; then
  echo "FAIL cpm-realization-binder-source-audit: missing binder source audit was accepted" >&2
  exit 1
fi
grep -F "CPM_BINDER_SOURCE_AUDIT_MISSING" "${tmp_dir}/missing-audit.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: missing-audit diagnostic did not name seeded negative" >&2
  cat "${tmp_dir}/missing-audit.err" >&2
  exit 1
}
grep -F "field=inventory.sites.site-a.interfaces.wan0" "${tmp_dir}/missing-audit.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: missing-audit diagnostic did not name field path" >&2
  cat "${tmp_dir}/missing-audit.err" >&2
  exit 1
}
grep -F "expectedSourceClass=public-inventory" "${tmp_dir}/missing-audit.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: missing-audit diagnostic did not name expected source class" >&2
  cat "${tmp_dir}/missing-audit.err" >&2
  exit 1
}
grep -F "owner=site-a.interface.wan0" "${tmp_dir}/missing-audit.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: missing-audit diagnostic did not name owning output record" >&2
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
    audit.validate "site-a.interfaces.wan0" {
      field = "inventory.sites.site-a.interfaces.wan0";
      ownerRecord = "site-a.interface.wan0";
      binderSourceAudit = {
        stage = "control-plane-model";
        authority = "realization-binding";
        sourceClass = "public-inventory";
        sourcePath = "inventory.sites.site-a.interfaces.wan0";
        field = "inventory.sites.site-a.interfaces.wan0";
      };
    }
' >"${tmp_dir}/missing-upstream.out" 2>"${tmp_dir}/missing-upstream.err"; then
  echo "FAIL cpm-realization-binder-source-audit: missing upstream behavior reference was accepted" >&2
  exit 1
fi
grep -F "CPM_UPSTREAM_BEHAVIOR_REF_MISSING" "${tmp_dir}/missing-upstream.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: missing-upstream diagnostic did not name seeded negative" >&2
  cat "${tmp_dir}/missing-upstream.err" >&2
  exit 1
}
grep -F "field=inventory.sites.site-a.interfaces.wan0" "${tmp_dir}/missing-upstream.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: missing-upstream diagnostic did not name bound field" >&2
  cat "${tmp_dir}/missing-upstream.err" >&2
  exit 1
}
grep -F "sourceClass=public-inventory" "${tmp_dir}/missing-upstream.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: missing-upstream diagnostic did not name binder source class" >&2
  cat "${tmp_dir}/missing-upstream.err" >&2
  exit 1
}
grep -F "missing=upstreamBehaviorRef" "${tmp_dir}/missing-upstream.err" >/dev/null || {
  echo "FAIL cpm-realization-binder-source-audit: missing-upstream diagnostic did not name missing upstream behavior reference" >&2
  cat "${tmp_dir}/missing-upstream.err" >&2
  exit 1
}

if ! nix eval --impure --expr '
  let
    lib = import '"${repo_root}"'/lib/utils.nix;
    helpers = import '"${repo_root}"'/src/cpm/cpm-contract-support.nix { inherit lib; };
    audit = import '"${repo_root}"'/src/cpm/binder-source-audit.nix {
      inherit helpers;
    };
  in
    audit.validate "site-a.interfaces.wan0" {
      upstreamBehaviorRef = "forwardingModel.enterprise.acme.site.site-a.interfaces.wan0";
      binderSourceAudit = {
        stage = "control-plane-model";
        authority = "realization-binding";
        sourceClass = "public-inventory";
        sourcePath = "inventory.sites.site-a.interfaces.wan0";
        field = "inventory.sites.site-a.interfaces.wan0";
        upstreamBehaviorRef = "forwardingModel.enterprise.acme.site.site-a.interfaces.wan0";
      };
    }
' | grep -qx true; then
  echo "FAIL cpm-realization-binder-source-audit: missing-audit/upstream recovery record did not validate" >&2
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
