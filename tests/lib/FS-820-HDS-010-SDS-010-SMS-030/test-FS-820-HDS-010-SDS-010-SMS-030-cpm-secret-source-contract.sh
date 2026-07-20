#!/usr/bin/env bash
# GAMP-ID: FS-820-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
# Trace chain: FS-820 → HDS-010 → SDS-010 → SMS-030 (secret source policy boundary)
# Also proves: FS-840-HDS-010-SDS-010-SMS-010 (scoped delivery), FS-840-HDS-010-SDS-010-SMS-030 (readiness rejection)
# Wired into CPM test runner via tests/ directory glob: test-FS-820-*.sh
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

expect_failure() {
  local name="$1"
  local inventory="$2"
  local expected="$3"
  local stderr_path="${tmp_dir}/${name}.stderr"

  if build_cpm "${inventory}" "${tmp_dir}/${name}.json" 2>"${stderr_path}"; then
    echo "FAIL FS-820-HDS-010-SDS-010-SMS-030: ${name} unexpectedly evaluated" >&2
    exit 1
  fi

  if ! grep -Fq "${expected}" "${stderr_path}"; then
    echo "FAIL FS-820-HDS-010-SDS-010-SMS-030: ${name} missing diagnostic" >&2
    echo "expected substring: ${expected}" >&2
    cat "${stderr_path}" >&2
    exit 1
  fi
}

write_inventory_with_secrets() {
  local mode="$1"
  local target="$2"

  cat >"${target}" <<'HEREDOC_HEADER'
let
  base = import
HEREDOC_HEADER
  echo "    ${inventory_path};" >>"${target}"

  # Common secret declarations used by positive and readiness tests
  if [ "${mode}" = "positive" ] || [ "${mode}" = "readiness-missing" ]; then
    cat >>"${target}" <<'SECRET_COMMON'
  secretDeclarations = [
    {
      id = "decl-pppoe-username";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = null;
      host = "test-host";
      consumer = {
        kind = "service";
        node = "test-node";
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
      gampIds = [
        "FS-820-HDS-010-SDS-010"
        "FS-820-HDS-010-SDS-010-SMS-030"
      ];
    }
  ];

  secretSources = [
    {
      id = "source-pppoe-username";
      declarationId = "decl-pppoe-username";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "test-secret";
        runtimePath = "test-secret-pppoe-username";
        sourceFieldPath = "deployment.hosts.test-host.credentials.usernameFile";
      };
      lifecycle = "hat-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [
        "FS-820-HDS-010-SDS-010"
        "FS-820-HDS-010-SDS-010-SMS-030"
      ];
    }
  ];

  sourceBindings = [
    {
      id = "binding-pppoe-username";
      declarationId = "decl-pppoe-username";
      sourceId = "source-pppoe-username";
      sourceClass = "deployment-platform-secret-reference";
      bindingKind = "declaration-source";
      sourceFieldPath = "deployment.hosts.test-host.credentials.usernameFile";
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
        "FS-820-HDS-010-SDS-010"
        "FS-820-HDS-010-SDS-010-SMS-030"
      ];
    }
  ];
SECRET_COMMON
  fi

  cat >>"${target}" <<'HEREDOC_FOOTER'
in
base // {
  inherit secretDeclarations secretSources sourceBindings;
}
HEREDOC_FOOTER
}

write_inventory_fixed_path() {
  local target="$1"

  cat >"${target}" <<'HEREDOC_FIXED_HEADER'
let
  base = import
HEREDOC_FIXED_HEADER
  echo "    ${inventory_path};" >>"${target}"

  cat >>"${target}" <<'FIXED_SECRET'
  secretDeclarations = [
    {
      id = "decl-evil-01";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = null;
      host = "evil-host";
      consumer = {
        kind = "service";
        node = "evil-node";
        name = "evil.service";
      };
      purpose = "evil-purpose";
      lifecycle = "evil-runtime";
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
      gampIds = [ "FS-820-HDS-010-SDS-010-SMS-030" ];
    }
  ];

  secretSources = [
    {
      id = "source-evil-01";
      declarationId = "decl-evil-01";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "evil-secret";
        runtimePath = "/run/secrets/evil";
        sourceFieldPath = "evil.path";
      };
      lifecycle = "evil-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [ "FS-820-HDS-010-SDS-010-SMS-030" ];
    }
  ];

  sourceBindings = [
    {
      id = "binding-evil-01";
      declarationId = "decl-evil-01";
      sourceId = "source-evil-01";
      sourceClass = "deployment-platform-secret-reference";
      bindingKind = "declaration-source";
      sourceFieldPath = "evil.path";
      policyAuthority = {
        createsRouteAuthority = false;
        createsFirewallPolicy = false;
        createsDnsPolicy = false;
        createsPublicIngress = false;
        createsTenantReachability = false;
        createsTrustBoundary = false;
        createsNetworkBehavior = false;
      };
      gampIds = [ "FS-820-HDS-010-SDS-010-SMS-030" ];
    }
  ];
FIXED_SECRET

  cat >>"${target}" <<'HEREDOC_FOOTER'
in
base // {
  inherit secretDeclarations secretSources sourceBindings;
}
HEREDOC_FOOTER
}

write_inventory_empty_path() {
  local target="$1"

  cat >"${target}" <<'HEREDOC_EMPTY_HEADER'
let
  base = import
HEREDOC_EMPTY_HEADER
  echo "    ${inventory_path};" >>"${target}"

  cat >>"${target}" <<'EMPTY_SECRET'
  secretDeclarations = [
    {
      id = "decl-empty-01";
      credentialClass = "provider-credential";
      site = "nixos";
      tenant = null;
      host = "empty-host";
      consumer = {
        kind = "service";
        node = "empty-node";
        name = "empty.service";
      };
      purpose = "empty-purpose";
      lifecycle = "empty-runtime";
      required = false;
      requiredness = "optional";
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
      gampIds = [ "FS-820-HDS-010-SDS-010-SMS-030" ];
    }
  ];

  secretSources = [
    {
      id = "source-empty-01";
      declarationId = "decl-empty-01";
      sourceClass = "deployment-platform-secret-reference";
      reference = {
        name = "empty-secret";
        runtimePath = "";
        sourceFieldPath = "empty.path";
      };
      lifecycle = "empty-runtime";
      materialAccess = "not-supplied-by-source-record";
      plaintextMaterial = false;
      providerNeutral = true;
      fixedSecretManagerRequired = false;
      gampIds = [ "FS-820-HDS-010-SDS-010-SMS-030" ];
    }
  ];

  sourceBindings = [];
EMPTY_SECRET

  cat >>"${target}" <<'HEREDOC_FOOTER'
in
base // {
  inherit secretDeclarations secretSources sourceBindings;
}
HEREDOC_FOOTER
}

# ── Positive case: abstract reference names accepted and mediated ────────────

positive_inventory="${tmp_dir}/positive-inventory.nix"
write_inventory_with_secrets "positive" "${positive_inventory}"
build_cpm "${positive_inventory}" "${tmp_dir}/positive.json"

jq -e '
  .control_plane_model.secretSources as $sources
  | .control_plane_model.secretDeliveryRecords as $deliveries
  | .control_plane_model.secretReadiness as $readiness
  | ($sources | length) == 1
    and $sources[0].reference.runtimePath == "test-secret-pppoe-username"
    and $sources[0].reference.mediatedRuntimePath == "/run/secrets/test-secret-pppoe-username"
    and ($deliveries | length) == 1
    and $deliveries[0].mediatedPath == "/run/secrets/test-secret-pppoe-username"
    and $deliveries[0].deliveryScope.site == "nixos"
    and $deliveries[0].deliveryScope.host == "test-host"
    and $deliveries[0].deliveryScope.consumer.node == "test-node"
    and $deliveries[0].deliveryScope.consumer.name == "pppoe.client"
    and $deliveries[0].deliveryScope.service == "pppoe-username"
    and ($deliveries[0].gampIds | index("FS-840-HDS-010-SDS-010-SMS-010")) != null
    and ($readiness.readinessDiagnostics | length) == 1
    and $readiness.allMaterialReady == false
    and $readiness.readinessDiagnostics[0].materialAccess == "not-supplied-by-source-record"
    and $readiness.readinessDiagnostics[0].mediatedPath == "/run/secrets/test-secret-pppoe-username"
    and ($readiness.readinessDiagnostics[0].diagnostic | startswith("FS-840-HDS-010-SDS-010-SMS-030"))
' "${tmp_dir}/positive.json" >/dev/null || {
  echo "FAIL FS-820-HDS-010-SDS-010-SMS-030: abstract reference mediation failed" >&2
  exit 1
}

echo "PASS FS-820-HDS-010-SDS-010-SMS-030: abstract reference accepted and mediated"

# ── Negative: fixed filesystem path rejected ─────────────────────────────────

fixed_path_inventory="${tmp_dir}/fixed-path-inventory.nix"
write_inventory_fixed_path "${fixed_path_inventory}"

expect_failure \
  "fixed-path-rejection" \
  "${fixed_path_inventory}" \
  "FS-820-HDS-010-SDS-010-SMS-030: runtimePath must be an abstract reference name (no leading /)"

echo "PASS FS-820-HDS-010-SDS-010-SMS-030: fixed path rejected"

# ── Negative: empty runtimePath rejected ─────────────────────────────────────

empty_path_inventory="${tmp_dir}/empty-path-inventory.nix"
write_inventory_empty_path "${empty_path_inventory}"

expect_failure \
  "empty-path-rejection" \
  "${empty_path_inventory}" \
  "FS-820-HDS-010-SDS-010-SMS-030: runtimePath must be an abstract reference name"

echo "PASS FS-820-HDS-010-SDS-010-SMS-030: empty runtimePath rejected"

# ── Prove secret declarations/sources/bindings preserved in output ───────────

jq -e '
  .control_plane_model.secretDeclarations as $declarations
  | .control_plane_model.secretSources as $sources
  | .control_plane_model.sourceBindings as $bindings
  | ($declarations | length) == 1
    and $declarations[0].id == "decl-pppoe-username"
    and $declarations[0].purpose == "pppoe-username"
    and ($sources | length) == 1
    and $sources[0].id == "source-pppoe-username"
    and $sources[0].reference.runtimePath == "test-secret-pppoe-username"
    and $sources[0].reference.mediatedRuntimePath == "/run/secrets/test-secret-pppoe-username"
    and ($bindings | length) == 1
    and $bindings[0].id == "binding-pppoe-username"
' "${tmp_dir}/positive.json" >/dev/null || {
  echo "FAIL FS-820-HDS-010-SDS-010-SMS-030: secret records not preserved with mediation" >&2
  exit 1
}

echo "PASS FS-820-HDS-010-SDS-010-SMS-030: secret records preserved with mediated paths"

# ── Prove readiness rejection emits diagnostics for missing material ─────────

readiness_inventory="${tmp_dir}/readiness-inventory.nix"
write_inventory_with_secrets "readiness-missing" "${readiness_inventory}"
build_cpm "${readiness_inventory}" "${tmp_dir}/readiness.json"

jq -e '
  .control_plane_model.secretReadiness as $readiness
  | $readiness.allMaterialReady == false
    and ($readiness.readinessDiagnostics | length) == 1
    and $readiness.readinessDiagnostics[0].materialAccess == "not-supplied-by-source-record"
    and $readiness.readinessDiagnostics[0].mediatedPath == "/run/secrets/test-secret-pppoe-username"
    and ($readiness.readinessDiagnostics[0].diagnostic | startswith("FS-840-HDS-010-SDS-010-SMS-030"))
    and ($readiness.readinessDiagnostics[0].gampIds | index("FS-840-HDS-010-SDS-010-SMS-030")) != null
    and $readiness.readinessDiagnostics[0].consumer.node == "test-node"
    and $readiness.readinessDiagnostics[0].scope.site == "nixos"
    and $readiness.readinessDiagnostics[0].scope.host == "test-host"
' "${tmp_dir}/readiness.json" >/dev/null || {
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-030: readiness diagnostics not correctly scoped" >&2
  exit 1
}

echo "PASS FS-840-HDS-010-SDS-010-SMS-030: readiness rejection diagnostics scoped to consumer"

# ── Prove scoped delivery records ────────────────────────────────────────────

jq -e '
  .control_plane_model.secretDeliveryRecords as $deliveries
  | ($deliveries | length) == 1
    and $deliveries[0].deliveryId == "binding-pppoe-username-delivery"
    and $deliveries[0].bindingId == "binding-pppoe-username"
    and $deliveries[0].declarationId == "decl-pppoe-username"
    and $deliveries[0].sourceId == "source-pppoe-username"
    and $deliveries[0].deliveryScope.site == "nixos"
    and $deliveries[0].deliveryScope.host == "test-host"
    and $deliveries[0].deliveryScope.consumer.kind == "service"
    and $deliveries[0].deliveryScope.consumer.node == "test-node"
    and $deliveries[0].deliveryScope.consumer.name == "pppoe.client"
    and $deliveries[0].deliveryScope.service == "pppoe-username"
    and $deliveries[0].mediatedPath == "/run/secrets/test-secret-pppoe-username"
    and ($deliveries[0].gampIds | index("FS-840-HDS-010-SDS-010-SMS-010")) != null
' "${tmp_dir}/readiness.json" >/dev/null || {
  echo "FAIL FS-840-HDS-010-SDS-010-SMS-010: scoped delivery records not emitted correctly" >&2
  exit 1
}

echo "PASS FS-840-HDS-010-SDS-010-SMS-010: scoped delivery records emitted with consumer scope"

# ── Prove HAT built-in secrets are mediated (abstract → platform paths) ──────

build_cpm "${inventory_path}" "${tmp_dir}/hat-secrets.json"

jq -e '
  def has_id($id): (.gampIds // [] | index($id)) != null;
  .control_plane_model.secretSources as $sources
  | .control_plane_model.secretDeclarations as $declarations
  | .control_plane_model.sourceBindings as $bindings
  | .control_plane_model.secretDeliveryRecords as $deliveries
  | .control_plane_model.secretReadiness as $readiness
  | ($sources | length) > 0
    and ($declarations | length) > 0
    and ($bindings | length) > 0
    and all($sources[];
      .reference.runtimePath != null
      and (.reference.runtimePath | startswith("/") | not)
      and .reference.mediatedRuntimePath != null
      and (.reference.mediatedRuntimePath | startswith("/run/secrets/"))
    )
    and ($deliveries | length) == ($bindings | length)
    and all($deliveries[];
      .mediatedPath != null
      and (.mediatedPath | startswith("/run/secrets/"))
      and has_id("FS-840-HDS-010-SDS-010-SMS-010")
    )
    and $readiness.allMaterialReady == false
    and (($readiness.readinessDiagnostics // []) | length) > 0
' "${tmp_dir}/hat-secrets.json" >/dev/null || {
  echo "FAIL FS-820-HDS-010-SDS-010-SMS-030: HAT secrets not properly mediated" >&2
  exit 1
}

echo "PASS FS-820-HDS-010-SDS-010-SMS-030: HAT secrets mediated with abstract-to-platform path mapping"

echo "PASS test-FS-820-HDS-010-SDS-010-SMS-030-cpm-secret-source-contract"
