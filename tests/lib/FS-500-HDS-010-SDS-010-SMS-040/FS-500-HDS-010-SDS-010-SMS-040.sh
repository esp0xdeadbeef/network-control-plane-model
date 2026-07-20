#!/usr/bin/env bash
# GAMP-ID: FS-500-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
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
      if labsPath == null then throw "FS-500 SMS-040 p2p gateway test: missing network-labs input" else labsPath
  '
)"

(
  cd "${repo_root}"
  nix run .#compile-and-build-control-plane-model -- \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/intent.nix" \
    "${labs_path}/examples/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
    "${output_json}" >/dev/null
)

python3 - "${output_json}" <<'PY'
import ipaddress
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    doc = json.load(fh)

violations = []
data = (doc.get("control_plane_model") or {}).get("data") or {}
for enterprise_name, enterprise in data.items():
    for site_name, site in (enterprise or {}).items():
        targets = (site or {}).get("runtimeTargets") or {}
        for target_name, target in targets.items():
            realization = (target or {}).get("effectiveRuntimeRealization") or {}
            interfaces = realization.get("interfaces") or {}
            for if_key, iface in interfaces.items():
                if (iface or {}).get("sourceKind") != "p2p":
                    continue
                routes = (iface.get("routes") or {})
                runtime_ifname = iface.get("runtimeIfName") or if_key
                for family, via_field, addr_field in (
                    ("ipv4", "via4", "addr4"),
                    ("ipv6", "via6", "addr6"),
                ):
                    addr = iface.get(addr_field)
                    network = None
                    if addr:
                        try:
                            network = ipaddress.ip_interface(addr).network
                        except ValueError:
                            network = None
                    for route in routes.get(family, []) or []:
                        intent = route.get("intent") or {}
                        via = route.get(via_field)
                        if intent.get("kind") not in {
                            "service-dns-reachability",
                            "service-endpoint-reachability",
                        } or not via:
                            continue
                        try:
                            via_addr = ipaddress.ip_address(via)
                        except ValueError:
                            violations.append(
                                f"{enterprise_name}/{site_name}/{target_name}/{runtime_ifname}: "
                                f"{route.get('dst')} has unparsable {via_field}={via}"
                            )
                            continue
                        if network is None or via_addr not in network:
                            violations.append(
                                f"{enterprise_name}/{site_name}/{target_name}/{runtime_ifname}: "
                                f"{route.get('dst')} {via_field}={via} not on {addr_field}={addr}"
                            )

if violations:
    print("FAIL FS-500 SMS-040 DNS service p2p gateways are off-link", file=sys.stderr)
    for violation in violations[:20]:
        print(violation, file=sys.stderr)
    if len(violations) > 20:
        print(f"... {len(violations) - 20} more", file=sys.stderr)
    raise SystemExit(1)
PY

echo "PASS FS-500-HDS-010-SDS-010-SMS-040 dns-service p2p gateways are on-link"
