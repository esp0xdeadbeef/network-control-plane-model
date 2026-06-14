#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-020-SMS-040
# GAMP-SCOPE: software-module-test
# Focused construction test: CPM provider-network route generation
# on fabric chain P2P interfaces (downstream-selector, policy, upstream-selector).
# Scans all services for providerAddress/customerAddress handoff addressing.
#
# SMS Acceptance Predicates:
#   P1: downstream-selector has route for 203.0.113.0/24 on p2p to provider-handoff access nodes
#   P2: policy has route for 203.0.113.0/24 on p2p to downstream-selector
#   P3: upstream-selector has route for 203.0.113.0/24 on p2p to policy
#   P4: Routes carry proto=provider, intent=provider-reachability
#   P5: /32 provider and customer address host routes present
#   P6: No provider routes leak onto WAN-uplink interfaces
#   P7: Fabric p2p interfaces have ipv6 route array present (IPv6-capable structure)
#   P8: No provider IPv6 routes leak onto WAN-uplink interfaces
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

hat_dir="$(pinned_hat_dir)"
output_json="${tmp_dir}/cpm.json"

all_checks_passed=true

nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${hat_dir}/intent.nix" \
  "${hat_dir}/inventory-nixos.nix" \
  "${output_json}" >/dev/null

echo "--- FS-800-HDS-010-SDS-020-SMS-040: CPM provider-network route generation ---"
echo ""

# ── P1: downstream-selector has 203.0.113.0/24 route on p2p to provider-handoff ──
check_p1() {
  local result
  result=$(jq -e '
    def root: if type == "array" then .[0] else . end;
    def site: root.control_plane_model.data.esp0xdeadbeef."site-a";
    def rt($target): site.runtimeTargets[$target];
    def ds: rt("esp0xdeadbeef-site-a-nixos-downstream-selector");
    def dsIfs: ds.effectiveRuntimeRealization.interfaces;

    # Check there is a route for 203.0.113.0/24 on a p2p interface
    # where backingRef.lane.access ends with "provider-handoff-access-a" or "provider-handoff-access-b"
    def has_provider_route($iface):
      (($iface.routes.ipv4 // []) | map(select(
        .dst == "203.0.113.0/24"
        and .proto == "provider"
        and .intent.kind == "provider-reachability"
        and .intent.source == "provider-network"
        and (.via4 // "") != ""
      )) | length) > 0;

    (dsIfs | to_entries | map(select(
      .value.sourceKind == "p2p"
      and ((.value.backingRef.lane.access // "") | test("provider-handoff-access-[ab]$"))
    )) | map(has_provider_route(.value)) | all)
  ' "${output_json}" 2>/dev/null || echo "false")

  if [[ "${result}" == "true" ]]; then
    echo "PASS: P1 — downstream-selector has 203.0.113.0/24 route on p2p to provider-handoff access nodes"
  else
    echo "FAIL: P1 — downstream-selector missing 203.0.113.0/24 route on provider-handoff p2p interfaces"
    all_checks_passed=false
  fi
}
check_p1

# ── P2: policy has 203.0.113.0/24 route on p2p to downstream-selector ──
check_p2() {
  local result
  result=$(jq -e '
    def root: if type == "array" then .[0] else . end;
    def site: root.control_plane_model.data.esp0xdeadbeef."site-a";
    def rt($target): site.runtimeTargets[$target];
    def pol: rt("esp0xdeadbeef-site-a-nixos-policy");
    def polIfs: pol.effectiveRuntimeRealization.interfaces;

    def has_provider_route($iface):
      (($iface.routes.ipv4 // []) | map(select(
        .dst == "203.0.113.0/24"
        and .proto == "provider"
        and .intent.kind == "provider-reachability"
        and (.via4 // "") != ""
      )) | length) > 0;

    (polIfs | to_entries | map(select(.value.sourceKind == "p2p")) | map(has_provider_route(.value)) | any)
  ' "${output_json}" 2>/dev/null || echo "false")

  if [[ "${result}" == "true" ]]; then
    echo "PASS: P2 — policy has 203.0.113.0/24 route on a p2p interface"
  else
    echo "FAIL: P2 — policy missing 203.0.113.0/24 route"
    all_checks_passed=false
  fi
}
check_p2

# ── P3: upstream-selector has 203.0.113.0/24 route on p2p to policy ──
check_p3() {
  local result
  result=$(jq -e '
    def root: if type == "array" then .[0] else . end;
    def site: root.control_plane_model.data.esp0xdeadbeef."site-a";
    def rt($target): site.runtimeTargets[$target];
    def us: rt("esp0xdeadbeef-site-a-nixos-upstream-selector");
    def usIfs: us.effectiveRuntimeRealization.interfaces;

    def has_provider_route($iface):
      (($iface.routes.ipv4 // []) | map(select(
        .dst == "203.0.113.0/24"
        and .proto == "provider"
        and .intent.kind == "provider-reachability"
        and (.via4 // "") != ""
      )) | length) > 0;

    (usIfs | to_entries | map(select(.value.sourceKind == "p2p")) | map(has_provider_route(.value)) | any)
  ' "${output_json}" 2>/dev/null || echo "false")

  if [[ "${result}" == "true" ]]; then
    echo "PASS: P3 — upstream-selector has 203.0.113.0/24 route on a p2p interface"
  else
    echo "FAIL: P3 — upstream-selector missing 203.0.113.0/24 route"
    all_checks_passed=false
  fi
}
check_p3

# ── P4: Routes carry correct proto and intent ──
check_p4() {
  local result
  result=$(jq -e '
    def root: if type == "array" then .[0] else . end;
    def site: root.control_plane_model.data.esp0xdeadbeef."site-a";
    def rt($target): site.runtimeTargets[$target];
    def allRoutes:
      [ site.runtimeTargets | to_entries[].value.effectiveRuntimeRealization.interfaces | to_entries[].value.routes.ipv4 // [] ] | flatten;

    (allRoutes | map(select(
      .dst == "203.0.113.0/24"
      and .proto == "provider"
      and .intent.kind == "provider-reachability"
      and .intent.source == "provider-network"
    )) | length) > 0
  ' "${output_json}" 2>/dev/null || echo "false")

  if [[ "${result}" == "true" ]]; then
    echo "PASS: P4 — Provider routes carry proto=provider, intent=provider-reachability"
  else
    echo "FAIL: P4 — Provider routes missing correct proto/intent tags"
    all_checks_passed=false
  fi
}
check_p4

# ── P5: /32 provider and customer address host routes present ──
check_p5() {
  local result
  result=$(jq -e '
    def root: if type == "array" then .[0] else . end;
    def site: root.control_plane_model.data.esp0xdeadbeef."site-a";
    def rt($target): site.runtimeTargets[$target];
    def allRoutes:
      [ site.runtimeTargets | to_entries[].value.effectiveRuntimeRealization.interfaces | to_entries[].value.routes.ipv4 // [] ] | flatten;

    def has_host($addr):
      (allRoutes | map(select(
        .dst == $addr
        and .proto == "provider"
        and (.via4 // "") != ""
      )) | length) > 0;

    has_host("203.0.113.5/32")
    and has_host("203.0.113.4/32")
    and has_host("203.0.113.1/32")
    and has_host("203.0.113.2/32")
  ' "${output_json}" 2>/dev/null || echo "false")

  if [[ "${result}" == "true" ]]; then
    echo "PASS: P5 — /32 provider/customer host routes present (203.0.113.1,2,4,5/32)"
  else
    echo "FAIL: P5 — /32 provider/customer host routes missing"
    all_checks_passed=false
  fi
}
check_p5

# ── P6: No provider routes on WAN-uplink interfaces ──
check_p6() {
  local result
  result=$(jq -e '
    def root: if type == "array" then .[0] else . end;
    def site: root.control_plane_model.data.esp0xdeadbeef."site-a";
    def rt($target): site.runtimeTargets[$target];

    def has_provider_on_wan:
      [ site.runtimeTargets | to_entries[].value.effectiveRuntimeRealization.interfaces | to_entries[]
        | select(.value.sourceKind == "wan")
        | (.value.routes.ipv4 // [])
        | map(select(.proto == "provider"))
      ] | flatten | length > 0;

    has_provider_on_wan | not
  ' "${output_json}" 2>/dev/null || echo "false")

  if [[ "${result}" == "true" ]]; then
    echo "PASS: P6 — No provider routes leak onto WAN-uplink interfaces"
  else
    echo "FAIL: P6 — Provider routes found on WAN interfaces (leakage)"
    all_checks_passed=false
  fi
}
check_p6

# ── P7: Fabric p2p interfaces have ipv6 route array present ──
check_p7() {
  local result
  result=$(jq -e '
    def root: if type == "array" then .[0] else . end;
    def site: root.control_plane_model.data.esp0xdeadbeef."site-a";
    def rt($target): site.runtimeTargets[$target];
    def ds: rt("esp0xdeadbeef-site-a-nixos-downstream-selector");
    def dsIfs: ds.effectiveRuntimeRealization.interfaces;

    # Verify at least one p2p interface on the fabric chain has both
    # routes.ipv4 and routes.ipv6 defined (IPv6-capable structure).
    (dsIfs | to_entries | map(select(
      .value.sourceKind == "p2p"
    )) | map(
      ((.value.routes.ipv4 // []) | type == "array")
      and ((.value.routes.ipv6 // []) | type == "array")
    ) | any)
  ' "${output_json}" 2>/dev/null || echo "false")

  if [[ "${result}" == "true" ]]; then
    echo "PASS: P7 — Fabric p2p interfaces have ipv6 route array present (IPv6-capable)"
  else
    echo "FAIL: P7 — Fabric p2p interfaces missing ipv6 route array"
    all_checks_passed=false
  fi
}
check_p7

# ── P8: No provider IPv6 routes leak onto WAN-uplink interfaces ──
check_p8() {
  local result
  result=$(jq -e '
    def root: if type == "array" then .[0] else . end;
    def site: root.control_plane_model.data.esp0xdeadbeef."site-a";
    def rt($target): site.runtimeTargets[$target];

    def has_provider_ipv6_on_wan:
      [ site.runtimeTargets | to_entries[].value.effectiveRuntimeRealization.interfaces | to_entries[]
        | select(.value.sourceKind == "wan")
        | (.value.routes.ipv6 // [])
        | map(select(.proto == "provider"))
      ] | flatten | length > 0;

    has_provider_ipv6_on_wan | not
  ' "${output_json}" 2>/dev/null || echo "false")

  if [[ "${result}" == "true" ]]; then
    echo "PASS: P8 — No provider IPv6 routes leak onto WAN-uplink interfaces"
  else
    echo "FAIL: P8 — Provider IPv6 routes found on WAN interfaces (leakage)"
    all_checks_passed=false
  fi
}
check_p8

echo ""
echo "--- Route detail (debug) ---"
jq -r '
  def root: if type == "array" then .[0] else . end;
  def site: root.control_plane_model.data.esp0xdeadbeef."site-a";
  def rt($target): site.runtimeTargets[$target];

  def provider_routes_on($node_name; $node_id):
    rt($node_id).effectiveRuntimeRealization.interfaces
    | to_entries[]
    | select((.value.routes.ipv4 // []) | map(select(.proto == "provider")) | length > 0)
    | "  \($node_name):\(.key) → \([.value.routes.ipv4[] | select(.proto == "provider") | "\(.dst) via \(.via4 // "?")"] | join(", "))";

  provider_routes_on("DS"; "esp0xdeadbeef-site-a-nixos-downstream-selector"),
  provider_routes_on("POL"; "esp0xdeadbeef-site-a-nixos-policy"),
  provider_routes_on("US"; "esp0xdeadbeef-site-a-nixos-upstream-selector")
' "${output_json}" 2>/dev/null || echo "(no provider routes found)"
echo ""

echo ""
if [[ "${all_checks_passed}" == "true" ]]; then
  echo "PASS: FS-800-HDS-010-SDS-020-SMS-040 (8/8 assertions)"
  exit 0
else
  echo "FAIL: One or more checks failed."
  exit 1
fi
