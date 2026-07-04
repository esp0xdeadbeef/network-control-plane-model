#!/usr/bin/env bash
# GAMP-ID: FS-050-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
# Trace chain: FS-050 -> HDS-010 -> SDS-010 -> SMS-010 (protected inventory boundary)
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

trace_id="FS-050-HDS-010-SDS-010-SMS-010"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

contract_path="${repo_root}/src/cpm/secret-source-contract.nix"
helpers_path="${repo_root}/src/cpm/cpm-contract-support.nix"

eval_contract_attr() {
  local inventory_nix="$1"
  local attr="$2"
  local output_json="$3"

  nix eval --impure --json --expr "
    let
      lib = (import <nixpkgs> {}).lib;
      helpers = import ${helpers_path} { inherit lib; };
      contract = import ${contract_path} {
        inherit lib helpers;
        inventory = import ${inventory_nix};
        secretPlatformSubstrate = \"nixos\";
      };
    in
      contract.${attr}
  " >"${output_json}" 2>"${tmp_dir}/eval.stderr" || {
    echo "FAIL ${trace_id}: nix eval failed for ${attr}" >&2
    cat "${tmp_dir}/eval.stderr" >&2
    exit 1
  }
}

cat >"${tmp_dir}/clean.nix" <<'CLEAN'
{
  secretBasePath = "/run/secrets";
  secretDeclarations = [
    {
      id = "decl-renderer-api-key";
      credentialClass = "api-token";
      site = "site-a";
      tenant = null;
      host = "router-core";
      consumer = {
        kind = "module";
        node = "router-core";
        name = "renderer.module";
      };
      authorizedConsumerScope = [ "renderer.module" ];
      purpose = "renderer-api-key";
      lifecycle = "runtime";
      required = true;
      requiredness = "mandatory";
      material = "reference-only";
      plaintextMaterial = false;
    }
  ];
  secretSources = [
    {
      id = "source-renderer-api-key";
      declarationId = "decl-renderer-api-key";
      sourceClass = "protected-inventory";
      reference = {
        name = "renderer-api-key";
        runtimePath = "renderer-api-key";
      };
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      targetInventorySurface = "protected";
    }
  ];
  sourceBindings = [
    {
      id = "binding-renderer-api-key";
      declarationId = "decl-renderer-api-key";
      sourceId = "source-renderer-api-key";
      sourceClass = "protected-inventory";
      bindingKind = "declaration-source";
    }
  ];
}
CLEAN

eval_contract_attr "${tmp_dir}/clean.nix" "secretDeliveryRecords" "${tmp_dir}/clean-delivery.json"
eval_contract_attr "${tmp_dir}/clean.nix" "secretAuthorization" "${tmp_dir}/clean-auth.json"
eval_contract_attr "${tmp_dir}/clean.nix" "secretPlaintextGuard" "${tmp_dir}/clean-plaintext.json"
eval_contract_attr "${tmp_dir}/clean.nix" "secretPolicyBoundary" "${tmp_dir}/clean-policy.json"

jq -e '
  length == 1
  and .[0].deliveryId == "binding-renderer-api-key-delivery"
  and .[0].sourceClass == "protected-inventory"
  and .[0].secretReference == "/run/secrets/renderer-api-key"
' "${tmp_dir}/clean-delivery.json" >/dev/null || {
  echo "FAIL ${trace_id}: clean case did not emit redacted protected reference" >&2
  jq '.' "${tmp_dir}/clean-delivery.json" >&2
  exit 1
}

jq -e '
  .allAuthorized == true
  and (.authorizedConsumerDiagnostics | length) == 0
  and (.protectedConsumerScopeDiagnostics | length) == 0
' "${tmp_dir}/clean-auth.json" >/dev/null || {
  echo "FAIL ${trace_id}: clean case should be authorized" >&2
  jq '.' "${tmp_dir}/clean-auth.json" >&2
  exit 1
}

jq -e '.allPlaintextFree == true and (.plaintextSecretDiagnostics | length) == 0' "${tmp_dir}/clean-plaintext.json" >/dev/null || {
  echo "FAIL ${trace_id}: clean case should be plaintext-free" >&2
  jq '.' "${tmp_dir}/clean-plaintext.json" >&2
  exit 1
}

jq -e '.allPolicyNeutral == true and (.policyBoundaryDiagnostics | length) == 0 and (.trustBoundaryDiagnostics | length) == 0' "${tmp_dir}/clean-policy.json" >/dev/null || {
  echo "FAIL ${trace_id}: clean case should be policy-neutral" >&2
  jq '.' "${tmp_dir}/clean-policy.json" >&2
  exit 1
}

echo "PASS ${trace_id}: clean protected-inventory reference stays redacted and authorized"

cat >"${tmp_dir}/unauthorized-consumer.nix" <<'UNAUTHORIZED'
{
  secretDeclarations = [
    {
      id = "decl-renderer-only";
      credentialClass = "api-token";
      site = "site-a";
      tenant = null;
      host = "router-core";
      consumer = {
        kind = "module";
        node = "router-core";
        name = "public.diagnostics";
      };
      authorizedConsumerScope = [ "renderer.module" ];
      purpose = "diagnostics-request";
      lifecycle = "runtime";
      required = true;
      requiredness = "mandatory";
      material = "reference-only";
      plaintextMaterial = false;
    }
  ];
  secretSources = [
    {
      id = "source-renderer-only";
      declarationId = "decl-renderer-only";
      sourceClass = "protected-inventory";
      reference = {
        name = "renderer-only-secret";
        runtimePath = "renderer-only-secret";
      };
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      targetInventorySurface = "protected";
    }
  ];
  sourceBindings = [
    {
      id = "binding-renderer-only";
      declarationId = "decl-renderer-only";
      sourceId = "source-renderer-only";
      sourceClass = "protected-inventory";
      bindingKind = "declaration-source";
    }
  ];
}
UNAUTHORIZED

eval_contract_attr "${tmp_dir}/unauthorized-consumer.nix" "secretAuthorization" "${tmp_dir}/unauthorized-auth.json"

jq -e --arg trace "${trace_id}" '
  .allAuthorized == false
  and (.protectedConsumerScopeDiagnostics | length) == 1
  and .protectedConsumerScopeDiagnostics[0].diagnosticName == "PROTECTED_VALUE_UNAUTHORIZED_CONSUMER"
  and .protectedConsumerScopeDiagnostics[0].consumerName == "public.diagnostics"
  and .protectedConsumerScopeDiagnostics[0].protectedValueIdentity == "renderer-only-secret"
  and (.protectedConsumerScopeDiagnostics[0].authorizedConsumerScope | index("renderer.module")) != null
  and (.protectedConsumerScopeDiagnostics[0].gampIds | index($trace)) != null
' "${tmp_dir}/unauthorized-auth.json" >/dev/null || {
  echo "FAIL ${trace_id}: SN1 unauthorized consumer diagnostic missing or incomplete" >&2
  jq '.' "${tmp_dir}/unauthorized-auth.json" >&2
  exit 1
}

echo "PASS ${trace_id}: SN1 unauthorized public diagnostics consumer is rejected"

cat >"${tmp_dir}/plaintext-material.nix" <<'PLAINTEXT'
{
  secretDeclarations = [
    {
      id = "decl-public-surface";
      credentialClass = "api-token";
      site = "site-a";
      tenant = null;
      host = "router-core";
      consumer = {
        kind = "module";
        node = "router-core";
        name = "renderer.module";
      };
      authorizedConsumerScope = [ "renderer.module" ];
      purpose = "public-inventory-render";
      lifecycle = "runtime";
      required = true;
      requiredness = "mandatory";
      material = "reference-only";
      plaintextMaterial = false;
    }
  ];
  secretSources = [
    {
      id = "source-public-surface";
      declarationId = "decl-public-surface";
      sourceClass = "protected-inventory";
      reference = {
        name = "public-surface-secret";
        runtimePath = "public-surface-secret";
      };
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = true;
      targetInventorySurface = "public";
    }
  ];
  sourceBindings = [
    {
      id = "binding-public-surface";
      declarationId = "decl-public-surface";
      sourceId = "source-public-surface";
      sourceClass = "protected-inventory";
      bindingKind = "declaration-source";
    }
  ];
}
PLAINTEXT

eval_contract_attr "${tmp_dir}/plaintext-material.nix" "secretPlaintextGuard" "${tmp_dir}/plaintext-guard.json"

jq -e --arg trace "${trace_id}" '
  .allPlaintextFree == false
  and (.plaintextSecretDiagnostics | length) == 1
  and .plaintextSecretDiagnostics[0].diagnosticName == "PLAINTEXT_SECRET_IN_DELIVERY"
  and .plaintextSecretDiagnostics[0].declarationId == "decl-public-surface"
  and (.plaintextSecretDiagnostics[0].plaintextFields | index("plaintextMaterial")) != null
  and .plaintextSecretDiagnostics[0].targetInventorySurface == "public"
  and (.plaintextSecretDiagnostics[0].gampIds | index($trace)) != null
' "${tmp_dir}/plaintext-guard.json" >/dev/null || {
  echo "FAIL ${trace_id}: SN2 plaintextMaterial leak diagnostic missing or incomplete" >&2
  jq '.' "${tmp_dir}/plaintext-guard.json" >&2
  exit 1
}

echo "PASS ${trace_id}: SN2 plaintextMaterial leak to public inventory is rejected"

cat >"${tmp_dir}/policy-boundary.nix" <<'POLICY'
{
  secretDeclarations = [
    {
      id = "decl-policy";
      credentialClass = "api-token";
      site = "site-a";
      tenant = "tenant-a";
      host = "router-core";
      consumer = {
        kind = "module";
        node = "router-core";
        name = "renderer.module";
      };
      authorizedConsumerScope = [ "renderer.module" ];
      purpose = "policy-negative";
      lifecycle = "runtime";
      required = true;
      requiredness = "mandatory";
      material = "reference-only";
      plaintextMaterial = false;
    }
  ];
  secretSources = [
    {
      id = "source-policy";
      declarationId = "decl-policy";
      sourceClass = "protected-inventory";
      reference = {
        name = "policy-secret";
        runtimePath = "policy-secret";
      };
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
    }
  ];
  sourceBindings = [
    {
      id = "binding-policy";
      declarationId = "decl-policy";
      sourceId = "source-policy";
      sourceClass = "protected-inventory";
      bindingKind = "declaration-source";
      metadata = {
        allowDns = true;
        allowNat = true;
        allowPublicExposure = true;
        trustAnchor = {
          tenant = "tenant-a";
        };
      };
    }
  ];
}
POLICY

eval_contract_attr "${tmp_dir}/policy-boundary.nix" "secretPolicyBoundary" "${tmp_dir}/policy-boundary.json"

jq -e '
  .allPolicyNeutral == false
  and (.policyBoundaryDiagnostics | length) == 1
  and (.trustBoundaryDiagnostics | length) == 1
  and (.policyBoundaryDiagnostics[0].policyFields | index("allowDns")) != null
  and (.policyBoundaryDiagnostics[0].policyFields | index("allowNat")) != null
  and (.policyBoundaryDiagnostics[0].policyFields | index("allowPublicExposure")) != null
  and (.trustBoundaryDiagnostics[0].trustFields | index("trustAnchor")) != null
' "${tmp_dir}/policy-boundary.json" >/dev/null || {
  echo "FAIL ${trace_id}: protected inventory policy/trust boundary diagnostic missing" >&2
  jq '.' "${tmp_dir}/policy-boundary.json" >&2
  exit 1
}

echo "PASS ${trace_id}: protected inventory cannot create DNS/NAT/public exposure/trust policy"
echo "PASS ${trace_id} protected inventory boundary"
