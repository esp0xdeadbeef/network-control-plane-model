#!/usr/bin/env bash
# GAMP-ID: FS-482-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --no-write-lock-file --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq

flake_input_path() {
  local input_name="$1"
  if [[ "${input_name}" == "network-labs" && -n "${NETWORK_LABS_PATH:-}" ]]; then
    realpath "${NETWORK_LABS_PATH}"
    return
  fi
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

example_root="$(flake_input_path network-labs)/examples/single-wan-bgp"
intent_path="${example_root}/intent.nix"
inventory_path="${example_root}/inventory-nixos.nix"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

compile_paths() {
  local inventory="$1"
  nix eval --no-write-lock-file --impure --json --expr '
    let
      flake = builtins.getFlake "'"path:${repo_root}"'";
    in
      flake.libBySystem."'"${system}"'".compileAndBuildFromPaths {
        inputPath = "'"${intent_path}"'";
        inventoryPath = "'"${inventory}"'";
      }
  '
}

# FS-482: a BGP session is authorized only from the declared session facts, and a
# missing session fact is a closed failure rather than a defaulted session.

# SN4: the baseline BGP model carries the authorized session with peer identity.
baseline_json="${tmp_dir}/baseline.json"
compile_paths "${inventory_path}" >"${baseline_json}"

if ! BASELINE_JSON="${baseline_json}" nix eval --no-write-lock-file --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "BASELINE_JSON"));
    site = data.control_plane_model.data.esp0xdeadbeef."site-a";
    wan = site.routing.uplinks.wan;
  in
    wan.mode == "bgp"
    && builtins.isInt (wan.bgp.peerAsn or null)
    && (wan.bgp ? peerAddr4 || wan.bgp ? peerAddr6)
' | grep -qx true; then
  echo "FAIL role-scoped-session-authorization: the baseline BGP model carries no authorized session with peer identity" >&2
  exit 1
fi

# SN1: a BGP uplink egress with no peerAsn is refused, naming the field. The
# session identity is a modeled fact, not something the model may default.
no_peer_asn="${tmp_dir}/inventory-no-peer-asn.nix"
cat >"${no_peer_asn}" <<EOF
let
  base = import ${inventory_path};
  site = base.controlPlane.sites.esp0xdeadbeef."site-a";
  wan = site.uplinks.wan;
  bgp = builtins.removeAttrs wan.egress.bgp [ "peerAsn" ];
in
base // {
  controlPlane = base.controlPlane // {
    sites = base.controlPlane.sites // {
      esp0xdeadbeef = base.controlPlane.sites.esp0xdeadbeef // {
        "site-a" = site // {
          uplinks = site.uplinks // { wan = wan // { egress = wan.egress // { bgp = bgp; }; }; };
        };
      };
    };
  };
}
EOF

set +e
compile_paths "${no_peer_asn}" >"${tmp_dir}/no-asn.out" 2>"${tmp_dir}/no-asn.err"
asn_rc=$?
set -e

if ((asn_rc == 0)); then
  echo "FAIL role-scoped-session-authorization: a BGP uplink egress with no peerAsn was accepted" >&2
  exit 1
fi

if ! grep -Fq "bgp uplink egress requires integer peerAsn" "${tmp_dir}/no-asn.err"; then
  echo "FAIL role-scoped-session-authorization: the missing peerAsn abort did not name the field" >&2
  cat "${tmp_dir}/no-asn.err" >&2
  exit 1
fi

# SN2: a BGP session with no peer address at all is refused.
no_peer_addr="${tmp_dir}/inventory-no-peer-addr.nix"
cat >"${no_peer_addr}" <<EOF
let
  base = import ${inventory_path};
  site = base.controlPlane.sites.esp0xdeadbeef."site-a";
  wan = site.uplinks.wan;
  bgp = builtins.removeAttrs wan.egress.bgp [ "peerAddr4" "peerAddr6" ];
in
base // {
  controlPlane = base.controlPlane // {
    sites = base.controlPlane.sites // {
      esp0xdeadbeef = base.controlPlane.sites.esp0xdeadbeef // {
        "site-a" = site // {
          uplinks = site.uplinks // { wan = wan // { egress = wan.egress // { bgp = bgp; }; }; };
        };
      };
    };
  };
}
EOF

set +e
compile_paths "${no_peer_addr}" >"${tmp_dir}/no-addr.out" 2>"${tmp_dir}/no-addr.err"
addr_rc=$?
set -e

if ((addr_rc == 0)); then
  echo "FAIL role-scoped-session-authorization: a BGP session with no peer address was accepted" >&2
  exit 1
fi

if ! grep -Fq "bgp uplink egress requires peerAddr4 and/or peerAddr6" "${tmp_dir}/no-addr.err"; then
  echo "FAIL role-scoped-session-authorization: the missing peer address abort did not name the fields" >&2
  cat "${tmp_dir}/no-addr.err" >&2
  exit 1
fi

# SN3: routing.mode = bgp with no site ASN is refused. The site ASN is a session
# fact and must not be defaulted.
no_asn="${tmp_dir}/inventory-no-site-asn.nix"
cat >"${no_asn}" <<EOF
let
  base = import ${inventory_path};
  site = base.controlPlane.sites.esp0xdeadbeef."site-a";
  routing = site.routing // { mode = "bgp"; bgp = builtins.removeAttrs site.routing.bgp [ "asn" ]; };
in
base // {
  controlPlane = base.controlPlane // {
    sites = base.controlPlane.sites // {
      esp0xdeadbeef = base.controlPlane.sites.esp0xdeadbeef // {
        "site-a" = site // { routing = routing; };
      };
    };
  };
}
EOF

set +e
compile_paths "${no_asn}" >"${tmp_dir}/no-site-asn.out" 2>"${tmp_dir}/no-site-asn.err"
site_asn_rc=$?
set -e

if ((site_asn_rc == 0)); then
  echo "FAIL role-scoped-session-authorization: routing.mode = bgp with no site ASN was accepted" >&2
  exit 1
fi

if ! grep -Fq 'routing.bgp.asn is required and must be an integer when routing.mode = "bgp"' \
  "${tmp_dir}/no-site-asn.err"; then
  echo "FAIL role-scoped-session-authorization: the missing site ASN abort did not name the field" >&2
  cat "${tmp_dir}/no-site-asn.err" >&2
  exit 1
fi

echo "PASS role-scoped-session-authorization"
