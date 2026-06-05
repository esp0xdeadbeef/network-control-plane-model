#!/usr/bin/env bash
# GAMP-ID: FS-190-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

archive_json="$(mktemp)"
baseline_json="$(mktemp)"
missing_endpoint_inventory="$(mktemp)"
missing_endpoint_json="$(mktemp)"
no_exposure_intent="$(mktemp)"
no_exposure_json="$(mktemp)"
trap 'rm -f "$archive_json" "$baseline_json" "$missing_endpoint_inventory" "$missing_endpoint_json" "$no_exposure_intent" "$no_exposure_json"' EXIT

nix flake archive --json "path:${repo_root}" > "$archive_json"

labs_path="$(
  ARCHIVE_JSON="$archive_json" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
      labsPath = if labs == null then null else labs.path or null;
    in
      if labsPath == null then
        throw "tests: missing archived network-labs input path"
      else
        labsPath
  '
)"

eval_service() {
  local intent_path="$1"
  local inventory_path="$2"
  local output_path="$3"

  REPO_ROOT="$repo_root" \
  INTENT_PATH="$intent_path" \
  INVENTORY_PATH="$inventory_path" \
    nix eval \
      --extra-experimental-features 'nix-command flakes' \
      --impure --json --expr '
        let
          flake = builtins.getFlake ("path:" + builtins.getEnv "REPO_ROOT");
          out = flake.lib.x86_64-linux.compileAndBuildFromPaths {
            inputPath = builtins.getEnv "INTENT_PATH";
            inventoryPath = builtins.getEnv "INVENTORY_PATH";
          };
          site = out.control_plane_model.data.esp0xdeadbeef."site-c";
          service =
            builtins.head (builtins.filter (item: (item.name or null) == "dmz-nebula") site.services);
          target = site.runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector" or { };
          realization = target.effectiveRuntimeRealization or { };
          interfaces = realization.interfaces or { };
          iface = interfaces."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-wan" or { };
          routes = (iface.routes or { }).ipv4 or [ ];
          hasProviderEndpointRoute =
            builtins.any (route: (route.dst or null) == "10.90.10.100") routes;
        in
        {
          inherit service hasProviderEndpointRoute;
        }
      ' > "$output_path"
}

base_intent="${labs_path}/examples/s-router-public-overlay-service/intent.nix"
base_inventory="${labs_path}/examples/s-router-public-overlay-service/inventory-nixos.nix"

eval_service "$base_intent" "$base_inventory" "$baseline_json"

baseline_ok="$(
  jq -r '
    .service.exposureClass == "public-ingress"
    and .service.exposure.class == "public-ingress"
    and .service.exposure.owningScope == {"kind":"service","name":"dmz-nebula"}
    and .service.exposure.classificationSource == "communicationContract.relations"
    and (.service.exposure.notInferredFrom | index("address-ownership") != null)
    and (.service.exposure.notInferredFrom | index("service-existence") != null)
    and (.service.exposure.notInferredFrom | index("route-availability") != null)
    and (.service.exposure.notInferredFrom | index("host-placement") != null)
    and any(.service.exposure.records[]; .relationId == "allow-sitec-wan-to-dmz-nebula" and .exposureClass == "public-ingress" and .sourceKind == "external" and .sourceNames == ["wan"])
    and .hasProviderEndpointRoute == true
  ' "$baseline_json"
)"
if [[ "$baseline_ok" != "true" ]]; then
  echo "FAIL service-exposure-classification: baseline service lacks explicit public-ingress classification" >&2
  jq '.' "$baseline_json" >&2
  exit 1
fi

cat > "$missing_endpoint_inventory" <<EOF
let
  base = import ${base_inventory};
in
base // {
  endpoints = builtins.removeAttrs (base.endpoints or { }) [ "c-router-lighthouse" ];
}
EOF

eval_service "$base_intent" "$missing_endpoint_inventory" "$missing_endpoint_json"

missing_endpoint_ok="$(
  jq -r '
    .service.exposureClass == "public-ingress"
    and .service.exposure.class == "public-ingress"
    and .service.providerEndpoints == []
    and .hasProviderEndpointRoute == false
  ' "$missing_endpoint_json"
)"
if [[ "$missing_endpoint_ok" != "true" ]]; then
  echo "FAIL service-exposure-classification: endpoint addresses or route availability changed exposure classification" >&2
  jq '.' "$missing_endpoint_json" >&2
  exit 1
fi

cat > "$no_exposure_intent" <<EOF
let
  base = import ${base_intent};
  site = base.esp0xdeadbeef.site-c;
  contract = site.communicationContract;
in
base // {
  esp0xdeadbeef = base.esp0xdeadbeef // {
    site-c = site // {
      communicationContract = contract // {
        relations = builtins.filter
          (relation: (relation.id or null) != "allow-sitec-wan-to-dmz-nebula")
          contract.relations;
      };
    };
  };
}
EOF

eval_service "$no_exposure_intent" "$base_inventory" "$no_exposure_json"

no_exposure_ok="$(
  jq -r '
    .service.providers == ["c-router-lighthouse"]
    and (.service.providerEndpoints | length) == 1
    and .service.exposureClass == "unexposed"
    and .service.exposure.class == "unexposed"
    and ([.service.exposure.records[] | select(.relationId == "allow-sitec-wan-to-dmz-nebula")] | length) == 0
    and .hasProviderEndpointRoute == false
  ' "$no_exposure_json"
)"
if [[ "$no_exposure_ok" != "true" ]]; then
  echo "FAIL service-exposure-classification: service existence, provider profile, address ownership, or host placement created exposure without an exposure relation" >&2
  jq '.' "$no_exposure_json" >&2
  exit 1
fi

echo "PASS service-exposure-classification"
