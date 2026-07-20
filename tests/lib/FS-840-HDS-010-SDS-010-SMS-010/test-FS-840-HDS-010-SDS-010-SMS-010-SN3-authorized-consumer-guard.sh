#!/usr/bin/env bash
# GAMP-ID: FS-840-HDS-010-SDS-010-SMS-010-SN3
# GAMP-SCOPE: software-module-test
# Trace chain: FS-840 → HDS-010 → SDS-010 → SMS-010 SN3 (authorizedConsumer null/empty guard)
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

archive_json="${tmp_dir}/flake-archive.json"

nix flake archive --json "path:${repo_root}" >"${archive_json}"
labs_path="$(
  jq -er '.inputs["network-labs"].path' "${archive_json}"
)"

intent_path="${labs_path}/HAT/emulated-isp-residential-testnet/intent.nix"
inventory_path="${labs_path}/HAT/emulated-isp-residential-testnet/inventory-nixos.nix"

build_cpm() {
  local inventory="$1"
  local output="$2"

  nix run \
    --no-write-lock-file \
    --extra-experimental-features 'nix-command flakes' \
    "path:${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory}" \
    "${output}" >/dev/null
}

write_inventory_without_consumer() {
  local target="$1"

  cat >"${target}" <<'HEREDOC_HEADER'
let
  base = import
HEREDOC_HEADER
  echo "    ${inventory_path};" >>"${target}"

  cat >>"${target}" <<'NO_CONSUMER_SECRET'
  # Seeded negative: declaration WITHOUT consumer field to prove
  # authorizedConsumerDiagnosticForRecord rejects it
  secretDeclarations = [
    {
      id = "decl-no-consumer";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = null;
      host = "no-consumer-host";
      # consumer intentionally omitted — seeded negative for SN3
      purpose = "no-consumer-purpose";
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
      id = "source-no-consumer";
      declarationId = "decl-no-consumer";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "no-consumer-secret";
        runtimePath = "no-consumer-pppoe-username";
        sourceFieldPath = "deployment.hosts.no-consumer-host.credentials.usernameFile";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [
        "FS-840-HDS-010-SDS-010"
        "FS-840-HDS-010-SDS-010-SMS-010"
      ];
    }
  ];

  sourceBindings = [
    {
      id = "binding-no-consumer";
      declarationId = "decl-no-consumer";
      sourceId = "source-no-consumer";
      sourceClass = "deployment-platform-secret-reference";
      bindingKind = "declaration-source";
      sourceFieldPath = "deployment.hosts.no-consumer-host.credentials.usernameFile";
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
NO_CONSUMER_SECRET

  cat >>"${target}" <<'HEREDOC_FOOTER'
in
base // {
  inherit secretDeclarations secretSources sourceBindings;
}
HEREDOC_FOOTER
}

write_inventory_with_empty_consumer() {
  local target="$1"

  cat >"${target}" <<'HEREDOC_HEADER'
let
  base = import
HEREDOC_HEADER
  echo "    ${inventory_path};" >>"${target}"

  cat >>"${target}" <<'EMPTY_CONSUMER_SECRET'
  # Seeded negative: declaration with empty consumer {} to prove
  # authorizedConsumerDiagnosticForRecord rejects it
  secretDeclarations = [
    {
      id = "decl-empty-consumer";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = null;
      host = "empty-consumer-host";
      consumer = { };  # empty attrset — seeded negative for SN3
      purpose = "empty-consumer-purpose";
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
      id = "source-empty-consumer";
      declarationId = "decl-empty-consumer";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "empty-consumer-secret";
        runtimePath = "empty-consumer-pppoe-username";
        sourceFieldPath = "deployment.hosts.empty-consumer-host.credentials.usernameFile";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [
        "FS-840-HDS-010-SDS-010"
        "FS-840-HDS-010-SDS-010-SMS-010"
      ];
    }
  ];

  sourceBindings = [
    {
      id = "binding-empty-consumer";
      declarationId = "decl-empty-consumer";
      sourceId = "source-empty-consumer";
      sourceClass = "deployment-platform-secret-reference";
      bindingKind = "declaration-source";
      sourceFieldPath = "deployment.hosts.empty-consumer-host.credentials.usernameFile";
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
EMPTY_CONSUMER_SECRET

  cat >>"${target}" <<'HEREDOC_FOOTER'
in
base // {
  inherit secretDeclarations secretSources sourceBindings;
}
HEREDOC_FOOTER
}

# ── Positive case: existing HAT inventory with consumers → allAuthorized should be true ──

build_cpm "${inventory_path}" "${tmp_dir}/positive.json"

jq -e '
  .control_plane_model.secretAuthorization as $auth
  | $auth.allAuthorized == true
    and ($auth.authorizedConsumerDiagnostics | length) == 0
' "${tmp_dir}/positive.json" >/dev/null || {
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-010-SN3: positive case — expected allAuthorized=true but got diagnostics" >&2
  jq '.control_plane_model.secretAuthorization' "${tmp_dir}/positive.json" >&2
  exit 1
}

echo "PASS FS-840-HDS-010-SDS-010-SMS-010-SN3: positive case — allAuthorized=true, no diagnostics"

# ── Seeded negative: declaration WITHOUT consumer → diagnostic produced ──

no_consumer_inventory="${tmp_dir}/no-consumer-inventory.nix"
write_inventory_without_consumer "${no_consumer_inventory}"

build_cpm "${no_consumer_inventory}" "${tmp_dir}/no-consumer.json"

jq -e '
  .control_plane_model.secretAuthorization as $auth
  | $auth.allAuthorized == false
    and ($auth.authorizedConsumerDiagnostics | length) == 1
    and $auth.authorizedConsumerDiagnostics[0].diagnosticName == "runtime-missing-authorized-consumer"
    and $auth.authorizedConsumerDiagnostics[0].deliveryId == "binding-no-consumer-delivery"
    and ($auth.authorizedConsumerDiagnostics[0].gampIds | index("FS-840-HDS-010-SDS-010-SMS-010")) != null
    and $auth.authorizedConsumerDiagnostics[0].consumer == {}
' "${tmp_dir}/no-consumer.json" >/dev/null || {
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-010-SN3: missing consumer did not produce diagnostic" >&2
  jq '.control_plane_model.secretAuthorization' "${tmp_dir}/no-consumer.json" >&2
  exit 1
}

echo "PASS FS-840-HDS-010-SDS-010-SMS-010-SN3: missing consumer rejected with runtime-missing-authorized-consumer"

# ── Seeded negative: declaration with empty consumer {} → diagnostic produced ──

empty_consumer_inventory="${tmp_dir}/empty-consumer-inventory.nix"
write_inventory_with_empty_consumer "${empty_consumer_inventory}"

build_cpm "${empty_consumer_inventory}" "${tmp_dir}/empty-consumer.json"

jq -e '
  .control_plane_model.secretAuthorization as $auth
  | $auth.allAuthorized == false
    and ($auth.authorizedConsumerDiagnostics | length) == 1
    and $auth.authorizedConsumerDiagnostics[0].diagnosticName == "runtime-missing-authorized-consumer"
    and $auth.authorizedConsumerDiagnostics[0].deliveryId == "binding-empty-consumer-delivery"
    and ($auth.authorizedConsumerDiagnostics[0].gampIds | index("FS-840-HDS-010-SDS-010-SMS-010")) != null
    and $auth.authorizedConsumerDiagnostics[0].consumer == {}
' "${tmp_dir}/empty-consumer.json" >/dev/null || {
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-010-SN3: empty consumer {} did not produce diagnostic" >&2
  jq '.control_plane_model.secretAuthorization' "${tmp_dir}/empty-consumer.json" >&2
  exit 1
}

echo "PASS FS-840-HDS-010-SDS-010-SMS-010-SN3: empty consumer {} rejected with runtime-missing-authorized-consumer"

echo "PASS test-FS-840-HDS-010-SDS-010-SMS-010-SN3-authorized-consumer-guard"
