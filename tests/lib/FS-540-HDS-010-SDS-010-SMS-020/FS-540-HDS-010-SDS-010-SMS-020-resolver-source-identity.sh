#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
#
# FS-540: a resolver with no modeled egress surface binds its source through
# its modeled resolver path. For an access resolver that path source is its
# own modeled service identity, and the provider's requester ACL must accept
# that same identity. Leaving the recursion source empty makes the query egress
# from whichever fabric address the default route selects, so the provider
# receives a source it did not authorize.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
LABS="${NETWORK_LABS_PATH:-/home/deadbeef/github/network-labs}"
row="${LABS}/GAMP/SMT/FS-540-HDS-010-SDS-010-SMS-045"

fail() {
  echo "FAIL FS-540-HDS-010-SDS-010-SMS-020: $1" >&2
  exit 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

cat >"${tmpdir}/probe.nix" <<NIX
let
  cpm = builtins.getFlake "${repo_root}";
  site = cpm.lib.\${builtins.currentSystem}.compileAndBuildFromPaths {
    inputPath = ${row}/intent.nix;
    inventoryPath = ${row}/inventory-nixos.nix;
  };
  data = site.control_plane_model.data.mini-smt."FS-540-HDS-010-SDS-010-SMS-045";
  access = data.runtimeTargets."mini-smt-FS-540-HDS-010-SDS-010-SMS-045-access-recursive";
  core = data.runtimeTargets."mini-smt-FS-540-HDS-010-SDS-010-SMS-045-core-primary";
  nonLoopback = xs: builtins.filter (x: x != "127.0.0.1" && x != "::1") xs;
  dnsRoles = access.services.dns.roles or { };
  recursionRole = dnsRoles.recursion or { };
in
{
  accessListen = nonLoopback access.services.dns.listen;
  accessOutgoing = nonLoopback (access.services.dns.outgoingInterfaces or [ ]);
  accessRecursionOutgoing = nonLoopback (recursionRole.outgoingInterfaces or [ ]);
  coreAllowFrom = core.services.dns.allowFrom;
}
NIX

result="$(nix eval --impure --json -f "${tmpdir}/probe.nix" 2>/dev/null)"
[[ -n "${result}" ]] || fail "probe evaluation produced no result"

# The resolver carries a modeled listener identity, so the source cannot be
# left empty.
jq -e '(.accessListen | length) > 0' <<<"${result}" >/dev/null \
  || fail "the access resolver carries no modeled listener identity"

# The emitted recursion source must be that identity.
jq -e '
  (.accessOutgoing | length) > 0
  and (.accessOutgoing == .accessListen)
  and (.accessRecursionOutgoing == .accessListen)
' <<<"${result}" >/dev/null || {
  echo "FAIL FS-540-HDS-010-SDS-010-SMS-020: the recursion source is not the resolver's modeled listener identity" >&2
  jq '{listen, accessOutgoing, accessRecursionOutgoing}' <<<"${result}" >&2
  exit 1
}

# The provider's requester ACL must accept the same identity, otherwise the
# resolver is authorized nowhere and the query is refused.
jq -e '
  . as $r
  | [ $r.accessOutgoing[] | select(($r.coreAllowFrom | index(.)) == null) ] | length == 0
' <<<"${result}" >/dev/null || {
  echo "FAIL FS-540-HDS-010-SDS-010-SMS-020: the provider requester ACL does not accept the emitted recursion source" >&2
  jq '{accessOutgoing, coreAllowFrom}' <<<"${result}" >&2
  exit 1
}

echo "PASS FS-540-HDS-010-SDS-010-SMS-020: the recursion source is the resolver identity and the provider accepts it"
