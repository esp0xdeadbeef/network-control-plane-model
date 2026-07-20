#!/usr/bin/env bash
# GAMP-ID: FS-720-HDS-010-SDS-020-SMS-020
# GAMP-ID: FS-720-HDS-030-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

labs_root="${NETWORK_LABS_ROOT:-/home/deadbeef/github/network-labs}"
hat_root="${labs_root}/GAMP/HAT/emulated-isp-residential-testnet"

fail() {
  echo "FAIL FS-720 HAT endpoint assignment: $*" >&2
  exit 1
}

[[ -f "${hat_root}/intent.nix" ]] || fail "missing ${hat_root}/intent.nix"
[[ -f "${hat_root}/inventory-nixos.nix" ]] || fail "missing ${hat_root}/inventory-nixos.nix"

result="$(
  nix eval --impure --json --expr "
    let
      flake = builtins.getFlake \"path:${repo_root}\";
      cpm = flake.libBySystem.\${builtins.currentSystem}.compileAndBuildFromPaths {
        inputPath = \"${hat_root}/intent.nix\";
        inventoryPath = \"${hat_root}/inventory-nixos.nix\";
      };
    in {
      names = builtins.attrNames (cpm.endpointAssignment or {});
      sigma = cpm.endpointAssignment.nixos-emulated-sigma or null;
      printer = cpm.endpointAssignment.nixos-printer01 or null;
      streaming = cpm.endpointAssignment.nixos-streaming-test or null;
    }
  "
)"

jq -e '
  (.names | index("nixos-client01") != null)
  and (.names | index("nixos-printer01") != null)
  and (.names | index("nixos-receiver01") != null)
  and (.names | index("nixos-streaming-test") != null)
  and (.names | index("site-a-nixos-printer01") == null)
  and .sigma.mode == "static"
  and .sigma.bridge == "mgmt"
  and .sigma.tenant == "mgmt"
  and .sigma.role == "management"
  and .printer.mode == "static"
  and .printer.bridge == "client"
  and .printer.static.address == "10.20.20.60"
  and .printer.static.gateway4 == "10.20.20.1"
  and .printer.static.address6 == "fd42:dead:beef:20::60"
  and .printer.static.gateway6 == "fd42:dead:beef:20::1"
  and .streaming.bridge == "streaming"
  and .streaming.static.address == "10.20.50.10"
  and .streaming.static.gateway4 == "10.20.50.1"
' <<<"${result}" >/dev/null \
  || {
    echo "${result}" >&2
    fail "HAT endpoint clients were not projected into top-level CPM endpointAssignment"
  }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
mkdir -p "${tmp_dir}/GAMP/HAT" "${tmp_dir}/GAMP"
cp -a "${hat_root}" "${tmp_dir}/GAMP/HAT/emulated-isp-residential-testnet"
cp -a "${labs_root}/GAMP/SAT" "${tmp_dir}/GAMP/SAT"

python3 - "${tmp_dir}/GAMP/HAT/emulated-isp-residential-testnet/inventory-nixos.nix" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = '              gateway4 = "10.20.50.1";\n'
if needle not in source:
    raise SystemExit("missing gateway4 fixture needle")
path.write_text(source.replace(needle, "", 1))
PY

if nix eval --impure --json --expr "
  let
    flake = builtins.getFlake \"path:${repo_root}\";
    cpm = flake.libBySystem.\${builtins.currentSystem}.compileAndBuildFromPaths {
      inputPath = \"${tmp_dir}/GAMP/HAT/emulated-isp-residential-testnet/intent.nix\";
      inventoryPath = \"${tmp_dir}/GAMP/HAT/emulated-isp-residential-testnet/inventory-nixos.nix\";
    };
  in cpm.endpointAssignment.nixos-streaming-test
" >/tmp/fs720-hat-endpoint-assignment-negative.out 2>/tmp/fs720-hat-endpoint-assignment-negative.err; then
  cat /tmp/fs720-hat-endpoint-assignment-negative.out >&2 || true
  fail "missing static gateway4 was accepted"
fi

grep -F "static endpoint nixos-streaming-test has no gateway4" \
  /tmp/fs720-hat-endpoint-assignment-negative.err >/dev/null \
  || {
    cat /tmp/fs720-hat-endpoint-assignment-negative.err >&2 || true
    fail "missing gateway4 diagnostic did not name the endpoint and field"
  }

tmp_role_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}" "${tmp_role_dir}"' EXIT
mkdir -p "${tmp_role_dir}/GAMP/HAT" "${tmp_role_dir}/GAMP"
cp -a "${hat_root}" "${tmp_role_dir}/GAMP/HAT/emulated-isp-residential-testnet"
cp -a "${labs_root}/GAMP/SAT" "${tmp_role_dir}/GAMP/SAT"

python3 - "${tmp_role_dir}/GAMP/HAT/emulated-isp-residential-testnet/inventory-nixos.nix" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = '              role = "management";\n'
if needle not in source:
    raise SystemExit("missing management role fixture needle")
path.write_text(source.replace(needle, "", 1))
PY

role_result="$(
  nix eval --impure --json --expr "
    let
      flake = builtins.getFlake \"path:${repo_root}\";
      cpm = flake.libBySystem.\${builtins.currentSystem}.compileAndBuildFromPaths {
        inputPath = \"${tmp_role_dir}/GAMP/HAT/emulated-isp-residential-testnet/intent.nix\";
        inventoryPath = \"${tmp_role_dir}/GAMP/HAT/emulated-isp-residential-testnet/inventory-nixos.nix\";
      };
    in cpm.endpointAssignment.nixos-emulated-sigma.role or null
  "
)"

[[ "${role_result}" == "null" ]] \
  || fail "CPM inferred management role instead of preserving only explicit source role"

echo "PASS FS-720-HDS-010-SDS-020-SMS-020 HAT endpoint assignment projection"
