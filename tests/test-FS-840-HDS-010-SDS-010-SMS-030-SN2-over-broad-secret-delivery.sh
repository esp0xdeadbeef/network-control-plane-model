#!/usr/bin/env bash
# GAMP-ID: FS-840-HDS-010-SDS-010-SMS-030-SN2
# GAMP-SCOPE: software-module-test
# Trace chain: FS-840 → HDS-010 → SDS-010 → SMS-030 SN2 (over-broad secret delivery guard)
# Wired into CPM test runner via tests/ directory glob: test-FS-840-*.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

# Direct Nix evaluation of secret-source-contract with synthetic inventories
# that test the overBroadDeliveryDiagnosticForRecord guard.
# Uses nix eval --impure --expr to construct minimal inventory fixtures.

nix_eval_contract() {
  local inventory_expr="$1"
  local attr="$2"

  nix eval --impure --json --expr "
    let
      flake = builtins.getFlake \"path:${repo_root}\";
      system = builtins.currentSystem;
      pkgs = import flake.inputs.nixpkgs { inherit system; };
      lib = pkgs.lib;
      helpers = import \"${repo_root}/src/cpm/cpm-contract-support.nix\" { inherit lib; };
      inventory = ${inventory_expr};
      contract = import \"${repo_root}/src/cpm/secret-source-contract.nix\" {
        inherit lib helpers inventory;
        secretPlatformSubstrate = \"test\";
      };
    in
    contract.secretAuthorization.${attr}
  "
}

# ── Positive case: no authorizedScope set → no over-broad diagnostic ─────────

no_scope_output="$(nix_eval_contract '
{
  secretDeclarations = [
    {
      id = "decl-no-scope";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = "tenant-a";
      host = "test-host";
      consumer = {
        kind = "service";
        node = "test-node";
        name = "consumer-name";
      };
      # authorizedScope intentionally omitted — should not trigger over-broad
      purpose = "no-scope-purpose";
      lifecycle = "hat-runtime";
      required = true;
      requiredness = "mandatory";
      material = "reference-only";
      plaintextMaterial = false;
      sourceSelected = false;
      policyAuthority = {
        createsRouteAuthority = false;
        createsFirewallPolicy = false;
        createsDnsPolicy = false;
        createsPublicIngress = false;
        createsTenantReachability = false;
        createsTrustBoundary = false;
        createsNetworkBehavior = false;
      };
      gampIds = [
        "FS-840-HDS-010-SDS-010"
        "FS-840-HDS-010-SDS-010-SMS-030"
      ];
    }
  ];
  secretSources = [
    {
      id = "source-no-scope";
      declarationId = "decl-no-scope";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "no-scope-secret";
        runtimePath = "no-scope-path";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-030" ];
    }
  ];
  sourceBindings = [
    {
      id = "binding-no-scope";
      declarationId = "decl-no-scope";
      sourceId = "source-no-scope";
      sourceClass = "deployment-platform-secret-reference";
      bindingKind = "declaration-source";
      policyAuthority = {
        createsRouteAuthority = false;
        createsFirewallPolicy = false;
        createsDnsPolicy = false;
        createsPublicIngress = false;
        createsTenantReachability = false;
        createsTrustBoundary = false;
        createsNetworkBehavior = false;
      };
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-030" ];
    }
  ];
}' "overBroadDeliveryDiagnostics")"

if [ "$(echo "$no_scope_output" | jq -r '. | length')" != "0" ]; then
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-030-SN2: no authorizedScope should produce no diagnostics" >&2
  echo "$no_scope_output" | jq . >&2
  exit 1
fi
echo "PASS FS-840-HDS-010-SDS-010-SMS-030-SN2: no authorizedScope → no over-broad diagnostics"

# ── Positive case: tenant in authorizedScope → no diagnostic ─────────────────

in_scope_output="$(nix_eval_contract '
{
  secretDeclarations = [
    {
      id = "decl-in-scope";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = "tenant-a";
      host = "test-host";
      consumer = {
        kind = "service";
        node = "test-node";
        name = "consumer-name";
      };
      authorizedScope = [ "tenant-a" ];  # tenant-a is in scope
      purpose = "in-scope-purpose";
      lifecycle = "hat-runtime";
      required = true;
      requiredness = "mandatory";
      material = "reference-only";
      plaintextMaterial = false;
      sourceSelected = false;
      policyAuthority = {
        createsRouteAuthority = false;
        createsFirewallPolicy = false;
        createsDnsPolicy = false;
        createsPublicIngress = false;
        createsTenantReachability = false;
        createsTrustBoundary = false;
        createsNetworkBehavior = false;
      };
      gampIds = [
        "FS-840-HDS-010-SDS-010"
        "FS-840-HDS-010-SDS-010-SMS-030"
      ];
    }
  ];
  secretSources = [
    {
      id = "source-in-scope";
      declarationId = "decl-in-scope";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "in-scope-secret";
        runtimePath = "in-scope-path";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-030" ];
    }
  ];
  sourceBindings = [
    {
      id = "binding-in-scope";
      declarationId = "decl-in-scope";
      sourceId = "source-in-scope";
      sourceClass = "deployment-platform-secret-reference";
      bindingKind = "declaration-source";
      policyAuthority = {
        createsRouteAuthority = false;
        createsFirewallPolicy = false;
        createsDnsPolicy = false;
        createsPublicIngress = false;
        createsTenantReachability = false;
        createsTrustBoundary = false;
        createsNetworkBehavior = false;
      };
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-030" ];
    }
  ];
}' "overBroadDeliveryDiagnostics")"

if [ "$(echo "$in_scope_output" | jq -r '. | length')" != "0" ]; then
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-030-SN2: tenant in authorizedScope should produce no diagnostics" >&2
  echo "$in_scope_output" | jq . >&2
  exit 1
fi
echo "PASS FS-840-HDS-010-SDS-010-SMS-030-SN2: tenant in authorizedScope → no over-broad diagnostic"

# ── Seeded negative: tenant not in authorizedScope → over-broad diagnostic ──

over_broad_output="$(nix_eval_contract '
{
  secretDeclarations = [
    {
      id = "decl-over-broad";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = "tenant-c";  # tenant-c is NOT in authorizedScope
      host = "site-router-01";
      consumer = {
        kind = "service";
        node = "test-node";
        name = "consumer-name";
      };
      authorizedScope = [ "tenant-a" ];  # only tenant-a is authorized
      purpose = "over-broad-purpose";
      lifecycle = "hat-runtime";
      required = true;
      requiredness = "mandatory";
      material = "reference-only";
      plaintextMaterial = false;
      sourceSelected = false;
      policyAuthority = {
        createsRouteAuthority = false;
        createsFirewallPolicy = false;
        createsDnsPolicy = false;
        createsPublicIngress = false;
        createsTenantReachability = false;
        createsTrustBoundary = false;
        createsNetworkBehavior = false;
      };
      gampIds = [
        "FS-840-HDS-010-SDS-010"
        "FS-840-HDS-010-SDS-010-SMS-030"
      ];
    }
  ];
  secretSources = [
    {
      id = "source-over-broad";
      declarationId = "decl-over-broad";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "over-broad-secret";
        runtimePath = "over-broad-path";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-030" ];
    }
  ];
  sourceBindings = [
    {
      id = "binding-over-broad";
      declarationId = "decl-over-broad";
      sourceId = "source-over-broad";
      sourceClass = "deployment-platform-secret-reference";
      bindingKind = "declaration-source";
      policyAuthority = {
        createsRouteAuthority = false;
        createsFirewallPolicy = false;
        createsDnsPolicy = false;
        createsPublicIngress = false;
        createsTenantReachability = false;
        createsTrustBoundary = false;
        createsNetworkBehavior = false;
      };
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-030" ];
    }
  ];
}' "overBroadDeliveryDiagnostics")"

jq -e '
  length == 1 and
  .[0].diagnosticName == "runtime-over-broad-secret-delivery" and
  .[0].deliveryId == "binding-over-broad-delivery" and
  (.[0].gampIds | index("FS-840-HDS-010-SDS-010-SMS-030")) != null and
  .[0].tenant == "tenant-c" and
  .[0].authorizedScope == ["tenant-a"]
' <<<"$over_broad_output" >/dev/null || {
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-030-SN2: over-broad delivery did not produce diagnostic" >&2
  echo "$over_broad_output" | jq . >&2
  exit 1
}

echo "PASS FS-840-HDS-010-SDS-010-SMS-030-SN2: over-broad delivery rejected with runtime-over-broad-secret-delivery"

# ── allAuthorized integration check ──────────────────────────────────────────

all_auth_output="$(nix_eval_contract '
{
  secretDeclarations = [
    {
      id = "decl-over-broad";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = "tenant-c";
      host = "site-router-01";
      consumer = {
        kind = "service";
        node = "test-node";
        name = "consumer-name";
      };
      authorizedScope = [ "tenant-a" ];
      purpose = "over-broad-purpose";
      lifecycle = "hat-runtime";
      required = true;
      requiredness = "mandatory";
      material = "reference-only";
      plaintextMaterial = false;
      sourceSelected = false;
      policyAuthority = {
        createsRouteAuthority = false;
        createsFirewallPolicy = false;
        createsDnsPolicy = false;
        createsPublicIngress = false;
        createsTenantReachability = false;
        createsTrustBoundary = false;
        createsNetworkBehavior = false;
      };
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-030" ];
    }
  ];
  secretSources = [
    {
      id = "source-over-broad";
      declarationId = "decl-over-broad";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "over-broad-secret";
        runtimePath = "over-broad-path";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-030" ];
    }
  ];
  sourceBindings = [
    {
      id = "binding-over-broad";
      declarationId = "decl-over-broad";
      sourceId = "source-over-broad";
      sourceClass = "deployment-platform-secret-reference";
      bindingKind = "declaration-source";
      policyAuthority = {
        createsRouteAuthority = false;
        createsFirewallPolicy = false;
        createsDnsPolicy = false;
        createsPublicIngress = false;
        createsTenantReachability = false;
        createsTrustBoundary = false;
        createsNetworkBehavior = false;
      };
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-030" ];
    }
  ];
}' "allAuthorized")"

if [ "$all_auth_output" != "false" ]; then
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-030-SN2: allAuthorized should be false when over-broad delivery exists" >&2
  echo "got: $all_auth_output" >&2
  exit 1
fi
echo "PASS FS-840-HDS-010-SDS-010-SMS-030-SN2: allAuthorized correctly false with over-broad delivery"

echo "PASS test-FS-840-HDS-010-SDS-010-SMS-030-SN2-over-broad-secret-delivery"
