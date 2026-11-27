#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
#
# ============================================================================
# WHAT THIS ASSERTS, AND THE DEFECT THAT MADE IT NECESSARY
# ============================================================================
#
# FS-540 says an access resolver forwards to `core-dns`, and that `core-dns` is
# the only DNS egress surface. A resolver CONFIGURED to forward to an address
# nothing routes to does not satisfy that: it answers what it already holds
# from its own authority, cannot forward anything else, and every "is the
# resolver up" check still passes.
#
# Measured on this repository's own cobalt render (2026-11-21, VM HAT,
# GAMP/HAT/evidence/dns-load-2026-11-21.md in the site repository):
#
#   tenant-client$ dig @10.2.30.1 x<random>.dnsperf.hat.invalid
#     eth0  Out IP 10.2.30.100 > 10.2.30.1.53: A? x1692...
#     eth0  In  IP 10.2.30.1.53 > 10.2.30.100: NXDomain* 0/1/1
#     -- answered in ~280 us, and NO packet left the access node
#
#   access-clients$ ip -4 route get 10.1.1.8
#     RTNETLINK answers: Network is unreachable
#   core$ ss -lntu | grep 10.1.1.8
#     udp UNCONN ... 10.1.1.8:53        <- core-dns WAS listening there
#
# So: the resolver is up, the provider is up, and there is no road between
# them. That is a fact about the compiled model, which is why it is asserted
# here and not left to a booted site.
#
# Per resolver binding, from the model:
#
#   1. it names an upstream node and at least one upstream address;
#   2. the requesting target has a route whose destination CONTAINS each
#      upstream address.
#
# NOT asserted here: `directPublicFallback`. It is an INTENT field, and the
# compiled model does not carry it on the binding (measured: the emitted
# `named-core-resolver` record has no such key), so a check for it here would
# read `null // false` and pass whatever the intent said -- an assertion that
# cannot fail is worse than none. It is covered where the intent is read
# (`FS-540-HDS-010-SDS-010-SMS-020.sh`, which asserts the resolver-source
# contract from the row's intent).
#
# What this case deliberately does NOT assert: that the road is a /32 to the
# resolver. FS-540 SMS-040 wants one and the emitter does not produce one yet
# (see network-forwarding-model, tests/lib/*/FS-540-HDS-010-SDS-010-SMS-040.sh,
# "NOT YET ASSERTED"). A case that demanded it here would be red against a
# known-open feature and would hide the regression this one does guard.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
  echo "FAIL FS-540-HDS-010-SDS-010-SMS-020: $*" >&2
  exit 1
}

# The row's own controlled fixture, not a site model: a site model needs a
# sibling nixos checkout, and this test must run from a clone of this
# repository alone.
labs_root="${NETWORK_LABS_PATH:-$(flake-archive-offline --json "path:${repo_root}" | jq -er '.inputs["network-labs"].path')}"
row="${labs_root}/GAMP/SMT/FS-540-HDS-010-SDS-010-SMS-020"
[[ -f "${row}/intent.nix" ]] || fail "missing controlled row source ${row}/intent.nix"
inventory="${row}/inventory-nixos.nix"
[[ -f "${inventory}" ]] || fail "missing controlled row inventory ${inventory}"

report="${tmp_dir}/report.json"
if ! nix run --no-write-lock-file "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${row}/intent.nix" "${inventory}" "${report}" >"${tmp_dir}/log" 2>&1; then
  fail "the control plane model did not compile:
$(tail -20 "${tmp_dir}/log")"
fi

# Flatten every named-core-resolver binding into one record: the requester, the
# upstream it names, the roads that requester has, and its fallback policy.
# `(.ipv4 // [])[] , (.ipv6 // [])[]` -- two streams, not two concatenated
# arrays. Concatenating first and then piping through `.[]` leaves `.` bound to
# a sub-expression, and a following `//` or field access then reads a LIST where
# it expects a route; measured as `Cannot index array with string ("dst")`.
jq '
  .control_plane_model.data."mini-smt"."FS-540-HDS-010-SDS-010-SMS-020".runtimeTargets as $targets
  | [
      $targets
      | to_entries[]
      | select((.value.services.dns.upstreamResolvers // [ ]) | length > 0)
      | .key as $targetName
      | .value as $target
      | ($target.services.dns.upstreamResolvers // [ ])[]
      | select((.kind // "") == "named-core-resolver")
      | {
          requester: $targetName,
          upstreamNode: (.node // null),
          upstreamAddrs: (
            (.addresses // .upstreamAddresses // [ ])
            | map(if type == "object" then (.v4 // .v6 // null) else . end)
            | map(select(. != null))
          ),
          routes: [
            $target.effectiveRuntimeRealization.interfaces
            | to_entries[]
            | .value.routes
            | (.ipv4 // [ ])[], (.ipv6 // [ ])[]
            | { dst: (.dst // null), policyOnly: (.policyOnly // false) }
            | select(.dst != null)
          ]
        }
    ]
  ' "${report}" >"${tmp_dir}/rows.json"

count="$(jq 'length' "${tmp_dir}/rows.json")"
[[ "${count}" != "0" ]] || fail "no resolver binding of kind named-core-resolver was emitted at all"

# 1. A binding with no address is the "configured to forward to nothing" shape.
jq -e 'all(.[]; (.upstreamNode // "") != "" and ((.upstreamAddrs | length) > 0))' \
  "${tmp_dir}/rows.json" >/dev/null || {
  echo "FAIL FS-540-HDS-010-SDS-010-SMS-020: a resolver binding names no upstream address, so it cannot forward" >&2
  jq '[ .[] | select((.upstreamNode // "") == "" or (.upstreamAddrs | length) == 0) ]' "${tmp_dir}/rows.json" >&2
  exit 1
}

# 2. Reachability, with this repository's own IPv4 arithmetic rather than a
#    second implementation of CIDR containment in a test. The probe is a file,
#    not an `--expr` string: the quoting in a string-built expression is how a
#    check silently ends up evaluating something other than what it says.
cat >"${tmp_dir}/reachable.nix" <<'NIX'
let
  # Environment, not `--arg`: this is how every other probe in this repository
  # is parameterised (`REPO_ROOT`, `OUTPUT_JSON`, ...), and it keeps the
  # expression a plain file that can be read and evaluated on its own.
  repoRoot = builtins.getEnv "REPO_ROOT";
  rowsPath = builtins.getEnv "ROWS_JSON";
  system = builtins.currentSystem;
  flake = builtins.getFlake ("path:" + repoRoot);
  pkgs = flake.inputs.nixpkgs.legacyPackages.${system};
  common = import (repoRoot + "/src/cpm/ControlModule/lib/ipam/common.nix") { lib = pkgs.lib; };
  ipv4 = import (repoRoot + "/src/cpm/ControlModule/lib/ipam/ipv4.nix") { inherit common; };
  rows = builtins.fromJSON (builtins.readFile rowsPath);

  # One requester/address pair per (requester, upstream address).
  pairs = builtins.concatMap
    (r:
      map (addr: { inherit (r) requester routes; inherit addr; })
        (builtins.filter (a: ipv4.parseIPv4 a != null) r.upstreamAddrs))
    rows;

  coveredBy =
    route: addr:
    let
      parsed = common.splitCIDR route.dst;
      net = if parsed == null then null else ipv4.parseIPv4 parsed.addr;
      target = ipv4.parseIPv4 addr;
    in
    parsed != null
    && net != null
    && target != null
    && ipv4.ipv4NetworkBaseInt {
      addrInt = ipv4.ipv4ToInt target;
      inherit (parsed) prefixLen;
    } == ipv4.ipv4NetworkBaseInt {
      addrInt = ipv4.ipv4ToInt net;
      inherit (parsed) prefixLen;
    };

  isDefault = route: route.dst == "0.0.0.0/0" || route.dst == "::/0";

  # A `policyOnly` route is, by construction, installed into the policy table
  # that carries FORWARDED tenant traffic. The resolver's own queries are
  # locally generated, so they consult the non-policy routes. The distinction
  # is what makes this case assert the right thing: a `policyOnly` default is
  # ordinary tenant egress and is not a DNS fallback for the resolver, while a
  # NON-policyOnly default is.
  ownPath = route: !(route.policyOnly or false);

  # Coverage by a route the resolver's own traffic can actually use: non-policy
  # and not a default.
  coveredByModelled = p: builtins.any
    (route: ownPath route && !(isDefault route) && coveredBy route p.addr)
    p.routes;

  # A non-policy default is general DNS egress: it reaches the WAN and every
  # tenant sub-net, which `deny-clients-dns-to-wan` and the tang restriction
  # forbid an access resolver from having.
  hasOwnDefault = p: builtins.any (route: ownPath route && isDefault route) p.routes;

  verdicts = map
    (p: {
      inherit (p) requester addr;
      reachable = coveredByModelled p;
      defaultEgress = hasOwnDefault p;
      onlyByDefault =
        builtins.any (route: ownPath route && coveredBy route p.addr) p.routes
        && !(coveredByModelled p);
    })
    pairs;
in
verdicts
NIX

verdicts="$(REPO_ROOT="${repo_root}" ROWS_JSON="${tmp_dir}/rows.json" \
  nix eval --impure --json --file "${tmp_dir}/reachable.nix" 2>"${tmp_dir}/nx")" \
  || fail "reachability evaluation failed:
$(tail -20 "${tmp_dir}/nx")"

unreachable="$(jq -r '[ .[] | select(.reachable | not) | "\(.requester) -> \(.addr)" ] | unique | join(", ")' <<<"${verdicts}")"
if [[ -n "${unreachable}" ]]; then
  {
    echo "FAIL FS-540-HDS-010-SDS-010-SMS-020: a resolver is configured to forward to an address its requester has no route to."
    echo
    echo "  unreachable: ${unreachable}"
    echo
    echo "At runtime such a resolver answers NXDOMAIN or SERVFAIL from its own"
    echo "authority and never forwards, while every unit reports healthy -- the"
    echo "shape measured on cobalt on 2026-11-21 (see this file's header)."
    echo
    for requester in $(jq -r '[ .[] | select(.reachable | not) | .requester ] | unique | .[]' <<<"${verdicts}"); do
      echo "  ${requester} has these destinations:"
      jq -r --arg r "${requester}" '
        [ .[] | select(.requester == $r) | .routes[].dst ] | unique | .[]
        | "    " + .
      ' "${tmp_dir}/rows.json"
    done
  } >&2
  exit 1
fi

# A non-policy default on the resolver's own path is general DNS egress.
default_egress="$(jq -r '[ .[] | select(.defaultEgress) | "\(.requester)" ] | unique | join(", ")' <<<"${verdicts}")"
if [[ -n "${default_egress}" ]]; then
  {
    echo "FAIL FS-540-HDS-010-SDS-010-SMS-020: a resolver's own traffic has a default route."
    echo
    echo "  ${default_egress}"
    echo
    echo "A default route is not a modelled path to one service endpoint: it is a"
    echo "road to the WAN and to every tenant sub-net. deny-clients-dns-to-wan"
    echo "forbids the WAN, and the tang/unlock sub-net carries no DNS egress"
    echo "beyond its own resolver endpoint. A policyOnly default is exempt: that"
    echo "one belongs to the forwarded-tenant policy table, not to the resolver."
  } >&2
  exit 1
fi

only_default="$(jq -r '[ .[] | select(.onlyByDefault) | "\\(.requester) -> \\(.addr)" ] | unique | join(", ")' <<<"${verdicts}")"
if [[ -n "${only_default}" ]]; then
  {
    echo "FAIL FS-540-HDS-010-SDS-010-SMS-020: a resolver reaches its upstream ONLY through a default route."
    echo
    echo "  ${only_default}"
    echo
    echo "A default route is a road to everything, not a modelled path to one"
    echo "service endpoint. An access resolver has DNS egress to its modelled"
    echo "upstream endpoints only -- deny-clients-dns-to-wan forbids the WAN, and"
    echo "the tang/unlock sub-net carries no DNS egress beyond its own resolver."
    echo "Emitted: a default, or a route that only the default covers. Expected:"
    echo "a host route or the upstream's own modelled prefix."
  } >&2
  exit 1
fi

echo "PASS FS-540-HDS-010-SDS-010-SMS-020: ${count} resolver binding(s) name an upstream address their requester reaches by a modelled route"
