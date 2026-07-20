#!/usr/bin/env bash
# GAMP-ID: FS-840-HDS-010-SDS-010-SMS-010-SN2
# GAMP-SCOPE: software-module-test
# Trace chain: FS-840 → HDS-010 → SDS-010 → SMS-010 SN2 (consumer role mismatch guard)
# Wired into CPM test runner via tests/ directory glob: test-FS-840-*.sh
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
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
# that test the consumerRoleMismatchDiagnosticForRecord guard.
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

# ── Positive case: consumer role absent → no mismatch diagnostic ──────────────

no_role_output="$(nix_eval_contract '
{
  secretDeclarations = [
    {
      id = "decl-no-role";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = null;
      host = "test-host";
      consumer = {
        kind = "service";
        node = "test-node";
        name = "consumer-name";
        # role intentionally omitted — should not trigger mismatch
      };
      purpose = "no-role-purpose";
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
        "FS-840-HDS-010-SDS-010-SMS-010"
      ];
    }
  ];
  secretSources = [
    {
      id = "source-no-role";
      declarationId = "decl-no-role";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "no-role-secret";
        runtimePath = "no-role-path";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-010" ];
    }
  ];
  sourceBindings = [
    {
      id = "binding-no-role";
      declarationId = "decl-no-role";
      sourceId = "source-no-role";
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
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-010" ];
    }
  ];
}' "consumerRoleMismatchDiagnostics")"

if [ "$(echo "$no_role_output" | jq -r '. | length')" != "0" ]; then
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-010-SN2: no consumer role should produce no mismatch diagnostics" >&2
  echo "$no_role_output" | jq . >&2
  exit 1
fi
echo "PASS FS-840-HDS-010-SDS-010-SMS-010-SN2: no consumer role → no mismatch diagnostics"

# ── Positive case: consumer role matches host role → no diagnostic ────────────

matching_output="$(nix_eval_contract '
{
  deployment = {
    hosts = {
      "test-host" = {
        role = "core";
      };
    };
  };
  secretDeclarations = [
    {
      id = "decl-matching";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = null;
      host = "test-host";
      consumer = {
        kind = "service";
        node = "test-node";
        name = "consumer-name";
        role = "core";  # matches host role
      };
      purpose = "matching-purpose";
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
        "FS-840-HDS-010-SDS-010-SMS-010"
      ];
    }
  ];
  secretSources = [
    {
      id = "source-matching";
      declarationId = "decl-matching";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "matching-secret";
        runtimePath = "matching-path";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-010" ];
    }
  ];
  sourceBindings = [
    {
      id = "binding-matching";
      declarationId = "decl-matching";
      sourceId = "source-matching";
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
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-010" ];
    }
  ];
}' "consumerRoleMismatchDiagnostics")"

if [ "$(echo "$matching_output" | jq -r '. | length')" != "0" ]; then
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-010-SN2: matching role should produce no mismatch diagnostics" >&2
  echo "$matching_output" | jq . >&2
  exit 1
fi
echo "PASS FS-840-HDS-010-SDS-010-SMS-010-SN2: matching consumer/host role → no mismatch diagnostic"

# ── Seeded negative: consumer role != host role → mismatch diagnostic ──────────

mismatch_output="$(nix_eval_contract '
{
  deployment = {
    hosts = {
      "test-host" = {
        role = "core";
      };
    };
  };
  secretDeclarations = [
    {
      id = "decl-mismatch";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = null;
      host = "test-host";
      consumer = {
        kind = "service";
        node = "test-node";
        name = "consumer-name";
        role = "access";  # mismatched — host role is "core"
      };
      purpose = "mismatch-purpose";
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
        "FS-840-HDS-010-SDS-010-SMS-010"
      ];
    }
  ];
  secretSources = [
    {
      id = "source-mismatch";
      declarationId = "decl-mismatch";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "mismatch-secret";
        runtimePath = "mismatch-path";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-010" ];
    }
  ];
  sourceBindings = [
    {
      id = "binding-mismatch";
      declarationId = "decl-mismatch";
      sourceId = "source-mismatch";
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
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-010" ];
    }
  ];
}' "consumerRoleMismatchDiagnostics")"

jq -e '
  length == 1 and
  .[0].diagnosticName == "runtime-consumer-role-mismatch" and
  .[0].deliveryId == "binding-mismatch-delivery" and
  (.[0].gampIds | index("FS-840-HDS-010-SDS-010-SMS-010")) != null and
  .[0].consumerRole == "access" and
  .[0].hostRole == "core"
' <<<"$mismatch_output" >/dev/null || {
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-010-SN2: consumer role mismatch did not produce diagnostic" >&2
  echo "$mismatch_output" | jq . >&2
  exit 1
}

echo "PASS FS-840-HDS-010-SDS-010-SMS-010-SN2: consumer role mismatch rejected with runtime-consumer-role-mismatch"

# ── allAuthorized integration check ──────────────────────────────────────────

all_auth_output="$(nix_eval_contract '
{
  deployment = {
    hosts = {
      "test-host" = {
        role = "core";
      };
    };
  };
  secretDeclarations = [
    {
      id = "decl-mismatch";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = null;
      host = "test-host";
      consumer = {
        kind = "service";
        node = "test-node";
        name = "consumer-name";
        role = "access";  # mismatched
      };
      purpose = "mismatch-purpose";
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
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-010" ];
    }
  ];
  secretSources = [
    {
      id = "source-mismatch";
      declarationId = "decl-mismatch";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "mismatch-secret";
        runtimePath = "mismatch-path";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-010" ];
    }
  ];
  sourceBindings = [
    {
      id = "binding-mismatch";
      declarationId = "decl-mismatch";
      sourceId = "source-mismatch";
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
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-010" ];
    }
  ];
}' "allAuthorized")"

if [ "$all_auth_output" != "false" ]; then
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-010-SN2: allAuthorized should be false when role mismatch exists" >&2
  echo "got: $all_auth_output" >&2
  exit 1
fi
echo "PASS FS-840-HDS-010-SDS-010-SMS-010-SN2: allAuthorized correctly false with role mismatch"

echo "PASS test-FS-840-HDS-010-SDS-010-SMS-010-SN2-consumer-role-mismatch"
