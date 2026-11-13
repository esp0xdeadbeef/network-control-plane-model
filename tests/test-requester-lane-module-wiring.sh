#!/usr/bin/env bash
# GAMP-ID: FS-540-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
#
# SPEC:   GAMP/SMS/FS-540-HDS-010-SDS-010-SMS-040.md  (Requester-Lane Reachability)
# OWNER:  network-control-plane-model
#
# Predicate: the module that implements requester-lane recursive reachability is
# reachable from the runtime-target pipeline.
#
# FS-540-HDS-010-SDS-010-SMS-040 defines reachability "from an authorized
# requester lane to the modeled resolver", and its seeded negative is "Remove
# requester-lane routes while retaining provider routes; fail".
#
# src/cpm/ControlModule/runtime-targets/requester-lane-recursive-reachability.nix
# implements exactly that, and its header documents the installation point:
#
#     # Usage from finalize.nix or an equivalent integration point:
#     #   addRequesterLaneKeying = import ./requester-lane-recursive-reachability.nix { ... };
#
# Nothing imports it. `grep -rn "requester-lane-recursive-reachability" src` finds
# only that comment, so the module is dead code and requester lanes carry no
# resolver reachability at all. tests/test-dns-service-policy-routes.sh asserts
# that fact from the other side and fails on it:
#
#     failed checks:
#       admittedDmzLaneLearnsMgmtDnsV4
#       clientLaneLearnsAllowedMgmtDnsV4
#       clientLaneLearnsAllowedMgmtDnsV6
#       clientLaneRouteIsPolicyTableAuthorityV4
#       clientLaneRouteIsPolicyTableAuthorityV6
#
# Wiring it in is not a one-line change: doing so makes the module's own
# fail-closed check fire on the shared lab fixtures ("target(s) ... carry DNS
# service routes but lack a matching DNS forwarding rule"), which regresses
# FS-470-SMS-090 and others. So the inconsistency the module was written to
# catch is real and currently unaddressed; this case records the gap instead of
# hiding it.
#
# This is not an upstream bug that another repository should fix.
# `service-dns-reachability` is CPM's own route-intent vocabulary: it appears in
# network-forwarding-model, network-compiler and network-labs zero times, so
# neither the forwarding model nor the compiler can emit it and neither can be
# tested for it. The fact is produced and consumed entirely inside this
# repository, which is why the case lives here.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
require_cmd rg

fail() { echo "FAIL requester-lane-module-wiring: $*" >&2; exit 1; }

module="src/cpm/ControlModule/runtime-targets/requester-lane-recursive-reachability.nix"
finalize="src/cpm/ControlModule/runtime-targets/finalize.nix"

[[ -f "${repo_root}/${module}" ]] \
  || fail "P1 the requester-lane reachability module is missing; the row has no implementation to check"

# P1: the module must be imported by the runtime-target pipeline. A comment that
# documents the installation point is not an installation.
# Exclude comment lines: the module's own header documents the import as a usage
# example, and matching that would report the gap as closed.
if ! rg -q --glob '*.nix' --glob '!requester-lane-recursive-reachability.nix' \
       '^[^#]*import \./requester-lane-recursive-reachability\.nix' "${repo_root}/src"; then
  echo "FAIL requester-lane-module-wiring: P1 nothing imports" >&2
  echo "  ${module}." >&2
  echo "  FS-540-HDS-010-SDS-010-SMS-040 requires requester-lane reachability to the" >&2
  echo "  modeled resolver, and this module implements it. Its own header names the" >&2
  echo "  installation point (${finalize}: addRequesterLaneKeying), but the only" >&2
  echo "  occurrence in src/ is that comment. Requester lanes therefore carry no" >&2
  echo "  resolver reachability, which tests/test-dns-service-policy-routes.sh" >&2
  echo "  reports as admittedDmzLaneLearnsMgmtDnsV4, clientLaneLearnsAllowedMgmtDnsV4," >&2
  echo "  clientLaneLearnsAllowedMgmtDnsV6, clientLaneRouteIsPolicyTableAuthorityV4" >&2
  echo "  and clientLaneRouteIsPolicyTableAuthorityV6 failing." >&2
  echo "  Wiring it alone is not enough, and that was measured rather than assumed:" >&2
  echo "  with the import added to finalize.nix the module's own seeded-negative" >&2
  echo "  check fires on the shared lab fixtures --" >&2
  echo "    FS-540-HDS-010-SDS-010-SMS-040: target(s) ... carry DNS service routes" >&2
  echo "    but lack a matching DNS forwarding rule" >&2
  echo "  -- which regresses FS-470-SMS-090 (PASS before the wiring, FAIL after) and" >&2
  echo "  test-realized-interface-routes.sh. The inconsistency the module exists to" >&2
  echo "  catch is therefore real and unaddressed, and this row cannot close by" >&2
  echo "  enabling the module or by silencing its diagnostic: both are forbidden by" >&2
  echo "  AGENTS.md. Resolve the DNS-routes-without-forwarding-rule inconsistency" >&2
  echo "  first, then wire the module in; this assertion then holds." >&2
  fail "P1 the requester-lane reachability module is not imported by the pipeline"
fi

echo "PASS requester-lane-module-wiring"
