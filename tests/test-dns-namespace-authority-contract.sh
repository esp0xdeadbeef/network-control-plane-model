#!/usr/bin/env bash
# GAMP-ID: FS-560-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-560-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-560-HDS-010-SDS-010-SMS-030
# GAMP-ID: FS-560-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"
fixture_dir="${repo_root}/fixtures/passing/default-egress-reachability"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

input_path="${fixture_dir}/input.nix"
inventory_path="${tmp_dir}/inventory.nix"
missing_owner_inventory_path="${tmp_dir}/missing-owner-inventory.nix"
missing_lease_family_inventory_path="${tmp_dir}/missing-lease-family-inventory.nix"
missing_publication_scope_inventory_path="${tmp_dir}/missing-publication-scope-inventory.nix"
renderer_order_inventory_path="${tmp_dir}/renderer-order-inventory.nix"
output_json="${tmp_dir}/cpm.json"

cat >"${inventory_path}" <<EOF
let
  base = import ${fixture_dir}/inventory.nix;
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime = base.realization.nodes.access-runtime // {
        services = (base.realization.nodes.access-runtime.services or { }) // {
          dns = {
            implementation = "unbound";
            listen = [ "10.20.0.1" "fd00:20::1" ];
            allowFrom = [ "10.20.0.0/24" "fd00:20::/64" ];
            forwarders = [ "1.1.1.1" ];
            deniedResolverCidrs = [ ];
            killSwitch.blockPublicResolvers = false;
            localZones = [
              {
                name = "tenant-a.lan.";
                type = "static";
              }
            ];
            localRecords = [
              {
                name = "printer.tenant-a.lan.";
                a = [ "10.20.0.50" ];
                aaaa = [ "fd00:20::50" ];
              }
            ];
            namespaceAuthority = [
              {
                namespace = "tenant-a.lan.";
                ownerScope = "tenant-a";
                requesterScopes = [ "tenant-a" ];
                addressFamilies = [ "ipv4" "ipv6" ];
                recordSources = [ "static" "dhcp4-lease" "dhcpv6-lease" "reverse" "discovery" ];
                fallbackBehavior = "local-authority-before-recursion";
              }
            ];
            leaseNameScopes = [
              {
                name = "client-01.tenant-a.lan.";
                namespace = "tenant-a.lan.";
                recordSource = "dhcp4-lease";
                ownerScope = "tenant-a";
                requesterScopes = [ "tenant-a" ];
                deniedRequesterScopes = [ "tenant-b" ];
                addressFamily = "ipv4";
                addresses = [ "10.20.0.101" ];
                scopeDenialDiagnostic = "lease-name-denied-requester-scope";
              }
              {
                name = "client-01.tenant-a.lan.";
                namespace = "tenant-a.lan.";
                recordSource = "dhcpv6-lease";
                ownerScope = "tenant-a";
                requesterScopes = [ "tenant-a" ];
                deniedRequesterScopes = [ "tenant-b" ];
                addressFamily = "ipv6";
                addresses = [ "fd00:20::101" ];
                scopeDenialDiagnostic = "lease-name-denied-requester-scope";
              }
            ];
            recordPublications = [
              {
                name = "printer.tenant-a.lan.";
                namespace = "tenant-a.lan.";
                recordSource = "static";
                ownerScope = "tenant-a";
                requesterScopes = [ "tenant-a" ];
                addressFamilies = [ "ipv4" "ipv6" ];
                publicationScopes = [ "tenant-a" ];
                publicationDenialDiagnostic = "record-not-published-to-requester-scope";
              }
              {
                name = "50.0.20.10.in-addr.arpa.";
                namespace = "tenant-a.lan.";
                recordSource = "reverse";
                ownerScope = "tenant-a";
                requesterScopes = [ "tenant-a" ];
                addressFamilies = [ "ipv4" ];
                publicationScopes = [ "tenant-a" ];
                publicationDenialDiagnostic = "reverse-record-not-published-to-requester-scope";
                reverseName = "printer.tenant-a.lan.";
              }
              {
                name = "chromecast.tenant-a.lan.";
                namespace = "tenant-a.lan.";
                recordSource = "discovery";
                ownerScope = "tenant-a";
                requesterScopes = [ "tenant-a" ];
                addressFamilies = [ "ipv4" ];
                publicationScopes = [ "tenant-a" ];
                publicationDenialDiagnostic = "discovery-record-not-published-to-requester-scope";
              }
            ];
            namespaceDiagnostics = [
              {
                namespace = "tenant-a.lan.";
                diagnosticType = "conflict";
                recordNames = [ "printer.tenant-a.lan." ];
                behavior = "fail-closed";
                reason = "static-and-lease-conflict";
                resolutionAuthority = "cpm-diagnostic";
              }
              {
                namespace = "tenant-a.lan.";
                diagnosticType = "duplicate-lease";
                recordNames = [ "client-01.tenant-a.lan." ];
                behavior = "fail-closed";
                reason = "duplicate-dhcp-lease-name";
                resolutionAuthority = "cpm-diagnostic";
              }
              {
                namespace = "tenant-a.lan.";
                diagnosticType = "stale-lease";
                recordNames = [ "old-client.tenant-a.lan." ];
                behavior = "suppress-stale-answer";
                reason = "lease-expired";
                resolutionAuthority = "cpm-diagnostic";
              }
              {
                namespace = "tenant-a.lan.";
                diagnosticType = "ambiguous-reverse";
                recordNames = [ "101.0.20.10.in-addr.arpa." ];
                behavior = "fail-closed";
                reason = "multiple-forward-names-for-address";
                resolutionAuthority = "cpm-diagnostic";
              }
            ];
          };
        };
      };
    };
  };
}
EOF

cat >"${missing_owner_inventory_path}" <<EOF
let
  base = import ${inventory_path};
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime = base.realization.nodes.access-runtime // {
        services = base.realization.nodes.access-runtime.services // {
          dns = base.realization.nodes.access-runtime.services.dns // {
            namespaceAuthority = [
              {
                namespace = "tenant-a.lan.";
                requesterScopes = [ "tenant-a" ];
                addressFamilies = [ "ipv4" ];
                fallbackBehavior = "local-authority-before-recursion";
              }
            ];
          };
        };
      };
    };
  };
}
EOF

cat >"${missing_lease_family_inventory_path}" <<EOF
let
  base = import ${inventory_path};
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime = base.realization.nodes.access-runtime // {
        services = base.realization.nodes.access-runtime.services // {
          dns = base.realization.nodes.access-runtime.services.dns // {
            leaseNameScopes = [
              {
                name = "client-01.tenant-a.lan.";
                namespace = "tenant-a.lan.";
                recordSource = "dhcp4-lease";
                ownerScope = "tenant-a";
                requesterScopes = [ "tenant-a" ];
                addresses = [ "10.20.0.101" ];
                scopeDenialDiagnostic = "lease-name-denied-requester-scope";
              }
            ];
          };
        };
      };
    };
  };
}
EOF

cat >"${missing_publication_scope_inventory_path}" <<EOF
let
  base = import ${inventory_path};
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime = base.realization.nodes.access-runtime // {
        services = base.realization.nodes.access-runtime.services // {
          dns = base.realization.nodes.access-runtime.services.dns // {
            recordPublications = [
              {
                name = "printer.tenant-a.lan.";
                namespace = "tenant-a.lan.";
                recordSource = "static";
                ownerScope = "tenant-a";
                requesterScopes = [ "tenant-a" ];
                addressFamilies = [ "ipv4" ];
                publicationDenialDiagnostic = "record-not-published-to-requester-scope";
              }
            ];
          };
        };
      };
    };
  };
}
EOF

cat >"${renderer_order_inventory_path}" <<EOF
let
  base = import ${inventory_path};
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime = base.realization.nodes.access-runtime // {
        services = base.realization.nodes.access-runtime.services // {
          dns = base.realization.nodes.access-runtime.services.dns // {
            namespaceDiagnostics = [
              {
                namespace = "tenant-a.lan.";
                diagnosticType = "conflict";
                recordNames = [ "printer.tenant-a.lan." ];
                behavior = "first-record-wins";
                reason = "renderer-order";
                resolutionAuthority = "renderer-local-order";
              }
            ];
          };
        };
      };
    };
  };
}
EOF

expect_failure() {
  local inventory_file="$1"
  local expected="$2"
  local stderr_file="${tmp_dir}/$(basename "${inventory_file}").stderr"

  if nix eval --impure --json --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      builder = flake.lib.${system}.build;
      input = import ${input_path};
      inventory = import ${inventory_file};
    in
      builder { inherit input inventory; }
  " >/dev/null 2>"${stderr_file}"; then
    echo "FAIL dns-namespace-authority-contract: ${inventory_file} unexpectedly evaluated" >&2
    exit 1
  fi

  if ! grep -Fq "${expected}" "${stderr_file}"; then
    echo "FAIL dns-namespace-authority-contract: expected path '${expected}' not found" >&2
    cat "${stderr_file}" >&2
    exit 1
  fi
}

expect_failure "${missing_owner_inventory_path}" "services.dns.namespaceAuthority[*].ownerScope"
expect_failure "${missing_lease_family_inventory_path}" "services.dns.leaseNameScopes[*].addressFamily"
expect_failure "${missing_publication_scope_inventory_path}" "services.dns.recordPublications[*].publicationScopes"
expect_failure "${renderer_order_inventory_path}" "services.dns.namespaceDiagnostics[*].resolutionAuthority"

nix eval --impure --json --expr "
  let
    flake = builtins.getFlake (toString ${repo_root});
    builder = flake.lib.${system}.build;
    input = import ${input_path};
    inventory = import ${inventory_path};
  in
    builder { inherit input inventory; }
" >"${output_json}"

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    dns = data.control_plane_model.data.acme.ams.runtimeTargets.access-runtime.services.dns;
    authority = builtins.head dns.namespaceAuthority;
    lease4 = builtins.head (builtins.filter (entry: entry.recordSource == "dhcp4-lease") dns.leaseNameScopes);
    lease6 = builtins.head (builtins.filter (entry: entry.recordSource == "dhcpv6-lease") dns.leaseNameScopes);
    staticPublication = builtins.head (builtins.filter (entry: entry.recordSource == "static") dns.recordPublications);
    reversePublication = builtins.head (builtins.filter (entry: entry.recordSource == "reverse") dns.recordPublications);
    discoveryPublication = builtins.head (builtins.filter (entry: entry.recordSource == "discovery") dns.recordPublications);
    diagnosticTypes = builtins.map (entry: entry.diagnosticType) dns.namespaceDiagnostics;
  in
    authority.namespace == "tenant-a.lan."
    && authority.ownerScope == "tenant-a"
    && authority.requesterScopes == [ "tenant-a" ]
    && authority.addressFamilies == [ "ipv4" "ipv6" ]
    && authority.fallbackBehavior == "local-authority-before-recursion"
    && lease4.addressFamily == "ipv4"
    && lease6.addressFamily == "ipv6"
    && lease4.addresses == [ "10.20.0.101" ]
    && lease6.addresses == [ "fd00:20::101" ]
    && lease4.scopeDenialDiagnostic == "lease-name-denied-requester-scope"
    && lease6.scopeDenialDiagnostic == "lease-name-denied-requester-scope"
    && staticPublication.publicationScopes == [ "tenant-a" ]
    && reversePublication.reverseName == "printer.tenant-a.lan."
    && discoveryPublication.publicationDenialDiagnostic == "discovery-record-not-published-to-requester-scope"
    && builtins.elem "conflict" diagnosticTypes
    && builtins.elem "duplicate-lease" diagnosticTypes
    && builtins.elem "stale-lease" diagnosticTypes
    && builtins.elem "ambiguous-reverse" diagnosticTypes
    && builtins.all (entry: entry.resolutionAuthority == "cpm-diagnostic") dns.namespaceDiagnostics
' >/dev/null || {
  echo "FAIL dns-namespace-authority-contract: CPM did not preserve explicit namespace authority construction contract" >&2
  exit 1
}

echo "PASS dns-namespace-authority-contract"
