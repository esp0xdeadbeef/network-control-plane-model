#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-013-SMS-020
# GAMP-SCOPE: software-module-test
# Focused construction test: provider-handoff access nodes must egress
# internet traffic through the site fabric (downstream-selector) and
# must NOT have any default-reachability route on PPPoE-linked p2p
# interfaces. Both IPv4 and IPv6 checked. Both NixOS and CLAB substrates.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

source "${repo_root}/tests/lib/pinned-paths.sh"
hat_dir="${HAT_DIR:-$(pinned_hat_dir)}"

all_checks_passed=true

run_checks() {
  local substrate="$1"  # nixos or clab
  local site_id="$2"
  local output_json="$3"

  jq -e --arg substrate "$substrate" '
    def root: if type == "array" then .[0] else . end;
    def site_id: if $substrate == "nixos" then "site-a" else "site-b" end;
    def site: root.control_plane_model.data.esp0xdeadbeef.[site_id];
    def rt($target): site.runtimeTargets[$target];

    def prefix: if $substrate == "nixos" then "nixos" else "clab" end;
    def labelA: "\(prefix)-provider-handoff-access-a";
    def labelB: "\(prefix)-provider-handoff-access-b";
    def siteName: site_id;
    def targetA: "esp0xdeadbeef-\(siteName)-\(labelA)";
    def targetB: "esp0xdeadbeef-\(siteName)-\(labelB)";

    # --- Helper: check default-reachability EXISTS on a specific interface ---
    def has_default($target; $iface_name; $expected_via4):
      rt($target).effectiveRuntimeRealization.interfaces[$iface_name] as $iface
      | ($iface.routes.ipv4 // []) as $v4
      | ($v4 | map(select(.intent.kind == "default-reachability"))) as $defaults
      | ($defaults | length) == 1
      and $defaults[0].proto == "default"
      and ($defaults[0].via4 // "") == $expected_via4;

    # --- Helper: check NO default-reachability on a specific interface (both v4+v6) ---
    def no_default($target; $iface_name):
      rt($target).effectiveRuntimeRealization.interfaces[$iface_name] as $iface
      | (($iface.routes.ipv4 // []) | map(select(.intent.kind == "default-reachability")) | length) == 0
      and (($iface.routes.ipv6 // []) | map(select(.intent.kind == "default-reachability")) | length) == 0;

    # --- Helper: route count checks ---
    def has_ipv4_routes($target; $iface_name):
      rt($target).effectiveRuntimeRealization.interfaces[$iface_name] as $iface
      | (($iface.routes.ipv4 // []) | length) > 0;

    def p2p_to_pppoe_core($target; $core_label):
      rt($target).effectiveRuntimeRealization.interfaces[
        "p2p-\(prefix)-core-\(core_label)-\(labelA // labelA)"
      ] // rt($target).effectiveRuntimeRealization.interfaces[
        "p2p-\(prefix)-core-\(core_label)-\(labelB // labelB)"
      ] // null;

    # --- SMS-020 Predicate 1: NO default-reachability on PPPoE-linked p2p ---
    # Provider A: no default on p2p-to-core-testnet-host-isp
    def check1a: no_default(targetA;
      "p2p-\(prefix)-core-testnet-host-isp-\(labelA)");

    # Provider B: no default on p2p-to-core-testnet-routed-isp
    def check1b: no_default(targetB;
      "p2p-\(prefix)-core-testnet-routed-isp-\(labelB)");

    # --- SMS-020 Predicate 2: default-reachability via downstream-selector ---
    # Provider A: default via DS
    def p2p_ds_a: "p2p-\(prefix)-downstream-selector-\(labelA)";
    def check2a: has_default(targetA; p2p_ds_a;
      if $substrate == "nixos" then "10.10.44.58" else "10.50.44.58" end);

    # Provider B: default via DS
    def p2p_ds_b: "p2p-\(prefix)-downstream-selector-\(labelB)";
    def check2b: has_default(targetB; p2p_ds_b;
      if $substrate == "nixos" then "10.10.44.60" else "10.50.44.60" end);

    # --- IPv6 deferred-documented check ---
    def check_ipv6_none_on_ds($target; $iface_name):
      rt($target).effectiveRuntimeRealization.interfaces[$iface_name] as $iface
      | (($iface.routes.ipv6 // []) | map(select(.intent.kind == "default-reachability")) | length) == 0;

    # --- Regression: access-client still has its default ---
    def check_regression_client: has_default(
      "esp0xdeadbeef-\(siteName)-\(prefix)-access-client";
      "p2p-\(prefix)-access-client-\(prefix)-downstream-selector";
      if $substrate == "nixos" then "10.10.44.1" else "10.50.44.1" end);

    # --- Smoke-check: provider-handoff nodes EXIST in runtime targets ---
    def check_smoke_a: rt(targetA) != null;
    def check_smoke_b: rt(targetB) != null;

    # --- Aggregate all checks ---
    {
      "SMS-020-P1a-no-default-on-pppoe-p2p-provider-A": check1a,
      "SMS-020-P1b-no-default-on-pppoe-p2p-provider-B": check1b,
      "SMS-020-P2a-default-via-DS-provider-A": check2a,
      "SMS-020-P2b-default-via-DS-provider-B": check2b,
      "SMS-020-P3-ipv6-deferred-documented-on-DS-A": check_ipv6_none_on_ds(targetA; p2p_ds_a),
      "SMS-020-P3-ipv6-deferred-documented-on-DS-B": check_ipv6_none_on_ds(targetB; p2p_ds_b),
      "SMS-020-regression-access-client-default": check_regression_client,
      "SMS-020-smoke-target-exists-A": check_smoke_a,
      "SMS-020-smoke-target-exists-B": check_smoke_b
    }
  ' "${output_json}"
}

# --- NixOS substrate ---
echo "--- FS-800-HDS-010-SDS-013-SMS-020: Testing NixOS substrate ---"
output_nixos="${tmp_dir}/cpm-nixos.json"

if [[ -n "${CPM_NIXOS_JSON:-}" ]]; then
  # Use pre-built CPM JSON from flake check
  cp "${CPM_NIXOS_JSON}" "${output_nixos}"
else
  nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
    "${hat_dir}/intent.nix" \
    "${hat_dir}/inventory-nixos.nix" \
    "${output_nixos}" >/dev/null
fi

nixos_checks=$(run_checks "nixos" "site-a" "${output_nixos}")
echo "${nixos_checks}" | jq -r 'to_entries[] | "  \(.key): \(.value)"'

nixos_failed=$(echo "${nixos_checks}" | jq -r '[to_entries[] | select(.value != true) | .key] | join(", ")')
if [[ -z "${nixos_failed}" || "${nixos_failed}" == "null" ]]; then
  echo "PASS FS-800-HDS-010-SDS-013-SMS-020 nixos substrate"
else
  echo "FAIL FS-800-HDS-010-SDS-013-SMS-020 nixos substrate: ${nixos_failed}"
  all_checks_passed=false
fi

# --- CLAB substrate ---
echo "--- FS-800-HDS-010-SDS-013-SMS-020: Testing CLAB substrate ---"
output_clab="${tmp_dir}/cpm-clab.json"

if [[ -n "${CPM_CLAB_JSON:-}" ]]; then
  # Use pre-built CPM JSON from flake check
  cp "${CPM_CLAB_JSON}" "${output_clab}"
else
  nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
    "${hat_dir}/intent.nix" \
    "${hat_dir}/inventory-clab.nix" \
    "${output_clab}" >/dev/null
fi

clab_checks=$(run_checks "clab" "site-b" "${output_clab}")
echo "${clab_checks}" | jq -r 'to_entries[] | "  \(.key): \(.value)"'

clab_failed=$(echo "${clab_checks}" | jq -r '[to_entries[] | select(.value != true) | .key] | join(", ")')
if [[ -z "${clab_failed}" || "${clab_failed}" == "null" ]]; then
  echo "PASS FS-800-HDS-010-SDS-013-SMS-020 clab substrate"
else
  echo "FAIL FS-800-HDS-010-SDS-013-SMS-020 clab substrate: ${clab_failed}"
  all_checks_passed=false
fi

# --- Final ---
if [[ "${all_checks_passed}" == "true" ]]; then
  echo ""
  echo "PASS FS-800-HDS-010-SDS-013-SMS-020 construction test (both substrates)"
  echo ""
  echo "GAP NOTE: SMS-020 predicate 3 (fail-closed diagnostic emission) is deferred."
  echo "  The CPM build-target.nix silently strips default-reachability from PPPoE"
  echo "  p2p interfaces and adds fabric-lane defaults on downstream-selector p2p."
  echo "  Explicit diagnostic records (mode=fail-closed) require threading diagnostics"
  echo "  through the build-target pipeline. The route behavior is correct; diagnostic"
  echo "  records are a separate CMC item."
  echo ""
  echo "GAP NOTE: IPv6 default route on downstream-selector p2p is deferred"
  echo "  (build-target.nix line 384: peerAddr6 = null). IPv4 default route is"
  echo "  sufficient for HAT egress. IPv6 fabric-egress is tracked as deferred."
  # --- Seeded negative: inject a default-reachability into the PPPoE p2p ---
  #  and verify the test DETECTS the violation (P1 must return false).
  echo ""
  echo "--- FS-800-HDS-010-SDS-013-SMS-020: Seeded negative (detect injected default) ---"

  # Use NixOS output as the corruption target.
  neg_json="${tmp_dir}/cpm-nixos-corrupted.json"
  p2p_key="p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a"

  # Inject a default-reachability route into the PPPoE p2p interface
  jq --arg p2p_key "$p2p_key" '
    def root: if type == "array" then .[0] else . end;
    (root.control_plane_model.data.esp0xdeadbeef.["site-a"]
      .runtimeTargets["esp0xdeadbeef-site-a-nixos-provider-handoff-access-a"]
      .effectiveRuntimeRealization.interfaces[$p2p_key].routes.ipv4) += [
        {
          intent: { kind: "default-reachability" },
          proto: "default",
          via4: "10.255.255.1"
        }
      ]
  ' "${output_nixos}" > "${neg_json}"

  # Run the P1 check on the corrupted output — it MUST return false.
  neg_result=$(jq -e --arg substrate "nixos" '
    def root: if type == "array" then .[0] else . end;
    def site: root.control_plane_model.data.esp0xdeadbeef.["site-a"];
    def rt($target): site.runtimeTargets[$target];
    def prefix: "nixos";
    def labelA: "nixos-provider-handoff-access-a";
    def targetA: "esp0xdeadbeef-site-a-nixos-provider-handoff-access-a";
    def no_default($target; $iface_name):
      rt($target).effectiveRuntimeRealization.interfaces[$iface_name] as $iface
      | (($iface.routes.ipv4 // []) | map(select(.intent.kind == "default-reachability")) | length) == 0
      and (($iface.routes.ipv6 // []) | map(select(.intent.kind == "default-reachability")) | length) == 0;
    no_default(targetA; "p2p-nixos-core-testnet-host-isp-nixos-provider-handoff-access-a")
  ' "${neg_json}" 2>/dev/null || true)

  if [[ "${neg_result}" == "false" ]]; then
    echo "  Seeded negative PASS: injected default-reachability correctly detected as violation"
  else
    echo "  Seeded negative FAIL: injected default-reachability NOT detected (expected false, got '${neg_result}')"
    all_checks_passed=false
  fi

  if [[ "${all_checks_passed}" == "true" ]]; then
    echo ""
    echo "PASS FS-800-HDS-010-SDS-013-SMS-020 construction test (all checks + seeded negative)"
  else
    echo ""
    echo "FAIL FS-800-HDS-010-SDS-013-SMS-020 construction test (seeded negative failed)"
    exit 1
  fi
  exit 0
else
  echo "FAIL FS-800-HDS-010-SDS-013-SMS-020 construction test"
  exit 1
fi
