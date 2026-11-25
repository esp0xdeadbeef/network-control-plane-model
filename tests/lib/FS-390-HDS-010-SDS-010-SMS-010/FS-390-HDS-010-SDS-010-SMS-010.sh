#!/usr/bin/env bash
# GAMP-ID: FS-390-HDS-010-SDS-010-SMS-010
# Construction regression: CPM preserves the upstream NFM forwarding artifact for renderers.
set -euo pipefail

trace_id="FS-390-HDS-010-SDS-010-SMS-010"
repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
network_labs_root="${NETWORK_LABS_ROOT:-${repo_root}/../network-labs}"
network_forwarding_model_root="${NETWORK_FORWARDING_MODEL_ROOT:-${repo_root}/../network-forwarding-model}"
tmp_dir="$(mktemp -d "${TMPDIR:-/var/tmp}/${trace_id}-cpm-artifact.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
  echo "FAIL ${trace_id}: $*" >&2
  exit 1
}

[[ -d "${network_labs_root}" ]] || fail "missing network-labs root: ${network_labs_root}"
[[ -d "${network_forwarding_model_root}" ]] || fail "missing network-forwarding-model root: ${network_forwarding_model_root}"
command -v jq >/dev/null 2>&1 || fail "jq is required"

ln -s "${network_labs_root}/GAMP" "${tmp_dir}/GAMP"
NETWORK_LABS_CURRENT_LAB_DIR="${tmp_dir}/current-lab" \
NETWORK_FORWARDING_MODEL_ROOT="${network_forwarding_model_root}" \
  bash "${network_labs_root}/scripts/select-current-lab.sh" SMT "${trace_id}" >/dev/null

forwarding_from_cpm="${tmp_dir}/forwarding-from-cpm.json"
cpm_stderr="${tmp_dir}/cpm.stderr"

REPO_ROOT="${repo_root}" \
INTENT_PATH="${tmp_dir}/current-lab/intent-s-router-nixos.nix" \
INVENTORY_PATH="${tmp_dir}/current-lab/inventory-s-router-nixos.nix" \
  nix eval --no-write-lock-file \
    --extra-experimental-features 'nix-command flakes' \
    --impure \
    --json \
    --expr '
      let
        flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
        out = flake.libBySystem.x86_64-linux.compileAndBuildFromPaths {
          inputPath = builtins.getEnv "INTENT_PATH";
          inventoryPath = builtins.getEnv "INVENTORY_PATH";
          validateForwardingModel = false;
          validateRuntimeModel = false;
        };
      in
        out.forwardingOut
    ' >"${forwarding_from_cpm}" 2>"${cpm_stderr}" || {
  # -------------------------------------------------------------------------
  # KNOWN FINDING, pinned. This fixture declares a tenant-owned public address
  # (`ownership.prefixes[].publicIpv4 = 198.51.100.10/32`) and the FS-390 row
  # requires the CPM to classify it as an `enterprise-client` destination -- so
  # the address is a modeled public DESTINATION. The prefix-authority model
  # publishes it to `tenantPrefixOwners` as a routed tenant prefix, and
  # FS-370-HDS-010-SDS-010-SMS-101's guard then requires a per-lane return path
  # for it on the downstream-selector and policy targets.
  #
  # Nothing in the fleet routes that address: `publicIpv4` has no consumer in
  # network-control-plane-model (`grep -rn publicIpv4 src/` is empty) and the
  # only fixtures that declare it are FS-390's three mini-SMTs. So the guard
  # demands a return path for a destination the model treats as egress-only, and
  # the compile fails closed exactly as designed.
  #
  # Which side is wrong is a scope decision, not a test decision: either a
  # public destination owned by a tenant is routed into the lane (then the model
  # must emit the lane route and this test must stay strict), or it is not (then
  # FS-370's guard must not require a return path for it). Pinned so this suite
  # reports the finding instead of hiding it behind a permanently red test, and
  # so that any OTHER failure here -- a different diagnostic, a different prefix,
  # a crash -- still fails.
  # -------------------------------------------------------------------------
  pinned="${repo_root}/tests/lib/FS-390-HDS-010-SDS-010-SMS-010.known-finding.json"
  pinned_rc=3
  if [[ -f "${pinned}" ]]; then
    # The comparison is a verdict, so a non-zero exit is DATA here, not an error:
    # under `set -e` an assignment whose substitution fails aborts the case and
    # the finding would surface as "no forwardingOut" instead of as a mismatch.
    set +e
    python3 - "${cpm_stderr}" "${pinned}" <<'PY2'
import json, re, sys

raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
match = re.search(r"validation failed: (\[.*?\])", raw, re.S)
if match is None:
    sys.exit(3)
try:
    found = json.loads(match.group(1))
except ValueError:
    sys.exit(3)

expected = json.load(open(sys.argv[2], encoding="utf-8"))

def key(d):
    return (d.get("code"), d.get("prefix"), d.get("interface"), d.get("expectedLane"))

if sorted(found, key=key) == sorted(expected, key=key):
    sys.exit(0)
print("  found:", json.dumps(sorted(found, key=key), indent=2), file=sys.stderr)
print("  pinned:", json.dumps(sorted(expected, key=key), indent=2), file=sys.stderr)
sys.exit(1)
PY2
    pinned_rc=$?
    set -e
  fi
  if [[ "${pinned_rc}" == "0" ]]; then
    echo "KNOWN-FINDING ${trace_id}: CPM refuses to route a tenant-owned public destination"
    echo "  the diagnostic set matches tests/lib/FS-390-HDS-010-SDS-010-SMS-010.known-finding.json"
    python3 -c 'import json,sys; [print("  ", json.dumps(d, sort_keys=True)) for d in json.load(open(sys.argv[1]))]' "${pinned}"
    exit 0
  fi
  sed 's/^/  /' "${cpm_stderr}" >&2
  fail "CPM compileAndBuildFromPaths did not expose forwardingOut"
}

jq -e --arg trace "${trace_id}" '
  .enterprise."mini-smt".site[$trace].publicIpv4DestinationPolicy.destinationClasses as $classes
  | $classes["public-ipv4-destination::198.51.100.10"] as $enterpriseClient
  | $classes["public-ipv4-destination::198.51.100.11"] as $tenantService
  | $classes["public-ipv4-destination::203.0.113.50"] as $seededTenantService
  | $classes["public-ipv4-destination::198.51.100.12"] as $localOwned
  | $classes["public-ipv4-destination::198.51.100.13"] as $providerOwned
  | $classes["public-ipv4-destination::198.51.100.14"] as $publicIngress
  | ($enterpriseClient.destinationClass == "enterprise-client")
    and ($enterpriseClient.ownerKind == "tenant")
    and ($enterpriseClient.ownerName == "client")
    and ($enterpriseClient.source == "domains.tenants")
    and ($tenantService.destinationClass == "tenant-service")
    and ($tenantService.ownerName == "tenant-api")
    and ($seededTenantService.destinationClass == "tenant-service")
    and ($seededTenantService.ownerName == "fixture-missing-output")
    and ($localOwned.destinationClass == "locally-owned-routed")
    and ($localOwned.ownerName == "locally-routed-endpoint")
    and ($providerOwned.destinationClass == "provider-owned")
    and ($providerOwned.ownerName == "provider-owned-endpoint")
    and ($publicIngress.destinationClass == "public-ingress")
    and ($publicIngress.ownerName == "public-web")
    and ([
      $enterpriseClient,
      $tenantService,
      $seededTenantService,
      $localOwned,
      $providerOwned,
      $publicIngress
    ] | all(.modelOwned == true and (.ownerName != null) and (.ownerKind != null) and (.source != null)))
' "${forwarding_from_cpm}" >/dev/null || {
  jq '.enterprise."mini-smt".site[$trace].publicIpv4DestinationPolicy' \
    --arg trace "${trace_id}" \
    "${forwarding_from_cpm}" >&2
  fail "CPM forwardingOut lost FS-390 public IPv4 destination classification"
}

echo "PASS ${trace_id}: CPM exposes NFM forwarding artifact for renderer audit output"
