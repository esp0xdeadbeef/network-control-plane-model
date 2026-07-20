#!/usr/bin/env bash
# GAMP-ID: FS-580-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"
fixture_dir="${repo_root}/fixtures/passing/dns-killswitch-policy-matrix"
output_json="$(mktemp)"
trap 'rm -f "${output_json}"' EXIT

nix eval --impure --json --expr "
  let
    flake = builtins.getFlake (toString ${repo_root});
    builder = flake.lib.${system}.build;
    input = import ${fixture_dir}/input.nix;
    inventory = import ${fixture_dir}/inventory.nix;
  in
    builder { inherit input inventory; }
" > "${output_json}"

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    dns = data.control_plane_model.data.acme.ams.runtimeTargets.access-runtime.services.dns;
    classes = dns.publicDnsTrafficClassifications or [ ];

    anyClass = predicate:
      builtins.any predicate classes;

    modeledResolver =
      anyClass
        (entry:
          (entry.kind or null) == "public-dns-traffic-classification"
          && (entry.trafficClass or null) == "modeled-resolver-traffic"
          && (entry.requesterScope or null) == "access-runtime"
          && (entry.resolverDestination or null) == "10.20.0.1"
          && (entry.egressSurface or null) == "local-access"
          && (entry.protocol or null) == "tcp-udp"
          && (entry.port or null) == "53"
          && (entry.dnsPolicy or null) == "modeled-resolver-relationship"
          && (entry.egressPolicy or null) == "not-direct-public-dns");

    deniedDirectPublicDns =
      anyClass
        (entry:
          (entry.kind or null) == "public-dns-traffic-classification"
          && (entry.trafficClass or null) == "denied-direct-public-dns"
          && (entry.requesterScope or null) == "access-runtime"
          && (entry.resolverDestination or null) == "1.1.1.1/32"
          && (entry.egressSurface or null) == "explicit-egress-default"
          && (entry.protocol or null) == "tcp-udp"
          && (entry.port or null) == "53"
          && (entry.dnsPolicy or null) == "direct-public-dns-forbidden"
          && (entry.egressPolicy or null) == "egress-allowed");

    unrelatedPayload =
      anyClass
        (entry:
          (entry.kind or null) == "public-dns-traffic-classification"
          && (entry.trafficClass or null) == "unrelated-payload"
          && (entry.requesterScope or null) == "access-runtime"
          && (entry.resolverDestination or null) == "1.1.1.1/32"
          && (entry.egressSurface or null) == "explicit-egress-default"
          && (entry.protocol or null) == "non-dns"
          && (entry.port or null) == "not-53"
          && (entry.dnsPolicy or null) == "not-dns-traffic"
          && (entry.egressPolicy or null) == "egress-allowed");

    noDestinationOnlyLeakClass =
      builtins.all
        (entry:
          !((entry.resolverDestination or null) == "1.1.1.1/32"
            && (entry.trafficClass or null) == "denied-direct-public-dns"
            && (entry.protocol or null) == "non-dns"))
        classes;
  in
    modeledResolver
    && deniedDirectPublicDns
    && unrelatedPayload
    && noDestinationOnlyLeakClass
' >/dev/null || {
  echo "FAIL public-dns-flow-classification: CPM did not emit the FS-580 SMS-010 public DNS traffic classes" >&2
  jq '.control_plane_model.data.acme.ams.runtimeTargets["access-runtime"].services.dns.publicDnsTrafficClassifications' "${output_json}" >&2
  exit 1
}

echo "PASS public-dns-flow-classification"
