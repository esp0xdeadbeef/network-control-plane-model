#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-PROVIDER-BOOTSTRAP-DNS-CONTRACT-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-006-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-006-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-006-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-006-SMS-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-006-SMS-001-005
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-006-SMS-001-006
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-015-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-015-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-015-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-015-SMS-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-016-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-016-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-016-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-016-SMS-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-017-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-017-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-017-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-018-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-018-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-018-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-019-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-019-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-019-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-019-SMS-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-004-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-004-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-004-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-004-SMS-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-004-SMS-001-005
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-004-SMS-001-006
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-004-SMS-001-007
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-005-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-005-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-005-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-005-SMS-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-006-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-006-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-007-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-007-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-007-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-007-SMS-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-006-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-006-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-006-SMS-001-CMC-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-006-SMS-001-CMC-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-006-SMS-001-CMC-001-005
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-006-SMS-001-CMC-001-006
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-015-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-015-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-015-SMS-001-CMC-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-015-SMS-001-CMC-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-016-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-016-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-016-SMS-001-CMC-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-016-SMS-001-CMC-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-017-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-017-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-017-SMS-001-CMC-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-018-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-018-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-018-SMS-001-CMC-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-019-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-019-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-019-SMS-001-CMC-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-019-SMS-001-CMC-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-004-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-004-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-004-SMS-001-CMC-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-004-SMS-001-CMC-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-004-SMS-001-CMC-001-005
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-004-SMS-001-CMC-001-006
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-004-SMS-001-CMC-001-007
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-005-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-005-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-005-SMS-001-CMC-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-005-SMS-001-CMC-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-006-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-006-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-007-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-007-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-007-SMS-001-CMC-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-002-SDS-001-007-SMS-001-CMC-001-004
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

labs_path="$(
  nix flake archive --json "path:${repo_root}" \
    | jq -er '.inputs["network-labs"].path'
)"

example_dir="${labs_path}/examples/s-router-public-overlay-service"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cat >"${tmp_dir}/inventory-with-provider-bootstrap-dns.nix" <<EOF
let
  base = import ${example_dir}/inventory-nixos.nix;
  site = base.controlPlane.sites.esp0xdeadbeef."site-a";
  overlay = site.overlays.east-west;
in
base
// {
  controlPlane = base.controlPlane // {
    sites = base.controlPlane.sites // {
      esp0xdeadbeef = base.controlPlane.sites.esp0xdeadbeef // {
        "site-a" = site // {
          overlays = site.overlays // {
            east-west = overlay // {
              providerBootstrapDns = {
                forwarders = [
                  "192.0.2.53"
                  "2001:db8::53"
                ];
              };
            };
          };
        };
      };
    };
  };
}
EOF

cat >"${tmp_dir}/inventory-missing-provider-bootstrap-forwarders.nix" <<EOF
let
  base = import ${example_dir}/inventory-nixos.nix;
  site = base.controlPlane.sites.esp0xdeadbeef."site-a";
  overlay = site.overlays.east-west;
in
base
// {
  controlPlane = base.controlPlane // {
    sites = base.controlPlane.sites // {
      esp0xdeadbeef = base.controlPlane.sites.esp0xdeadbeef // {
        "site-a" = site // {
          overlays = site.overlays // {
            east-west = overlay // {
              providerBootstrapDns = { };
            };
          };
        };
      };
    };
  };
}
EOF

output_json="${tmp_dir}/output.json"

nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${example_dir}/intent.nix" \
  "${tmp_dir}/inventory-with-provider-bootstrap-dns.nix" \
  "${output_json}" \
  >"${tmp_dir}/compile-stdout.txt"

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    bootstrap = site.overlays.east-west.providerBootstrapDns;
    allSites =
      builtins.concatMap
        (enterprise: builtins.attrValues enterprise)
        (builtins.attrValues data.control_plane_model.data);
    targetEntriesForSite = siteValue:
      builtins.map
        (targetName: {
          name = targetName;
          target = siteValue.runtimeTargets.${targetName};
        })
        (builtins.attrNames (siteValue.runtimeTargets or { }));
    allTargetEntries = builtins.concatMap targetEntriesForSite allSites;
    allTargets = builtins.map (entry: entry.target) allTargetEntries;
    tenantTargets = builtins.filter (target: (target.role or "") == "access") allTargets;
    hostileTargets =
      builtins.map
        (entry: entry.target)
        (builtins.filter
          (entry:
            builtins.match ".*hostile.*" entry.name != null
            || builtins.match ".*hostile.*" (entry.target.logicalNode.name or "") != null)
          allTargetEntries);
    forwardersForTargets = targets:
      builtins.concatMap
        (target: target.services.dns.forwarders or [ ])
        targets;
    targetDnsValues = forwardersForTargets allTargets;
    tenantDnsValues = forwardersForTargets tenantTargets;
    hostileDnsValues = forwardersForTargets hostileTargets;
  in
    bootstrap.source == "provider-bootstrap-dns"
    && bootstrap.scope == "bootstrap-only"
    && bootstrap.failClosed == true
    && bootstrap.fallbackToCustomerResolver == false
    && bootstrap.reusableByCustomerResolvers == false
    && bootstrap.forwarders == [ "192.0.2.53" "2001:db8::53" ]
    && bootstrap.routePreference == [ "provider-bootstrap" ]
    && bootstrap.allowedUpstreamClasses == [ "provider-bootstrap" ]
    && builtins.elem { dst = "192.0.2.53"; source = "provider-bootstrap-dns"; scope = "bootstrap-only"; } bootstrap.routeContracts
    && builtins.elem { dst = "2001:db8::53"; source = "provider-bootstrap-dns"; scope = "bootstrap-only"; } bootstrap.policyMatrix
    && (builtins.length tenantTargets) > 0
    && (builtins.length hostileTargets) > 0
    && !(builtins.elem "192.0.2.53" targetDnsValues)
    && !(builtins.elem "2001:db8::53" targetDnsValues)
    && !(builtins.elem "192.0.2.53" tenantDnsValues)
    && !(builtins.elem "2001:db8::53" tenantDnsValues)
    && !(builtins.elem "192.0.2.53" hostileDnsValues)
    && !(builtins.elem "2001:db8::53" hostileDnsValues)
' >/dev/null || {
  echo "FAIL provider-bootstrap-dns-contract" >&2
  exit 1
}

if nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${example_dir}/intent.nix" \
  "${tmp_dir}/inventory-missing-provider-bootstrap-forwarders.nix" \
  "${tmp_dir}/missing-output.json" \
  >"${tmp_dir}/missing-stdout.txt" \
  2>"${tmp_dir}/missing-stderr.txt"; then
  echo "FAIL provider-bootstrap-dns-contract: missing providerBootstrapDns.forwarders did not fail" >&2
  exit 1
fi

if ! rg -q 'providerBootstrapDns.forwarders.*must define at least one bootstrap resolver address' "${tmp_dir}/missing-stderr.txt"; then
  echo "FAIL provider-bootstrap-dns-contract: missing-forwarder diagnostic was not specific" >&2
  cat "${tmp_dir}/missing-stderr.txt" >&2
  exit 1
fi

echo "PASS provider-bootstrap-dns-contract"
