#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-OVERLAY-DNS-RETURN-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
output_json="${tmp_dir}/output.json"

nix flake archive --json "path:${repo_root}" > "${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labsPath = archived.inputs."network-labs".path or null;
    in
      if labsPath == null then throw "example-overlay-dns-return-table: missing network-labs input" else labsPath
  '
)"

(
  cd "${repo_root}"
  nix run .#compile-and-build-control-plane-model -- \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
    "${output_json}" >/dev/null
)

# FS-315: a route's policy-table presence is its modeled lane relation.  The
# overlay peer prefix is reachable over the east-west overlay; the DMZ access's
# return path to that prefix is the lane-scoped policy-only default on the DMZ
# east-west lane (reason policy-derived-default, via the overlay peer).  The
# prefix must NOT be fanned out as a per-prefix complement copied into sibling
# policy lanes, which is the defect FS-315 forbids.
jq -e '
  .control_plane_model.data.esp0xdeadbeef."site-c".runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector"
    .effectiveRuntimeRealization.interfaces as $ifaces
  | ($ifaces."p2p-c-router-policy-c-router-upstream-selector--access-c-router-access-dmz--uplink-east-west".routes.ipv4) as $dmzEw
  | ($ifaces."p2p-c-router-nebula-core-c-router-upstream-selector".routes.ipv4) as $nebulaCore
  # The DMZ east-west lane carries the lane-scoped policy-only default toward
  # the overlay peer: that is the modeled return path for overlay-ingress DNS
  # replies to the remote prefix.
  | (any($dmzEw[]?;
        .dst == "0.0.0.0/0"
        and .policyOnly == true
        and .reason == "policy-derived-default"
        and .lane.access == "c-router-access-dmz"
        and .lane.uplink == "east-west"
        and (.via4 // "") != ""))
    # FS-315: no unlaned route may be copied into a sibling policy lane.
    and ([ ($dmzEw + $nebulaCore)[]?
           | select(.policyTableComplement == true and (.lane.access // null) == null)
         ] | length == 0)
' "${output_json}" >/dev/null || {
  cat >&2 <<'EOF'
FAIL example-overlay-dns-return-table

CPM must give the Site-C DMZ access's east-west lane a lane-scoped policy-only
return default toward the overlay peer, so replies from the DMZ DNS service to
the remote hostile prefix return through the Nebula core interface in the
east-west DMZ lane.  A per-prefix complement must not be copied into sibling
policy lanes from an unlaned overlay route (FS-315).
EOF
  jq '
    .control_plane_model.data.esp0xdeadbeef."site-c".runtimeTargets."esp0xdeadbeef-site-c-c-router-upstream-selector"
      .effectiveRuntimeRealization.interfaces
  ' "${output_json}" >&2
  exit 1
}

echo "PASS example-overlay-dns-return-table"
