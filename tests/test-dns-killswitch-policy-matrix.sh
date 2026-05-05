#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"
fixture_dir="${repo_root}/fixtures/passing/dns-killswitch-policy-matrix"
input_path="${fixture_dir}/input.nix"
inventory_path="${fixture_dir}/inventory.nix"
malformed_inventory_path="${fixture_dir}/malformed-inventory.nix"
expected_path="${fixture_dir}/expected-dns-policy.json"

if [[ ! -f "${input_path}" || ! -f "${inventory_path}" || ! -f "${expected_path}" ]]; then
  cat >&2 <<EOF
FATAL network-control-plane-model DNS kill-switch policy-matrix fixture is incomplete.

missing fixture:
  - ${input_path}
  - ${inventory_path}
  - ${malformed_inventory_path}
  - ${expected_path}

The fixture is part of the CPM contract. Restore it instead of weakening this
test; expected behavior must stay derived from the model pipeline, not from
renderer or NixOS glue.

The fixture must contain a policy matrix with at least these access classes:

  - local-only: may query only its own access router DNS
  - overlay-allowed: may query local DNS and modeled overlay/core DNS
  - service-dns-allowed: may query local DNS and a modeled site/service DNS
  - explicit-egress-dns: may query local DNS and explicit egress/default DNS
    only because intent says so
  - denied: has DNS advertised locally but must not receive upstream DNS routes
    or public resolver fallback
  - broken-policy: deliberately malformed DNS policy that CPM must reject in a
    negative companion case before renderer evaluation

Every access runtime target and every WAN/core egress runtime target in the
fixture must have a DNS service contract. In this project that means renderers
can later materialize Unbound for both Containerlab and NixOS, but this CPM test
must prove the contract before either renderer runs.

Required CPM output per access runtime target:

  services.dns.killSwitch.enabled = true
  services.dns.killSwitch.blockPublicResolvers = true
  services.dns.killSwitch.blockImplicitDefaultRouteDns = true
  services.dns.killSwitch.allowPublicResolverFallback = false
  services.dns.routePreference = [
    "local-access"
    "overlay-core"
    "service-dns"
    "explicit-egress-default"
  ]
  services.dns.allowedUpstreamClasses = <from ${expected_path}>
  services.dns.deniedResolverCidrs contains common public DNS resolver /32 and /128 targets
  services.dns.routeContracts contains no implicit 0.0.0.0/0 or ::/0 DNS escape

Required negative proof:

  The same fixture directory must include a malformed policy case that fails in
  CPM with a path-specific DNS error before any renderer can materialize local
  nftables/routes. A fix that only edits NixOS modules, CLAB scripts, or
  renderer-side firewall snippets must not make this test pass.
EOF
  exit 1
fi

if [[ ! -f "${malformed_inventory_path}" ]]; then
  echo "FATAL dns-killswitch-policy-matrix missing negative malformed inventory: ${malformed_inventory_path}" >&2
  exit 1
fi

output_json="$(mktemp)"
malformed_stderr="$(mktemp)"
trap 'rm -f "${output_json}" "${malformed_stderr}"' EXIT

if nix eval --impure --json --expr "
  let
    flake = builtins.getFlake (toString ${repo_root});
    builder = flake.lib.${system}.build;
    input = import ${input_path};
    inventory = import ${malformed_inventory_path};
  in
    builder { inherit input inventory; }
" >/dev/null 2>"${malformed_stderr}"; then
  echo "FAIL dns-killswitch-policy-matrix: malformed DNS policy unexpectedly evaluated" >&2
  exit 1
fi

if ! grep -Fq "services.dns.killSwitch.allowPublicResolverFallback" "${malformed_stderr}"; then
  echo "FAIL dns-killswitch-policy-matrix: malformed DNS policy failed without path-specific error" >&2
  cat "${malformed_stderr}" >&2
  exit 1
fi

nix eval --impure --json --expr "
  let
    flake = builtins.getFlake (toString ${repo_root});
    builder = flake.lib.${system}.build;
    input = import ${input_path};
    inventory = import ${inventory_path};
  in
    builder { inherit input inventory; }
" > "${output_json}"

OUTPUT_JSON="${output_json}" EXPECTED_JSON="${expected_path}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    expected = builtins.fromJSON (builtins.readFile (builtins.getEnv "EXPECTED_JSON"));
    site = data.control_plane_model.data.${expected.enterprise}.${expected.site};
    runtimeTargets = site.runtimeTargets or { };

    routePreference = [
      "local-access"
      "overlay-core"
      "service-dns"
      "explicit-egress-default"
    ];

    publicResolverCidrs = [
      "1.1.1.1/32"
      "1.0.0.1/32"
      "8.8.8.8/32"
      "8.8.4.4/32"
      "9.9.9.9/32"
      "2606:4700:4700::1111/128"
      "2606:4700:4700::1001/128"
      "2001:4860:4860::8888/128"
      "2001:4860:4860::8844/128"
      "2620:fe::fe/128"
    ];

    dnsFor = targetName: (runtimeTargets.${targetName}.services or { }).dns or null;

    hasNoImplicitDefaultDns = dns:
      builtins.all
        (route:
          !((route.destination or null) == "0.0.0.0/0" && !((route.explicitlyAllowed or false)))
          && !((route.destination or null) == "::/0" && !((route.explicitlyAllowed or false))))
        (dns.routeContracts or [ ]);

    accessOk = targetName: expectedClasses:
      let
        dns = dnsFor targetName;
        killSwitch = dns.killSwitch or { };
      in
        dns != null
        && (killSwitch.enabled or false)
        && (killSwitch.blockPublicResolvers or false)
        && (killSwitch.blockImplicitDefaultRouteDns or false)
        && !(killSwitch.allowPublicResolverFallback or true)
        && (dns.routePreference or [ ]) == routePreference
        && (dns.allowedUpstreamClasses or [ ]) == expectedClasses
        && builtins.all (cidr: builtins.elem cidr (dns.deniedResolverCidrs or [ ])) publicResolverCidrs
        && hasNoImplicitDefaultDns dns;

    policyMatrixOk = entry:
      let
        dns = dnsFor entry.target;
        matches =
          builtins.filter
            (policy: (policy.name or null) == entry.name)
            (dns.policyMatrix or [ ]);
      in
        matches != [ ]
        && ((builtins.head matches).allowedUpstreamClasses or [ ]) == entry.allowedUpstreamClasses;

    accessMatrixOk =
      builtins.all
        (entry: accessOk entry.target (dnsFor entry.target).allowedUpstreamClasses && policyMatrixOk entry)
        expected.accessMatrix;

    wanCoreDnsOk =
      builtins.all
        (targetName: dnsFor targetName != null && ((dnsFor targetName).implementation or null) == "unbound")
        expected.wanCoreDnsTargets;
  in
    accessMatrixOk && wanCoreDnsOk
' >/dev/null || {
  cat >&2 <<'EOF'
FAIL dns-killswitch-policy-matrix

CPM output did not satisfy the modeled DNS kill-switch matrix. Expected every
access DNS contract to carry strict kill-switch metadata, public resolver deny
CIDRs, deterministic route preference, and allowed upstream classes from the
fixture expectation. This must be fixed in CPM/model output, not in NixOS or
Containerlab renderer glue.
EOF
  exit 1
}

echo "PASS dns-killswitch-policy-matrix"
