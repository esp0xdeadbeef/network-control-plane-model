#!/usr/bin/env bash
# GAMP-ID: FS-820-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
# Trace chain: FS-820 → HDS-010 → SDS-010 → SMS-030 (secret source policy boundary)
# SN1: policy-field classification (POLICY_BEARING_SOURCE_BINDING)
# SN2: trust-boundary classification (TRUST_BOUNDARY_SOURCE_BINDING)
# Wired into CPM test runner via tests/ directory glob: test-fs820-*.sh
#
# Standalone test: directly evaluates secret-source-contract.nix with
# controlled test inventories, avoiding dependencies on the full CPM
# pipeline or HAT inventory state.
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

contract_path="${repo_root}/src/cpm/secret-source-contract.nix"

helpers_path="${repo_root}/src/cpm/cpm-contract-support.nix"

# Build a standalone evaluator that imports the secret-source-contract
# module with a given inventory and dumps the secretPolicyBoundary to JSON.
evaluate_policy_boundary() {
  local inventory_nix="$1"
  local output_json="$2"

  if ! nix eval --impure --json --expr "
    let
      contract = import ${contract_path} {
        lib = (import <nixpkgs> {}).lib;
        helpers = import ${helpers_path} { lib = (import <nixpkgs> {}).lib; };
        inventory = import ${inventory_nix};
        secretPlatformSubstrate = \"nixos\";
      };
    in
    contract.secretPolicyBoundary
  " > "${output_json}" 2>"${tmp_dir}/eval.stderr"; then
    echo "FAIL: nix eval failed" >&2
    cat "${tmp_dir}/eval.stderr" >&2
    exit 1
  fi
}

# ── Test 1: Happy path — binding without metadata → allPolicyNeutral=true ────

cat > "${tmp_dir}/neutral-inventory.nix" <<'NEUTRAL'
{
  secretDeclarations = [
    {
      id = "decl-neutral";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = null;
      host = "neutral-host";
      consumer = {
        kind = "service";
        node = "neutral-node";
        name = "neutral.service";
      };
      purpose = "neutral-purpose";
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
    }
  ];
  secretSources = [
    {
      id = "source-neutral";
      declarationId = "decl-neutral";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "neutral-secret";
        runtimePath = "neutral-secret-path";
        sourceFieldPath = "deployment.hosts.neutral-host.credentials.usernameFile";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
    }
  ];
  sourceBindings = [
    {
      id = "binding-neutral";
      declarationId = "decl-neutral";
      sourceId = "source-neutral";
      sourceClass = "deployment-platform-secret-reference";
      bindingKind = "declaration-source";
      sourceFieldPath = "deployment.hosts.neutral-host.credentials.usernameFile";
    }
  ];
}
NEUTRAL

evaluate_policy_boundary "${tmp_dir}/neutral-inventory.nix" "${tmp_dir}/neutral.json"

jq -e '
  .allPolicyNeutral == true
    and (.policyBoundaryDiagnostics | length) == 0
    and (.trustBoundaryDiagnostics | length) == 0
' "${tmp_dir}/neutral.json" >/dev/null || {
  echo "FAIL FS-820-HDS-010-SDS-010-SMS-030: happy path — expected allPolicyNeutral=true" >&2
  jq '.' "${tmp_dir}/neutral.json" >&2
  exit 1
}

echo "PASS FS-820-HDS-010-SDS-010-SMS-030: happy path — policy-neutral binding accepted"

# ── Test 2: SN1 — policy injection via metadata.allowRoute ────────────────────

cat > "${tmp_dir}/route-inventory.nix" <<'ROUTE_INJECT'
{
  secretDeclarations = [
    {
      id = "decl-route-injected";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = null;
      host = "route-injected-host";
      consumer = {
        kind = "service";
        node = "route-injected-node";
        name = "pppoe.client";
      };
      purpose = "pppoe-username";
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
    }
  ];
  secretSources = [
    {
      id = "source-route-injected";
      declarationId = "decl-route-injected";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "route-injected-secret";
        runtimePath = "route-injected-secret-path";
        sourceFieldPath = "deployment.hosts.route-injected-host.credentials.usernameFile";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
    }
  ];
  sourceBindings = [
    {
      id = "binding-route-injected";
      declarationId = "decl-route-injected";
      sourceId = "source-route-injected";
      sourceClass = "deployment-platform-secret-reference";
      bindingKind = "declaration-source";
      sourceFieldPath = "deployment.hosts.route-injected-host.credentials.usernameFile";
      metadata = {
        allowRoute = {
          destination = "10.99.99.0/24";
          interface = "pppoe-wan0";
        };
      };
    }
  ];
}
ROUTE_INJECT

evaluate_policy_boundary "${tmp_dir}/route-inventory.nix" "${tmp_dir}/route.json"

jq -e '
  .allPolicyNeutral == false
    and (.policyBoundaryDiagnostics | length) == 1
    and .policyBoundaryDiagnostics[0].diagnosticName == "POLICY_BEARING_SOURCE_BINDING"
    and .policyBoundaryDiagnostics[0].bindingId == "binding-route-injected"
    and .policyBoundaryDiagnostics[0].declarationId == "decl-route-injected"
    and (.policyBoundaryDiagnostics[0].policyFields | index("allowRoute")) != null
    and (.policyBoundaryDiagnostics[0].diagnostic | contains("allowRoute"))
    and (.policyBoundaryDiagnostics[0].diagnostic | contains("FS-820-HDS-010-SDS-010-SMS-030"))
    and (.policyBoundaryDiagnostics[0].gampIds | index("FS-820-HDS-010-SDS-010-SMS-030")) != null
    and (.trustBoundaryDiagnostics | length) == 0
' "${tmp_dir}/route.json" >/dev/null || {
  echo "FAIL FS-820-HDS-010-SDS-010-SMS-030 SN1: route policy injection not properly diagnosed" >&2
  jq '.' "${tmp_dir}/route.json" >&2
  exit 1
}

echo "PASS FS-820-HDS-010-SDS-010-SMS-030 SN1: route policy injection rejected with POLICY_BEARING_SOURCE_BINDING"

# ── Test 3: SN2 — trust boundary injection via metadata.trustAnchor ────────────

cat > "${tmp_dir}/trust-inventory.nix" <<'TRUST_INJECT'
{
  secretDeclarations = [
    {
      id = "decl-trust-injected";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = null;
      host = "trust-injected-host";
      consumer = {
        kind = "service";
        node = "trust-injected-node";
        name = "pppoe.client";
      };
      purpose = "pppoe-username";
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
    }
  ];
  secretSources = [
    {
      id = "source-trust-injected";
      declarationId = "decl-trust-injected";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "trust-injected-secret";
        runtimePath = "trust-injected-secret-path";
        sourceFieldPath = "deployment.hosts.trust-injected-host.credentials.usernameFile";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
    }
  ];
  sourceBindings = [
    {
      id = "binding-trust-injected";
      declarationId = "decl-trust-injected";
      sourceId = "source-trust-injected";
      sourceClass = "deployment-platform-secret-reference";
      bindingKind = "declaration-source";
      sourceFieldPath = "deployment.hosts.trust-injected-host.credentials.usernameFile";
      metadata = {
        trustAnchor = {
          tenant = "unrelated-tenant-b";
          scope = "cross-site";
        };
      };
    }
  ];
}
TRUST_INJECT

evaluate_policy_boundary "${tmp_dir}/trust-inventory.nix" "${tmp_dir}/trust.json"

jq -e '
  .allPolicyNeutral == false
    and (.trustBoundaryDiagnostics | length) == 1
    and .trustBoundaryDiagnostics[0].diagnosticName == "TRUST_BOUNDARY_SOURCE_BINDING"
    and .trustBoundaryDiagnostics[0].bindingId == "binding-trust-injected"
    and .trustBoundaryDiagnostics[0].declarationId == "decl-trust-injected"
    and (.trustBoundaryDiagnostics[0].trustFields | index("trustAnchor")) != null
    and .trustBoundaryDiagnostics[0].affectedTenant == "unrelated-tenant-b"
    and (.trustBoundaryDiagnostics[0].diagnostic | contains("trustAnchor"))
    and (.trustBoundaryDiagnostics[0].diagnostic | contains("unrelated-tenant-b"))
    and (.trustBoundaryDiagnostics[0].diagnostic | contains("FS-820-HDS-010-SDS-010-SMS-030"))
    and (.trustBoundaryDiagnostics[0].gampIds | index("FS-820-HDS-010-SDS-010-SMS-030")) != null
    and (.policyBoundaryDiagnostics | length) == 0
' "${tmp_dir}/trust.json" >/dev/null || {
  echo "FAIL FS-820-HDS-010-SDS-010-SMS-030 SN2: trust boundary injection not properly diagnosed" >&2
  jq '.' "${tmp_dir}/trust.json" >&2
  exit 1
}

echo "PASS FS-820-HDS-010-SDS-010-SMS-030 SN2: trust boundary injection rejected with TRUST_BOUNDARY_SOURCE_BINDING"

# ── Test 4: Prove policy-bearing bindings are filtered from delivery records ──

# Build the full CPM with neutral inventory to verify delivery records still work
cat > "${tmp_dir}/delivery-inventory.nix" <<'DELIVERY_NEUTRAL'
{
  secretDeclarations = [
    {
      id = "decl-delivery";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = null;
      host = "delivery-host";
      consumer = {
        kind = "service";
        node = "delivery-node";
        name = "delivery.service";
      };
      purpose = "delivery-purpose";
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
    }
  ];
  secretSources = [
    {
      id = "source-delivery";
      declarationId = "decl-delivery";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "delivery-secret";
        runtimePath = "delivery-secret-path";
        sourceFieldPath = "deployment.hosts.delivery-host.credentials.usernameFile";
      };
      lifecycle = "hat-runtime";
      materialAccess = "supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
    }
  ];
  sourceBindings = [
    {
      id = "binding-delivery";
      declarationId = "decl-delivery";
      sourceId = "source-delivery";
      sourceClass = "deployment-platform-secret-reference";
      bindingKind = "declaration-source";
      sourceFieldPath = "deployment.hosts.delivery-host.credentials.usernameFile";
      # No metadata → policy-neutral
    }
  ];
}
DELIVERY_NEUTRAL

if ! nix eval --impure --json --expr "
  let
    contract = import ${contract_path} {
      lib = (import <nixpkgs> {}).lib;
      helpers = import ${helpers_path} { lib = (import <nixpkgs> {}).lib; };
      inventory = import ${tmp_dir}/delivery-inventory.nix;
      secretPlatformSubstrate = \"nixos\";
    };
  in
  {
    deliveryCount = builtins.length contract.secretDeliveryRecords;
    deliveryId = (builtins.head contract.secretDeliveryRecords).deliveryId;
    allPolicyNeutral = contract.secretPolicyBoundary.allPolicyNeutral;
  }
" > "${tmp_dir}/delivery.json" 2>"${tmp_dir}/eval2.stderr"; then
  echo "FAIL: nix eval (delivery) failed" >&2
  cat "${tmp_dir}/eval2.stderr" >&2
  exit 1
fi

jq -e '
  .deliveryCount == 1
    and .deliveryId == "binding-delivery-delivery"
    and .allPolicyNeutral == true
' "${tmp_dir}/delivery.json" >/dev/null || {
  echo "FAIL FS-820-HDS-010-SDS-010-SMS-030: delivery records broken for policy-neutral bindings" >&2
  jq '.' "${tmp_dir}/delivery.json" >&2
  exit 1
}

echo "PASS FS-820-HDS-010-SDS-010-SMS-030: policy-neutral binding delivered to downstream"

# ── Test 5: Policy-bearing binding excluded from delivery records ─────────────

cat > "${tmp_dir}/excluded-inventory.nix" <<'EXCLUDED'
{
  secretDeclarations = [
    {
      id = "decl-excluded";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = null;
      host = "excluded-host";
      consumer = {
        kind = "service";
        node = "excluded-node";
        name = "excluded.service";
      };
      purpose = "excluded-purpose";
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
    }
  ];
  secretSources = [
    {
      id = "source-excluded";
      declarationId = "decl-excluded";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "excluded-secret";
        runtimePath = "excluded-secret-path";
        sourceFieldPath = "deployment.hosts.excluded-host.credentials.usernameFile";
      };
      lifecycle = "hat-runtime";
      materialAccess = "supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
    }
  ];
  sourceBindings = [
    {
      id = "binding-excluded";
      declarationId = "decl-excluded";
      sourceId = "source-excluded";
      sourceClass = "deployment-platform-secret-reference";
      bindingKind = "declaration-source";
      sourceFieldPath = "deployment.hosts.excluded-host.credentials.usernameFile";
      metadata = {
        allowFirewall = {
          direction = "ingress";
          port = 8443;
        };
      };
    }
  ];
}
EXCLUDED

if ! nix eval --impure --json --expr "
  let
    contract = import ${contract_path} {
      lib = (import <nixpkgs> {}).lib;
      helpers = import ${helpers_path} { lib = (import <nixpkgs> {}).lib; };
      inventory = import ${tmp_dir}/excluded-inventory.nix;
      secretPlatformSubstrate = \"nixos\";
    };
  in
  {
    deliveryCount = builtins.length contract.secretDeliveryRecords;
    allPolicyNeutral = contract.secretPolicyBoundary.allPolicyNeutral;
    diagCount = builtins.length contract.secretPolicyBoundary.policyBoundaryDiagnostics;
    diagName = (builtins.head contract.secretPolicyBoundary.policyBoundaryDiagnostics).diagnosticName;
    bindingCount = builtins.length contract.sourceBindings;
  }
" > "${tmp_dir}/excluded.json" 2>"${tmp_dir}/eval3.stderr"; then
  echo "FAIL: nix eval (excluded) failed" >&2
  cat "${tmp_dir}/eval3.stderr" >&2
  exit 1
fi

jq -e '
  .deliveryCount == 0
    and .allPolicyNeutral == false
    and .diagCount == 1
    and .diagName == "POLICY_BEARING_SOURCE_BINDING"
    and .bindingCount == 1
' "${tmp_dir}/excluded.json" >/dev/null || {
  echo "FAIL FS-820-HDS-010-SDS-010-SMS-030: policy-bearing binding should be excluded from delivery records" >&2
  jq '.' "${tmp_dir}/excluded.json" >&2
  exit 1
}

echo "PASS FS-820-HDS-010-SDS-010-SMS-030: policy-bearing binding excluded from delivery records but preserved in sourceBindings"

echo "PASS test-fs820-hds010-sds010-sms030-secret-source-policy-boundary"
