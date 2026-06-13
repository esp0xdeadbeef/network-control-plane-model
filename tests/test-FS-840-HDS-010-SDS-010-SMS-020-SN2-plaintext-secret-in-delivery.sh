#!/usr/bin/env bash
# GAMP-ID: FS-840-HDS-010-SDS-010-SMS-020-SN2
# GAMP-SCOPE: software-module-test
# Trace chain: FS-840 → HDS-010 → SDS-010 → SMS-020 SN2 (plaintext secret in delivery guard)
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
# that test the plaintextSecretDiagnosticForRecord guard.

nix_eval_plaintext_guard() {
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
    contract.secretPlaintextGuard.${attr}
  "
}

# ── Positive case: clean source (no plaintext fields) → no diagnostics ───────

clean_output="$(nix_eval_plaintext_guard '
{
  secretDeclarations = [
    {
      id = "decl-clean-020";
      credentialClass = "pppoe-credential";
      site = "nixos";
      tenant = "tenant-a";
      host = "test-host";
      consumer = {
        kind = "service";
        node = "test-node";
        name = "pppoe.client";
      };
      purpose = "pppoe-credentials";
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
        "FS-840-HDS-010-SDS-010-SMS-020"
      ];
    }
  ];
  secretSources = [
    {
      id = "source-clean-020";
      declarationId = "decl-clean-020";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "clean-secret-020";
        runtimePath = "pppoe-credentials";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
  sourceBindings = [
    {
      id = "binding-clean-020";
      declarationId = "decl-clean-020";
      sourceId = "source-clean-020";
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
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
}' "plaintextSecretDiagnostics")"

if [ "$(echo "$clean_output" | jq -r '. | length')" != "0" ]; then
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-020-SN2: clean source should produce no diagnostics" >&2
  echo "$clean_output" | jq . >&2
  exit 1
fi
echo "PASS FS-840-HDS-010-SDS-010-SMS-020-SN2: clean source → no plaintext diagnostics"

# ── Positive: allPlaintextFree is true when clean ────────────────────────────

clean_free="$(nix_eval_plaintext_guard '
{
  secretDeclarations = [
    {
      id = "decl-clean-020b";
      credentialClass = "pppoe-credential";
      site = "nixos";
      tenant = "tenant-a";
      host = "test-host";
      consumer = {
        kind = "service";
        node = "test-node";
        name = "pppoe.client";
      };
      purpose = "pppoe-credentials";
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
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
  secretSources = [
    {
      id = "source-clean-020b";
      declarationId = "decl-clean-020b";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "clean-secret-020b";
        runtimePath = "pppoe-credentials";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
  sourceBindings = [
    {
      id = "binding-clean-020b";
      declarationId = "decl-clean-020b";
      sourceId = "source-clean-020b";
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
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
}' "allPlaintextFree")"

if [ "$clean_free" != "true" ]; then
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-020-SN2: allPlaintextFree should be true when clean" >&2
  echo "got: $clean_free" >&2
  exit 1
fi
echo "PASS FS-840-HDS-010-SDS-010-SMS-020-SN2: allPlaintextFree true with clean source"

# ── Seeded negative: source with privateKey (plaintext WG key) → PLAINTEXT_SECRET_IN_DELIVERY

wg_key_output="$(nix_eval_plaintext_guard '
{
  secretDeclarations = [
    {
      id = "decl-wg-key-020";
      credentialClass = "wireguard-private-key";
      site = "nixos";
      tenant = "tenant-a";
      host = "site-router-01";
      consumer = {
        kind = "service";
        node = "wg-node";
        name = "wireguard.client";
      };
      purpose = "wireguard-key";
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
        "FS-840-HDS-010-SDS-010-SMS-020"
      ];
    }
  ];
  secretSources = [
    {
      id = "source-wg-key-020";
      declarationId = "decl-wg-key-020";
      sourceClass = "wireguard-private-key";
      reference = {
        name = "wg-key";
        runtimePath = "wireguard-private-key";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      # Seeded plaintext value — this should trigger PLAINTEXT_SECRET_IN_DELIVERY
      privateKey = "ABCDEF1234567890abcdef1234567890abcdef12345678";
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
  sourceBindings = [
    {
      id = "binding-wg-key-020";
      declarationId = "decl-wg-key-020";
      sourceId = "source-wg-key-020";
      sourceClass = "wireguard-private-key";
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
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
}' "plaintextSecretDiagnostics")"

jq -e '
  length == 1 and
  .[0].diagnosticName == "PLAINTEXT_SECRET_IN_DELIVERY" and
  .[0].deliveryId == "binding-wg-key-020-delivery" and
  .[0].credentialClass == "wireguard-private-key" and
  (.[0].plaintextFields | length) == 1 and
  .[0].plaintextFields[0] == "privateKey" and
  (.[0].gampIds | index("FS-840-HDS-010-SDS-010-SMS-020")) != null and
  (.[0].diagnostic | startswith("FS-840-HDS-010-SDS-010-SMS-020 SN2"))
' <<<"$wg_key_output" >/dev/null || {
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-020-SN2: plaintext privateKey did not produce diagnostic" >&2
  echo "$wg_key_output" | jq . >&2
  exit 1
}
echo "PASS FS-840-HDS-010-SDS-010-SMS-020-SN2: plaintext privateKey rejected with PLAINTEXT_SECRET_IN_DELIVERY"

# ── allPlaintextFree is false when plaintext exists ───────────────────────────

wg_key_free="$(nix_eval_plaintext_guard '
{
  secretDeclarations = [
    {
      id = "decl-wg-key-020b";
      credentialClass = "wireguard-private-key";
      site = "nixos";
      tenant = "tenant-a";
      host = "site-router-01";
      consumer = {
        kind = "service";
        node = "wg-node";
        name = "wireguard.client";
      };
      purpose = "wireguard-key";
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
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
  secretSources = [
    {
      id = "source-wg-key-020b";
      declarationId = "decl-wg-key-020b";
      sourceClass = "wireguard-private-key";
      reference = {
        name = "wg-key-b";
        runtimePath = "wireguard-private-key";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      privateKey = "ABCDEF1234567890abcdef1234567890abcdef12345678";
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
  sourceBindings = [
    {
      id = "binding-wg-key-020b";
      declarationId = "decl-wg-key-020b";
      sourceId = "source-wg-key-020b";
      sourceClass = "wireguard-private-key";
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
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
}' "allPlaintextFree")"

if [ "$wg_key_free" != "false" ]; then
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-020-SN2: allPlaintextFree should be false with plaintext WG key" >&2
  echo "got: $wg_key_free" >&2
  exit 1
fi
echo "PASS FS-840-HDS-010-SDS-010-SMS-020-SN2: allPlaintextFree false with plaintext privateKey"

# ── Seeded negative: source with psk (plaintext pre-shared key) ──────────────

psk_output="$(nix_eval_plaintext_guard '
{
  secretDeclarations = [
    {
      id = "decl-wg-psk-020";
      credentialClass = "wireguard-preshared-key";
      site = "nixos";
      tenant = "tenant-a";
      host = "site-router-01";
      consumer = {
        kind = "service";
        node = "wg-node";
        name = "wireguard.client";
      };
      purpose = "wireguard-psk";
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
        "FS-840-HDS-010-SDS-010-SMS-020"
      ];
    }
  ];
  secretSources = [
    {
      id = "source-wg-psk-020";
      declarationId = "decl-wg-psk-020";
      sourceClass = "wireguard-preshared-key";
      reference = {
        name = "wg-psk";
        runtimePath = "wireguard-preshared-key";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      # Seeded plaintext PSK value
      psk = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
  sourceBindings = [
    {
      id = "binding-wg-psk-020";
      declarationId = "decl-wg-psk-020";
      sourceId = "source-wg-psk-020";
      sourceClass = "wireguard-preshared-key";
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
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
}' "plaintextSecretDiagnostics")"

jq -e '
  length == 1 and
  .[0].diagnosticName == "PLAINTEXT_SECRET_IN_DELIVERY" and
  .[0].deliveryId == "binding-wg-psk-020-delivery" and
  .[0].credentialClass == "wireguard-preshared-key" and
  (.[0].plaintextFields | length) == 1 and
  .[0].plaintextFields[0] == "psk" and
  (.[0].gampIds | index("FS-840-HDS-010-SDS-010-SMS-020")) != null
' <<<"$psk_output" >/dev/null || {
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-020-SN2: plaintext psk did not produce diagnostic" >&2
  echo "$psk_output" | jq . >&2
  exit 1
}
echo "PASS FS-840-HDS-010-SDS-010-SMS-020-SN2: plaintext psk rejected with PLAINTEXT_SECRET_IN_DELIVERY"

# ── Ensure delivery record still has secretReference (path) ───────────────────

delivery_output="$(nix_eval_plaintext_guard '
{
  secretDeclarations = [
    {
      id = "decl-ref-check-020";
      credentialClass = "pppoe-credential";
      site = "nixos";
      tenant = "tenant-a";
      host = "test-host";
      consumer = {
        kind = "service";
        node = "test-node";
        name = "pppoe.client";
      };
      purpose = "pppoe-credentials";
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
        "FS-840-HDS-010-SDS-010-SMS-020"
      ];
    }
  ];
  secretSources = [
    {
      id = "source-ref-check-020";
      declarationId = "decl-ref-check-020";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "ref-check-secret";
        runtimePath = "pppoe-credentials";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
  sourceBindings = [
    {
      id = "binding-ref-check-020";
      declarationId = "decl-ref-check-020";
      sourceId = "source-ref-check-020";
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
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
}' "plaintextSecretDiagnostics")"

# Need to inspect delivery record directly for secretReference field
delivery_records_json="$(nix eval --impure --json --expr "
  let
    flake = builtins.getFlake \"path:${repo_root}\";
    system = builtins.currentSystem;
    pkgs = import flake.inputs.nixpkgs { inherit system; };
    lib = pkgs.lib;
    helpers = import \"${repo_root}/src/cpm/cpm-contract-support.nix\" { inherit lib; };
    inventory = {
      secretBasePath = \"/run/secrets\";
      secretDeclarations = [
        {
          id = \"decl-ref-check-020\";
          credentialClass = \"pppoe-credential\";
          site = \"nixos\";
          tenant = \"tenant-a\";
          host = \"test-host\";
          consumer = {
            kind = \"service\";
            node = \"test-node\";
            name = \"pppoe.client\";
          };
          purpose = \"pppoe-credentials\";
          lifecycle = \"hat-runtime\";
          required = true;
          requiredness = \"mandatory\";
          material = \"reference-only\";
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
          gampIds = [ \"FS-840-HDS-010-SDS-010-SMS-020\" ];
        }
      ];
      secretSources = [
        {
          id = \"source-ref-check-020\";
          declarationId = \"decl-ref-check-020\";
          sourceClass = \"deployment-platform-secret-reference\";
          reference = {
            name = \"ref-check-secret\";
            runtimePath = \"pppoe-credentials\";
          };
          lifecycle = \"hat-runtime\";
          materialAccess = \"not-supplied-by-source-record\";
          plaintextMaterial = false;
          providerNeutral = true;
          fixedSecretManagerRequired = false;
          gampIds = [ \"FS-840-HDS-010-SDS-010-SMS-020\" ];
        }
      ];
      sourceBindings = [
        {
          id = \"binding-ref-check-020\";
          declarationId = \"decl-ref-check-020\";
          sourceId = \"source-ref-check-020\";
          sourceClass = \"deployment-platform-secret-reference\";
          bindingKind = \"declaration-source\";
          policyAuthority = {
            createsRouteAuthority = false;
            createsFirewallPolicy = false;
            createsDnsPolicy = false;
            createsPublicIngress = false;
            createsTenantReachability = false;
            createsTrustBoundary = false;
            createsNetworkBehavior = false;
          };
          gampIds = [ \"FS-840-HDS-010-SDS-010-SMS-020\" ];
        }
      ];
    };
    contract = import \"${repo_root}/src/cpm/secret-source-contract.nix\" {
      inherit lib helpers inventory;
      secretPlatformSubstrate = \"test\";
    };
    dr = builtins.elemAt contract.secretDeliveryRecords 0;
  in
  {
    deliveryId = dr.deliveryId or null;
    mediatedPath = dr.mediatedPath or null;
    secretReference = dr.secretReference or null;
  }
")"

echo "$delivery_records_json" > "${tmp_dir}/delivery-record.json"

jq -e '
  .deliveryId == "binding-ref-check-020-delivery" and
  .mediatedPath == "/run/secrets/pppoe-credentials" and
  .secretReference == "/run/secrets/pppoe-credentials"
' "${tmp_dir}/delivery-record.json" >/dev/null || {
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-020-SN2: delivery record missing secretReference field" >&2
  cat "${tmp_dir}/delivery-record.json" | jq . >&2
  exit 1
}
echo "PASS FS-840-HDS-010-SDS-010-SMS-020-SN2: delivery record includes secretReference (path reference)"

# ── Verify secretContent field name is detected ───────────────────────────────

secret_content_output="$(nix_eval_plaintext_guard '
{
  secretDeclarations = [
    {
      id = "decl-content-020";
      credentialClass = "generic-secret";
      site = "nixos";
      tenant = "tenant-a";
      host = "test-host";
      consumer = {
        kind = "service";
        node = "test-node";
        name = "generic.client";
      };
      purpose = "generic-secret";
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
        "FS-840-HDS-010-SDS-010-SMS-020"
      ];
    }
  ];
  secretSources = [
    {
      id = "source-content-020";
      declarationId = "decl-content-020";
      sourceClass = "generic-secret";
      reference = {
        name = "content-secret";
        runtimePath = "generic-secret";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      secretContent = "my-secret-api-key-value";
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
  sourceBindings = [
    {
      id = "binding-content-020";
      declarationId = "decl-content-020";
      sourceId = "source-content-020";
      sourceClass = "generic-secret";
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
      gampIds = [ "FS-840-HDS-010-SDS-010-SMS-020" ];
    }
  ];
}' "plaintextSecretDiagnostics")"

jq -e '
  length == 1 and
  .[0].diagnosticName == "PLAINTEXT_SECRET_IN_DELIVERY" and
  .[0].credentialClass == "generic-secret" and
  (.[0].plaintextFields | length) == 1 and
  .[0].plaintextFields[0] == "secretContent"
' <<<"$secret_content_output" >/dev/null || {
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-020-SN2: secretContent field did not produce diagnostic" >&2
  echo "$secret_content_output" | jq . >&2
  exit 1
}
echo "PASS FS-840-HDS-010-SDS-010-SMS-020-SN2: secretContent field rejected with PLAINTEXT_SECRET_IN_DELIVERY"

echo "PASS test-FS-840-HDS-010-SDS-010-SMS-020-SN2-plaintext-secret-in-delivery"
