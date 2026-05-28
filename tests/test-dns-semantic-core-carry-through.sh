#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-DNS-SEMANTIC-CARRY-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

input_file="$(mktemp)"
inventory_file="$(mktemp)"
output_json="$(mktemp)"
trap 'rm -f "${input_file}" "${inventory_file}" "${output_json}"' EXIT

cat >"${input_file}" <<'EOF'
{
  meta.networkForwardingModel = {
    name = "network-forwarding-model";
    schemaVersion = 9;
  };

  enterprise.acme.site.ams = {
    siteId = "ams";
    siteName = "acme.ams";

    attachments = [
      { kind = "tenant"; name = "client"; unit = "access"; }
    ];

    policyNodeName = "policy";
    upstreamSelectorNodeName = "upstream";
    coreNodeNames = [ "core-wan-a" "core-nebula" "core-wan-b" ];
    uplinkCoreNames = [ "core-wan-a" "core-wan-b" ];
    uplinkNames = [ "wan-a" "wan-b" ];

    domains = {
      tenants = [
        { name = "client"; ipv4 = "10.20.20.0/24"; ipv6 = "fd00:20::/64"; }
      ];
      externals = [
        { name = "wan-a"; }
        { name = "wan-b"; }
      ];
    };

    tenantPrefixOwners."4|10.20.20.0/24" = {
      family = 4;
      dst = "10.20.20.0/24";
      netName = "client";
      owner = "access";
    };

    communicationContract = {
      services = [
        { name = "site-dns"; providers = [ "access-dns" "nebula-dns" "wan-a-dns" "wan-b-dns" ]; trafficType = "dns"; }
      ];
      allowedRelations = [
        { id = "allow-client-dns"; from = { kind = "tenant"; name = "client"; }; to = { kind = "service"; name = "site-dns"; }; trafficType = "dns"; action = "allow"; }
      ];
    };

    policy.interfaceTags = {
      tenant = "client";
      wan-a = "wan-a";
      wan-b = "wan-b";
      site-dns = "site-dns";
    };

    forwardingSemantics = {
      explicit = true;
      coreNodeNames = [ "core-wan-a" "core-nebula" "core-wan-b" ];
      policyNodeName = "policy";
      upstreamSelectorNodeName = "upstream";
      traversalParticipantNodeNames = [ "access" "policy" "upstream" "core-wan-a" "core-nebula" "core-wan-b" ];
      dns = {
        explicit = true;
        serviceNodeNames = [ "access" "core-nebula" "core-wan-a" "core-wan-b" ];
        accessNodeNames = [ "access" ];
        nonWanCoreNodeNames = [ "core-nebula" ];
        wanFallbackNodeNames = [ "core-wan-a" "core-wan-b" ];
        resolverPreferenceNodeNames = [ "access" "core-nebula" "core-wan-a" "core-wan-b" ];
      };
    };

    nodes = {
      access = {
        role = "access";
        services.dns = { };
        loopback = { ipv4 = "10.19.0.1/32"; ipv6 = "fd00:19::1/128"; };
        interfaces.tenant = {
          interface = "tenant-client";
          kind = "tenant";
          tenant = "client";
          addr4 = "10.20.20.1/24";
          addr6 = "fd00:20::1/64";
          routes = { ipv4 = [ ]; ipv6 = [ ]; };
        };
      };
      policy = {
        role = "policy";
        loopback = { ipv4 = "10.19.0.2/32"; ipv6 = "fd00:19::2/128"; };
        interfaces = { };
      };
      upstream = {
        role = "upstream-selector";
        loopback = { ipv4 = "10.19.0.3/32"; ipv6 = "fd00:19::3/128"; };
        interfaces = { };
      };
      core-nebula = {
        role = "core";
        services.dns = { };
        loopback = { ipv4 = "10.19.0.4/32"; ipv6 = "fd00:19::4/128"; };
        egressIntent = { exit = true; uplinks = [ "east-west" ]; wanInterfaces = [ "east-west" ]; };
        interfaces = { };
      };
      core-wan-a = {
        role = "core";
        services.dns = { };
        loopback = { ipv4 = "10.19.0.5/32"; ipv6 = "fd00:19::5/128"; };
        egressIntent = { exit = true; uplinks = [ "wan-a" ]; wanInterfaces = [ "wan-a" ]; };
        interfaces = { };
      };
      core-wan-b = {
        role = "core";
        services.dns = { };
        loopback = { ipv4 = "10.19.0.6/32"; ipv6 = "fd00:19::6/128"; };
        egressIntent = { exit = true; uplinks = [ "wan-b" ]; wanInterfaces = [ "wan-b" ]; };
        interfaces = { };
      };
    };

    links = { };
    transit = { adjacencies = [ ]; ordering = [ ]; };
  };
}
EOF

cat >"${inventory_file}" <<'EOF'
{
  endpoints = {
    access-dns = { ipv4 = [ "10.20.20.1" ]; ipv6 = [ "fd00:20::1" ]; };
    nebula-dns = { ipv4 = [ "100.96.10.1" ]; ipv6 = [ "fd00:96::1" ]; };
    wan-a-dns = { ipv4 = [ "1.1.1.1" ]; ipv6 = [ "2606:4700:4700::1111" ]; };
    wan-b-dns = { ipv4 = [ "9.9.9.9" ]; ipv6 = [ "2620:fe::fe" ]; };
  };

  realization.nodes = {
    access-runtime = {
      host = "lab";
      platform = "linux";
      logicalNode = { enterprise = "acme"; site = "ams"; name = "access"; };
      ports = { };
      advertisements = {
        dhcp4.tenant = {
          dnsServers = [ "router-self" ];
          domain = "lan.";
        };
        ipv6Ra.tenant = {
          dnssl = [ "lan." ];
          rdnss = [ "router-self" ];
        };
      };
      services.dns = {
        implementation = "bind";
        listen = [ "10.20.20.1" "fd00:20::1" ];
        allowFrom = [ "10.20.20.0/24" "fd00:20::/64" ];
      };
    };
    core-nebula-runtime = {
      host = "lab";
      platform = "linux";
      logicalNode = { enterprise = "acme"; site = "ams"; name = "core-nebula"; };
      ports = { };
      services.dns = { listen = [ "100.96.10.1" "fd00:96::1" ]; };
    };
    core-wan-a-runtime = {
      host = "lab";
      platform = "linux";
      logicalNode = { enterprise = "acme"; site = "ams"; name = "core-wan-a"; };
      ports = { };
      services.dns = { listen = [ "1.1.1.1" "2606:4700:4700::1111" ]; };
    };
    core-wan-b-runtime = {
      host = "lab";
      platform = "linux";
      logicalNode = { enterprise = "acme"; site = "ams"; name = "core-wan-b"; };
      ports = { };
      services.dns = { listen = [ "9.9.9.9" "2620:fe::fe" ]; };
    };
    policy-runtime = {
      host = "lab";
      platform = "linux";
      logicalNode = { enterprise = "acme"; site = "ams"; name = "policy"; };
      ports = { };
    };
    upstream-runtime = {
      host = "lab";
      platform = "linux";
      logicalNode = { enterprise = "acme"; site = "ams"; name = "upstream"; };
      ports = { };
    };
  };
  deployment.hosts.lab = { };
}
EOF

nix eval \
  --impure \
  --json \
  --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      builder = flake.lib.${system}.build;
      input = import ${input_file};
      inventory = import ${inventory_file};
    in
      builder { inherit input inventory; }
  " >"${output_json}"

nix eval --impure --expr "
  let
    data = builtins.fromJSON (builtins.readFile ${output_json});
    site = data.control_plane_model.data.acme.ams;
    dns = site.forwardingSemantics.dns;
    targets = site.runtimeTargets;
  in
    dns.resolverPreferenceNodeNames == [ \"access\" \"core-nebula\" \"core-wan-a\" \"core-wan-b\" ]
    && (targets.access-runtime.services.dns.implementation or null) == \"bind\"
    && ! (targets.core-nebula-runtime.services.dns ? implementation)
    && ! (targets.core-wan-a-runtime.services.dns ? implementation)
    && ! (targets.core-wan-b-runtime.services.dns ? implementation)
    && targets.core-nebula-runtime.services.dns.roles.recursion.outgoingInterfaces == [ \"10.19.0.4\" \"fd00:19::4\" ]
    && targets.core-nebula-runtime.services.dns.roles.recursion.allowedUpstreamClasses == [ \"local-access\" ]
    && targets.core-nebula-runtime.services.dns.roles.local.listen == [ \"100.96.10.1\" \"fd00:96::1\" ]
    && targets.access-runtime.services.dns.roles.recursion.allowedUpstreamClasses == [ \"local-access\" \"explicit-egress-default\" ]
    && targets.access-runtime.services.dns.forwarders == [
      \"100.96.10.1\"
      \"fd00:96::1\"
      \"1.1.1.1\"
      \"2606:4700:4700::1111\"
      \"9.9.9.9\"
      \"2620:fe::fe\"
    ]
" | grep -qx true || {
  echo "FAIL dns-semantic-core-carry-through" >&2
  jq '.control_plane_model.data.acme.ams | {dns: .forwardingSemantics.dns, runtimeTargets: (.runtimeTargets | with_entries(.value = {role: .value.role, services: .value.services}))}' "${output_json}" >&2
  exit 1
}

echo "PASS dns-semantic-core-carry-through"
