#!/usr/bin/env bash
# GAMP-SCOPE: contract test; overlay provider material has one source of truth
#
# SPECIFICATION REQUIRED: a GAMP row must state the provenance rule for overlay
# provider material. FS-460-HDS-010-SDS-010-SMS-070 is the closest existing chain,
# but it does not own this rule; the rule currently exists only as an error string
# and a comment. Intended owner: the platform GAMP SMS layer, mirrored under
# network-labs/GAMP/SMS/ (the trace-ID tree, not this repository). Do not infer a
# new trace ID from this test.
#
# THE RULE
# --------
#   - network-forwarding-model publishes overlay topology: which overlays exist,
#     `nodes`, `terminateOn`, peer sites, and `provider` as a value.
#   - the inventory supplies provider material: a downloaded profile (addresses,
#     keys, endpoints, contract), preserved verbatim.
#   - network-control-plane-model merges both and publishes one
#     `canonicalOverlays`, with `provider` as a field and not as a collection name.
#   - provenance decides the layer, not the provider. A WireGuard profile
#     downloaded from a commercial provider is inventory. A WireGuard overlay the
#     operator stands up on their own VPS is derivable from intent. Identical
#     fields, opposite sides; only a declared provenance rule separates them, and a
#     rule written in terms of field shapes cannot.
#
# THE VIOLATION THIS TEST PINS
# ----------------------------
# The model states overlay facts twice: once at
# `cpm.data.<enterprise>.<site>.overlays.<name>` (the correct source) and once by
# walking `inventory.controlPlane.sites.<enterprise>.<site>.overlays.<name>`. On
# `network-labs/examples/wireguard-provider-overlay` the second walk publishes an
# empty `wgInventory` while the overlay record carries a provider contract, so a
# projection of the empty walk published nothing and no renderer failed.
#
# This test evaluates the model. It does not grep source text. It asserts:
#   N1  A model whose two paths agree (seeded: every provider-contract overlay gets
#       a runtime interface in the inventory) evaluates successfully.
#   N2  A model whose two paths disagree (seeded: the same inventory with those
#       runtime nodes removed) is rejected by the fail-closed check.
#   N3  The rejection names FS-460-HDS-010-SDS-010-SMS-070 and both paths, so a
#       failure is diagnosable without a debugger.
#   N4  The overlay table prints which path supplied the contract and the runtime
#       interface for every overlay.
set -euo pipefail

if [[ -n "${SMS_TEST_REPO_ROOT:-}" ]]; then
  repo_root="${SMS_TEST_REPO_ROOT}"
else
  repo_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "${repo_root}" ]] || repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
source "${repo_root}/tests/lib/direct-test-guard.sh"

workspace_root="${NETWORK_WORKSPACE_ROOT:-$(cd "${repo_root}/.." && pwd)}"
example="${OVERLAY_PROVENANCE_EXAMPLE:-${workspace_root}/network-labs/examples/wireguard-provider-overlay}"

echo "--- OVERLAY-PROVENANCE: two overlay sources must agree or the model throws ---"
echo ""

if [[ ! -f "${example}/intent.nix" || ! -f "${example}/inventory-nixos.nix" ]]; then
  echo "FAIL OVERLAY-PROVENANCE: no overlay example at ${example}" >&2
  echo "  set OVERLAY_PROVENANCE_EXAMPLE to an intent+inventory pair" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

make_inventory() {
  local mode="$1"
  local output="$2"
  cat >"${output}" <<EOF
let
  base = import (/. + "${example}/inventory-nixos.nix");
  addRuntimeNodes = _name: overlay:
    if builtins.isAttrs (overlay.providerContract or null) then
      overlay
      // {
        runtimeNodes =
          if "${mode}" == "agree" then
            {
              "provenance-probe-node" = {
                service = { interface = "provenance-probe"; };
              };
            }
          else
            { };
      }
    else
      overlay;
in
base
// {
  controlPlane = base.controlPlane
    // {
      sites = builtins.mapAttrs
        (_enterprise: sites:
          builtins.mapAttrs
            (_site: site:
              site
              // {
                overlays = builtins.mapAttrs addRuntimeNodes (site.overlays or { });
              })
            sites)
        base.controlPlane.sites;
    };
}
EOF
}

inventory_agree="${tmp_dir}/inventory-agree.nix"
inventory_disagree="${tmp_dir}/inventory-disagree.nix"
make_inventory agree "${inventory_agree}"
make_inventory disagree "${inventory_disagree}"

probe_expr='
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    inputPath = builtins.getEnv "INPUT_PATH";
    inventoryPath = builtins.getEnv "INVENTORY_PATH";
    flake = builtins.getFlake ("path:" + repoRoot);
    built = flake.lib.x86_64-linux.compileAndBuildFromPaths {
      inherit inputPath inventoryPath;
    };
    cpm = built.control_plane_model;
    inventory = import (/. + inventoryPath);

    runtimeInterface = overlay:
      let
        nodes = builtins.attrValues (overlay.runtimeNodes or { });
        ifaces = builtins.filter (s: builtins.isString s && s != "") (
          map (node: (node.service or { }).interface or null) nodes
        );
      in
      if ifaces == [ ] then null else builtins.head ifaces;

    sourceOf = overlay: {
      provider = overlay.provider or null;
      hasProviderContract = builtins.isAttrs (overlay.providerContract or null);
      runtimeNodeNames = builtins.attrNames (overlay.runtimeNodes or { });
      runtimeInterface = runtimeInterface overlay;
    };

    inventoryEntries =
      builtins.concatLists (
        map
          (enterprise:
            let sites = inventory.controlPlane.sites.${enterprise} or { }; in
            builtins.concatLists (
              map
                (site:
                  let overlays = sites.${site}.overlays or { }; in
                  map
                    (name: {
                      key = "${enterprise}/${site}/${name}";
                      inventory = sourceOf overlays.${name};
                    })
                    (builtins.attrNames overlays))
                (builtins.attrNames sites)))
          (builtins.attrNames inventory.controlPlane.sites));

    modelEntries =
      if result.success then
        builtins.concatLists (
          map
            (enterprise:
              let sites = cpm.data.${enterprise} or { }; in
              builtins.concatLists (
                map
                  (site:
                    let overlays = sites.${site}.overlays or { }; in
                    map
                      (name: {
                        key = "${enterprise}/${site}/${name}";
                        model = sourceOf overlays.${name};
                      })
                      (builtins.attrNames overlays))
                  (builtins.attrNames sites)))
            (builtins.attrNames cpm.data))
      else
        [ ];

    result = builtins.tryEval (builtins.deepSeq cpm.canonicalOverlays true);
  in
  {
    succeeded = result.success;
    inherit modelEntries inventoryEntries;
  }
'

raw_negative_expr='
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    inputPath = builtins.getEnv "INPUT_PATH";
    inventoryPath = builtins.getEnv "INVENTORY_PATH";
    flake = builtins.getFlake ("path:" + repoRoot);
    built = flake.lib.x86_64-linux.compileAndBuildFromPaths {
      inherit inputPath inventoryPath;
    };
  in
  builtins.deepSeq built.control_plane_model.canonicalOverlays true
'

run_probe() {
  local inventory_path="$1"
  local output="$2"
  env \
    REPO_ROOT="${repo_root}" \
    INPUT_PATH="${example}/intent.nix" \
    INVENTORY_PATH="${inventory_path}" \
    nix eval --impure --json --expr "${probe_expr}" >"${output}"
}

positive_json="${tmp_dir}/agree.json"
negative_json="${tmp_dir}/disagree.json"
negative_log="${tmp_dir}/disagree.log"

if ! run_probe "${inventory_agree}" "${positive_json}"; then
  echo "FAIL OVERLAY-PROVENANCE: the agreeing model could not be evaluated" >&2
  exit 1
fi

if ! run_probe "${inventory_disagree}" "${negative_json}"; then
  echo "FAIL OVERLAY-PROVENANCE: the disagreeing model probe did not produce a verdict" >&2
  exit 1
fi

# N3: the same disagreeing model, evaluated without tryEval, must fail with the
# named trace ID and the two paths. This is the message a maintainer will see.
if env \
  REPO_ROOT="${repo_root}" \
  INPUT_PATH="${example}/intent.nix" \
  INVENTORY_PATH="${inventory_disagree}" \
  nix eval --impure --json --expr "${raw_negative_expr}" >/dev/null 2>"${negative_log}"; then
  echo "FAIL OVERLAY-PROVENANCE: the disagreeing model was accepted without throwing" >&2
  exit 1
fi

python3 - "${positive_json}" "${negative_json}" "${negative_log}" <<'PY'
import json
import sys

positive_path, negative_path, log_path = sys.argv[1:4]
positive = json.load(open(positive_path))
negative = json.load(open(negative_path))
log = open(log_path, encoding="utf-8", errors="replace").read()

issues = []


def source_line(label, source):
    contract = "providerContract" if source.get("hasProviderContract") else "-"
    interface = source.get("runtimeInterface") or "-"
    nodes = ",".join(source.get("runtimeNodeNames") or []) or "-"
    provider = source.get("provider") or "-"
    return (
        f"  {label}: provider={provider} contract={contract} "
        f"runtimeNodes={nodes} interface={interface}"
    )


def merged(entries):
    by_key = {}
    for entry in entries:
        by_key.setdefault(entry["key"], {}).update(entry)
    return [by_key[key] for key in sorted(by_key)]


def print_table(name, entries):
    print(f"{name}:")
    if not entries:
        print("  (none)")
        return
    for entry in merged(entries):
        print(f"  overlay {entry['key']}")
        if "model" in entry:
            print(source_line("cpm.data     ", entry["model"]))
        if "inventory" in entry:
            print(source_line("inventory    ", entry["inventory"]))


print_table(
    "AGREEING MODEL (seeded positive)",
    positive.get("modelEntries", []) + positive.get("inventoryEntries", []),
)
print("")
print_table("DISAGREEING MODEL (seeded negative)", negative.get("inventoryEntries", []))
print("")
print("DISAGREEING MODEL rejection:")
print(log.strip())
print("")

if not positive.get("succeeded"):
    issues.append("N1: the model whose two paths agree did not evaluate successfully")
if not positive.get("modelEntries"):
    issues.append("N1: the agreeing model published no overlay records")
if not positive.get("inventoryEntries"):
    issues.append("N1: the agreeing inventory published no overlay records")

positive_merged = merged(
    positive.get("modelEntries", []) + positive.get("inventoryEntries", [])
)
for entry in positive_merged:
    model = entry.get("model") or {}
    inventory = entry.get("inventory") or {}
    if model.get("hasProviderContract") != inventory.get("hasProviderContract"):
        issues.append(
            f"N1: {entry['key']} disagrees about providerContract between the two paths"
        )
    if model.get("runtimeInterface") != inventory.get("runtimeInterface"):
        issues.append(
            f"N1: {entry['key']} disagrees about the runtime interface between the two paths"
        )
    if model.get("hasProviderContract") and not model.get("runtimeInterface"):
        issues.append(
            f"N1: {entry['key']} carries provider material but no runtime interface "
            "in the agreeing model"
        )

if negative.get("succeeded"):
    issues.append(
        "N2: the model whose two paths disagree was accepted; the fail-closed "
        "check did not fire"
    )
if not negative.get("inventoryEntries"):
    issues.append("N4: the disagreeing inventory published no overlay records")

required = [
    "FS-460-HDS-010-SDS-010-SMS-070",
    "carries provider material at cpm.data.",
    "but not at inventory.controlPlane.sites.",
    "canonicalOverlays",
]
missing = [fragment for fragment in required if fragment not in log]
if missing:
    issues.append(
        "N3: the rejection message is missing: " + ", ".join(repr(item) for item in missing)
    )

if issues:
    for issue in issues:
        print(f"ISSUE {issue}", file=sys.stderr)
    sys.exit(1)

print("PASS N1: the agreeing model evaluates and both paths supply the same fields")
print("PASS N2: the disagreeing model is rejected by the fail-closed check")
print("PASS N3: the rejection names FS-460-HDS-010-SDS-010-SMS-070 and both paths")
print("PASS N4: every overlay names the path that supplied each field")
PY

echo ""
echo "PASS OVERLAY-PROVENANCE: overlay provider material has one named source or the model throws"
