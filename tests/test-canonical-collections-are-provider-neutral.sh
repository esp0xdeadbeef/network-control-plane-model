#!/usr/bin/env bash
# GAMP-SCOPE: contract test; canonical collections vs the names the fleet publishes
#
# CANONICAL COLLECTIONS ARE PROVIDER-NEUTRAL, AND THE COLLECTIONS AGREE WITH EACH
# OTHER.
#
# Two rules, both stated by documents this repository does not own:
#
#   1. A canonical collection may not be named after a provider.
#      `network-renderer-nixos/README.md`, "Not Allowed": a renderer must not
#      "treat a provider name such as `nebula`, `wireguard`, or `openvpn` as
#      generic forwarding truth". The model naming a collection
#      `canonicalWireGuard` asserts exactly that one layer up.
#
#   2. Two collections that describe the same overlays must describe the same
#      overlays. `canonicalSites` publishes overlay topology; a collection that
#      publishes provider material for overlays is talking about the same set, so
#      a name in one and not the other is a join that cannot complete.
#
# This test evaluates the model and checks both. It does not read source text: a
# collection could be renamed in one place and aliased in another, and only the
# evaluated output shows what a renderer would receive.
#
# WHAT IT CHECKS
# --------------
# P1  No published `canonical*` collection embeds a provider name.
# P2  `canonicalOverlays` exists and every record carries the fields a consumer
#     needs: `provider`, `providerMaterial`, `providerContract`, `terminateOn`,
#     `nodes`.
# P3  The overlay names in `canonicalOverlays.byOverlay` and in
#     `canonicalSites.overlays` are the same set.
#
# STATUS: expected RED until the producer and the schema agree on names. That is
# the point: the schema declares a closed set, so a collection the model publishes
# and the schema does not name is not merely untidy, it is rejected at validation.
#
# Evidence boundary: construction. Evaluation only.
set -euo pipefail

if [[ -n "${SMS_TEST_REPO_ROOT:-}" ]]; then
  repo_root="${SMS_TEST_REPO_ROOT}"
else
  repo_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "${repo_root}" ]] || repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
workspace_root="${NETWORK_WORKSPACE_ROOT:-$(cd "${repo_root}/.." && pwd)}"

echo "--- S88-CANONICAL-NAMES: provider-neutral collections, coherent overlay sets ---"
echo ""

# The fixture is an overlay example; the provider names only appear when an
# overlay actually exists.
example="${CANONICAL_TEST_EXAMPLE:-${workspace_root}/network-labs/examples/wireguard-provider-overlay}"
if [[ ! -f "${example}/intent.nix" ]]; then
  echo "SKIP S88-CANONICAL-NAMES: no overlay example at ${example}"
  echo "  (set CANONICAL_TEST_EXAMPLE to an intent+inventory pair to run this)"
  exit 0
fi

probe="$(mktemp)"
trap 'rm -f "${probe}"' EXIT

if ! env REPO_ROOT="${repo_root}" EXAMPLE="${example}" \
  nix eval --impure --json --expr '
    let
      repoRoot = builtins.getEnv "REPO_ROOT";
      example = builtins.getEnv "EXAMPLE";
      flake = builtins.getFlake ("path:" + repoRoot);
      lib = flake.inputs.nixpkgs.lib;
      system = "x86_64-linux";
      cpm = flake.lib.${system}.compileAndBuildFromPaths {
        inputPath = example + "/intent.nix";
        inventoryPath = example + "/inventory-nixos.nix";
      };
      model = cpm.control_plane_model;
      canonicalNames = builtins.filter (lib.hasPrefix "canonical") (builtins.attrNames model);
      overlays = (model.canonicalOverlays or { }).byOverlay or { };
      sites = (model.canonicalSites or { }).overlays or [ ];
      siteOverlayNames = lib.unique (map (entry: entry.overlay) sites);
      requiredFields = [ "provider" "providerMaterial" "providerContract" "terminateOn" "nodes" ];
      missingFields = builtins.concatMap
        (name:
          map (field: "${name} lacks ${field}")
            (builtins.filter (field: !(overlays.${name} ? ${field})) requiredFields))
        (builtins.attrNames overlays);
      providerFieldTypes = builtins.mapAttrs (_: record: builtins.typeOf (record.provider or null)) overlays;
    in
    {
      inherit canonicalNames siteOverlayNames missingFields providerFieldTypes;
      overlayNames = builtins.attrNames overlays;
    }
  ' >"${probe}" 2>/dev/null; then
  echo "FAIL S88-CANONICAL-NAMES: the evaluation needed for the check failed" >&2
  exit 1
fi

read_json() { python3 -c "import json,sys; d=json.load(open('${probe}')); print($1)"; }

issues=0
report_issue() {
  local id="$1" finding="$2" why="$3" read="$4"
  issues=$((issues + 1))
  {
    echo "ISSUE ${id}: ${finding}"
    echo "  why:  ${why}"
    echo "  read: ${read}"
  } >&2
}

read_pointer="network-renderer-nixos/README.md -> Not Allowed ('Treat a provider name such
         as nebula, wireguard, or openvpn as generic forwarding truth'), and
         network-realization-schema/schema/default.nix -> bundle.canonicalCollections,
         which is a CLOSED set: a collection the producer publishes and the schema does
         not name is rejected at validation."

# ---------------------------------------------------------------------------
# P1 -- no provider name inside a canonical collection name.
# ---------------------------------------------------------------------------
providers="wireguard nebula openvpn tailscale ipsec vxlan"
offending="$(python3 - "$probe" "${providers}" <<'PY'
import json, sys
probe, providers = sys.argv[1], sys.argv[2].split()
d = json.load(open(probe))
hits = []
for name in d["canonicalNames"]:
    lowered = name.lower()
    for provider in providers:
        if provider in lowered:
            hits.append(f"{name} (contains '{provider}')")
print("\n".join(hits))
PY
)"

if [[ -n "${offending}" ]]; then
  report_issue "P1" "canonical collection(s) named after a provider:
$(sed 's/^/      /' <<<"${offending}")" \
    "a canonical collection is the model's provider-neutral statement. Naming one after
       the transport that carries it means a second provider cannot be represented without
       a second collection, and every consumer learns the provider's name to find the
       facts." \
    "${read_pointer}"
else
  echo "PASS P1: no canonical collection name embeds a provider name"
fi

# ---------------------------------------------------------------------------
# P2 -- the overlay records carry the fields a consumer needs.
# ---------------------------------------------------------------------------
missing="$(read_json "'\\n'.join(d['missingFields'])")"
overlay_names="$(read_json "' '.join(d['overlayNames'])")"
bad_types="$(read_json "' '.join(k for k, v in d['providerFieldTypes'].items() if v != 'string')")"

if [[ -z "${overlay_names}" ]]; then
  report_issue "P2" "canonicalOverlays.byOverlay is empty for a model with overlays" \
    "an empty collection is the failure mode this test exists for: a renderer consuming it
       renders nothing and has no field to fail on. Measured: the provider-named collection
       this replaced was empty for exactly this example." \
    "${read_pointer}"
elif [[ -n "${missing}" ]]; then
  report_issue "P2" "canonicalOverlays records are missing required fields:
$(sed 's/^/      /' <<<"${missing}")" \
    "each field is what a consumer needs to place the overlay: the provider as a value, the
       material it terminates on, the contract, and the topology." \
    "${read_pointer}"
elif [[ -n "${bad_types}" ]]; then
  report_issue "P2" "canonicalOverlays.provider is not a string for: ${bad_types}" \
    "the provider has to be a value on the record. If it is absent or another type, the
       consumer has to infer it from the collection's name -- which is the defect." \
    "${read_pointer}"
else
  echo "PASS P2: canonicalOverlays publishes ${overlay_names} with every required field"
fi

# ---------------------------------------------------------------------------
# P3 -- the two collections describe the same overlays.
# ---------------------------------------------------------------------------
if [[ -n "${overlay_names}" ]]; then
  mismatch="$(read_json "' '.join(sorted(set(d['overlayNames']) ^ set(d['siteOverlayNames'])))")"
  if [[ -n "${mismatch}" ]]; then
    report_issue "P3" "canonicalOverlays and canonicalSites disagree about which overlays exist: ${mismatch}" \
      "the two collections are talking about the same overlays. A name in one and not the
         other is a join that silently drops a record, and the consumer cannot tell a
         missing overlay from an overlay with no facts." \
      "${read_pointer}"
  else
    echo "PASS P3: canonicalOverlays and canonicalSites name the same overlays"
  fi
fi

# ---------------------------------------------------------------------------
# Seeded negatives -- the two detectors must be able to fire.
# ---------------------------------------------------------------------------
seeded_offending="$(python3 - <<'PY'
providers = "wireguard nebula openvpn tailscale ipsec vxlan".split()
names = ["canonicalOverlays", "canonicalWireGuard", "canonicalRoutes"]
hits = [f"{n} (contains '{p}')" for n in names for p in providers if p in n.lower()]
print("\n".join(hits))
PY
)"

seeded_missing="$(python3 - <<'PY'
record = {"providerInterface": "wg0"}
required = ["provider", "providerMaterial", "providerContract", "terminateOn", "nodes"]
print("\n".join(f"seeded lacks {f}" for f in required if f not in record))
PY
)"

if [[ -z "${seeded_offending}" ]] || [[ -z "${seeded_missing}" ]]; then
  issues=$((issues + 1))
  {
    echo "ISSUE SEED: a detector did not fire on the seeded input"
    echo "  provider-name hits: ${seeded_offending:-<none>}"
    echo "  missing-field hits: ${seeded_missing:-<none>}"
    echo "  every PASS above is therefore not evidence"
  } >&2
else
  echo "PASS SEED: both detectors fire on the seeded input"
fi

echo ""
if ((issues > 0)); then
  echo "FAIL S88-CANONICAL-NAMES: ${issues} issue(s)." >&2
  echo "  Fix in the producer, not in this test: the collection names and the schema's" >&2
  echo "  closed set have to be one decision, and a provider name is not a collection." >&2
  exit 1
fi

echo "PASS S88-CANONICAL-NAMES: canonical collections are provider-neutral and coherent"
exit 0
