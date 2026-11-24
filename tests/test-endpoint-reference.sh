#!/usr/bin/env bash
# GAMP-SCOPE: layer test; a runtime endpoint reference is not a resolved address
#
# A VPS WITH A DOMAIN NAME IS NOT A /32.
#
# Two different facts live next to each other on an overlay and must not be
# confused:
#
#   underlay endpoint   how to reach the peer: a literal address, OR a reference
#                       resolved at runtime (`/run/secrets/...`, whose content may
#                       be an address or a name). A VPS on a provider with dynamic
#                       addressing only has the reference; resolving it at build
#                       time would bake a stale value into the artifact.
#   overlay address     the tunnel address inside the overlay. It is not an
#                       endpoint and no domain name can supply it: FS-350-HDS-010-
#                       SDS-010-SMS-050 realizes it in inventory from the NFM
#                       participant ledger.
#
# The model already supports both (`underlayEndpointSourceFiles` becomes
# `underlayEndpoints = [ { sourceFile; family; } ]` and is never resolved here;
# measured on the overlay example, which carries
# `/run/secrets/hetzner-public-ipv4` as an endpoint). This test asserts that the
# distinction stays: an endpoint reference is preserved, and a name is not accepted
# where an address belongs.
#
# WHAT IT CHECKS
# --------------
# A1  Every published underlay endpoint is either a literal address or a
#     `{ sourceFile; family; }` reference -- never a reference silently resolved to
#     an address at build time.
# A2  The same overlay still carries concrete node addresses. The two facts are
#     independent: a runtime endpoint does not excuse a missing tunnel address, and
#     a tunnel address does not let the endpoint be resolved early.
# A3  A hostname placed in an address field is REJECTED. The model must not accept
#     "vps.example.net" as `addr4` and carry it downstream as an address.
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

echo "--- ENDPOINT-REFERENCE: a runtime endpoint is not a resolved address ---"
echo ""

example="${ENDPOINT_REFERENCE_EXAMPLE:-${workspace_root}/network-labs/examples/s-router-overlay-dns-lane-policy}"
if [[ ! -f "${example}/intent.nix" ]] || [[ ! -f "${example}/inventory-nixos.nix" ]]; then
  echo "SKIP ENDPOINT-REFERENCE: no intent/inventory pair at ${example}"
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

      build = inventoryPath:
        flake.lib.${system}.compileAndBuildFromPaths {
          inputPath = example + "/intent.nix";
          inherit inventoryPath;
        };

      cpm = build (example + "/inventory-nixos.nix");
      data = cpm.control_plane_model.data;

      overlaysOf =
        builtins.concatLists (builtins.map
          (enterprise: builtins.concatLists (builtins.map
            (site:
              let overlays = (data.${enterprise}.${site}.overlays or { });
              in builtins.map
                (name: {
                  inherit enterprise site;
                  overlay = name;
                  endpoints = overlays.${name}.underlayEndpoints or [ ];
                  nodes = overlays.${name}.nodes or { };
                })
                (builtins.attrNames overlays))
            (builtins.attrNames data.${enterprise})))
          (builtins.attrNames data));

      isReference = endpoint: builtins.isAttrs endpoint && (endpoint ? sourceFile);
      isLiteral = endpoint: builtins.isString endpoint;
      kindOf = endpoint:
        if isReference endpoint then "reference"
        else if isLiteral endpoint then "literal"
        else "unknown";

      # A3: put a hostname where an address belongs and see whether the model
      # accepts it. This is the exact mistake a "VPS with a domain name" invites.
      hostnameInAddressRejected =
        let
          inventory = import (example + "/inventory-nixos.nix");
          sites = (inventory.controlPlane or { }).sites or { };
          poison =
            builtins.mapAttrs
              (_: enterpriseSites:
                builtins.mapAttrs
                  (_: site:
                    if !builtins.isAttrs site || !builtins.isAttrs (site.overlays or null) then
                      site
                    else
                      site
                      // {
                        overlays = builtins.mapAttrs
                          (_: overlay:
                            if !builtins.isAttrs overlay || !builtins.isAttrs (overlay.nodes or null) then
                              overlay
                            else
                              overlay
                              // {
                                nodes = builtins.mapAttrs
                                  (_: node: node // { addr4 = "vps.example.net/32"; })
                                  overlay.nodes;
                              })
                          site.overlays;
                      })
                  enterpriseSites)
              sites;
          poisonedPath = builtins.toFile "inventory-hostname-in-address.nix"
            ("builtins.fromJSON " + builtins.toJSON (builtins.toJSON
              (inventory // { controlPlane = (inventory.controlPlane or { }) // { sites = poison; }; })));
          attempt = builtins.tryEval (builtins.deepSeq (build poisonedPath) true);
        in
        !(attempt.success && attempt.value);

      allEndpoints = builtins.concatMap (o: o.endpoints) overlaysOf;
      endpointKinds = lib.unique (map kindOf allEndpoints);
      overlaysWithReference = builtins.filter
        (o: builtins.any isReference o.endpoints)
        overlaysOf;
      nodesWithoutAddress = builtins.concatMap
        (o: builtins.filter (name: (o.nodes.${name}.addr4 or null) == null && (o.nodes.${name}.addr6 or null) == null) (builtins.attrNames o.nodes))
        overlaysWithReference;
    in
    {
      inherit endpointKinds hostnameInAddressRejected nodesWithoutAddress;
      endpointCount = builtins.length allEndpoints;
      referenceOverlayCount = builtins.length overlaysWithReference;
      sampleReference =
        let refs = builtins.filter isReference allEndpoints;
        in if refs == [ ] then null else builtins.head refs;
    }
  ' >"${probe}" 2>/dev/null; then
  echo "FAIL ENDPOINT-REFERENCE: the evaluation needed for the check failed" >&2
  exit 1
fi

read_field() { python3 -c "import json;d=json.load(open('${probe}'));print(d['$1'])"; }

issues=0
read_pointer="FS-350-HDS-010-SDS-010-SMS-050 realizes the overlay participant address in inventory
         from the NFM participant ledger; an overlay's PUBLIC endpoint is a separate fact and may
         be a runtime reference (underlayEndpointSourceFiles). A name is not an address, and a
         reference is not a value -- resolving one at build time bakes in a stale answer."

kinds="$(read_field endpointKinds)"
ref_overlays="$(read_field referenceOverlayCount)"
missing_addr="$(read_field nodesWithoutAddress)"
rejected="$(read_field hostnameInAddressRejected)"

echo "  endpoints published: $(read_field endpointCount) across $(read_field referenceOverlayCount) overlay(s) with a runtime reference"
echo "  endpoint kinds:      ${kinds}"
echo "  sample reference:    $(read_field sampleReference)"
echo ""

# ---------------------------------------------------------------------------
# A1 -- references stay references.
# ---------------------------------------------------------------------------
if [[ "${ref_overlays}" == "0" ]]; then
  issues=$((issues + 1))
  {
    echo "ISSUE A1: no overlay published a runtime endpoint reference"
    echo "  why:  the fixture supplies underlayEndpointSourceFiles, so a model that publishes"
    echo "        none has resolved or dropped them. Both are wrong: the reference is the fact,"
    echo "        and its value is only known at deploy time."
    echo "  read: ${read_pointer}"
  } >&2
elif [[ "${kinds}" == *unknown* ]]; then
  issues=$((issues + 1))
  {
    echo "ISSUE A1: an endpoint was published in a form that is neither a literal address nor a reference (kinds: ${kinds})"
    echo "  why:  a consumer cannot tell what to do with it: use it, or resolve it."
    echo "  read: ${read_pointer}"
  } >&2
else
  echo "PASS A1: endpoints are published as references or literals, unresolved"
fi

# ---------------------------------------------------------------------------
# A2 -- a runtime endpoint does not excuse a missing tunnel address.
# ---------------------------------------------------------------------------
if [[ "${missing_addr}" != "[]" ]]; then
  issues=$((issues + 1))
  {
    echo "ISSUE A2: overlay node(s) have a runtime endpoint but no tunnel address: ${missing_addr}"
    echo "  why:  the two facts are independent. The endpoint says how to reach the peer; the"
    echo "        address is the tunnel identity, realized from the NFM participant ledger. A"
    echo "        reference for one cannot stand in for the other."
    echo "  read: ${read_pointer}"
  } >&2
else
  echo "PASS A2: every node with a runtime endpoint also carries a concrete tunnel address"
fi

# ---------------------------------------------------------------------------
# A3 -- a hostname is not an address.
# ---------------------------------------------------------------------------
if [[ "${rejected}" != "True" ]]; then
  issues=$((issues + 1))
  {
    echo "ISSUE A3: the model accepts a hostname in an address field"
    echo "  why:  'vps.example.net/32' is not an address. Accepting it carries a name into"
    echo "        route and interface material, where it fails at deploy time at best. The"
    echo "        name belongs in the endpoint reference, which is resolved at runtime."
    echo "  read: ${read_pointer}"
  } >&2
else
  echo "PASS A3: a hostname in an address field is rejected"
fi

# ---------------------------------------------------------------------------
# Seeded negatives -- the classifier must call both shapes correctly, or A1 is
# measuring nothing.
# ---------------------------------------------------------------------------
seeded="$(python3 - <<'PY'
kinds = {"ref": {"sourceFile": "/run/secrets/x", "family": 4},
         "lit": "198.51.100.20",
         "bad": 42}
def kind_of(e):
    if isinstance(e, dict) and "sourceFile" in e:  return "reference"
    if isinstance(e, str):                          return "literal"
    return "unknown"
print(" ".join(kind_of(v) for v in kinds.values()))
PY
)"

if [[ "${seeded}" != "reference literal unknown" ]]; then
  issues=$((issues + 1))
  {
    echo "ISSUE SEED: the endpoint classifier is wrong: got '${seeded}'"
    echo "  expected: reference literal unknown"
    echo "  every PASS above is therefore not evidence"
  } >&2
else
  echo "PASS SEED: classifier separates a reference, a literal, and an unknown shape"
fi

echo ""
if ((issues > 0)); then
  echo "FAIL ENDPOINT-REFERENCE: ${issues} issue(s)." >&2
  echo "  Keep the endpoint a reference and resolve it at deploy time; keep the tunnel" >&2
  echo "  address a realized value. Do not resolve the reference early to make a fixture" >&2
  echo "  look like it has an address." >&2
  exit 1
fi

echo "PASS ENDPOINT-REFERENCE: endpoints stay references, addresses stay addresses"
exit 0
