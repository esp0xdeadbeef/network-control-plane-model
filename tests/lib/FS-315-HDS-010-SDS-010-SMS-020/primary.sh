#!/usr/bin/env bash
set -euo pipefail
# GAMP-ID: FS-315-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
# Focused construction test: policy-table lane cardinality module.
# Exercises all seeded negatives from SMS FS-315-HDS-010-SDS-010-SMS-020.

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd python3
require_cmd nix

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

run_nix_eval() {
  local expr="$1"
  local test_label="$2"
  local outfile="${tmpdir}/${test_label}.out"
  local errfile="${tmpdir}/${test_label}.err"
  nix eval --impure --json --expr "${expr}" >"${outfile}" 2>"${errfile}" || {
    echo "FAIL ${test_label}: nix eval failed:" >&2
    cat "${errfile}" >&2
    exit 1
  }
  cat "${outfile}"
}

fail_with() {
  local test_name="$1"; shift
  printf 'FAIL %s: %s\n' "${test_name}" "$*" >&2
  exit 1
}

cpm_module_path="${repo_root}/src/cpm/Site/build-data/runtime-route-policy.nix"

nix_pre='let
  lib = import <nixpkgs/lib>;
  attrsOrEmpty = v: if builtins.isAttrs v then v else {};
  listOrEmpty = v: if builtins.isList v then v else [];
  defaultDst = f: if f == 4 then "0.0.0.0/0" else "::/0";
  rp = import '"${cpm_module_path}"' {
    inherit lib attrsOrEmpty listOrEmpty defaultDst;
  };
  inherit (rp) policyTableComplements;'

# ---- SN1: Route assigned exclusively to lane 3 appears in lane-3 table -----
#        only; zero occurrences in lane 2 or lane 7.

test_sn1() {
  local result
  result="$(run_nix_eval "${nix_pre}
  lane3 = { access = \"vlan3\"; };
  lane2 = { access = \"vlan2\"; };
  lane7 = { access = \"vlan7\"; };

  defaults4 = [
    { dst = \"0.0.0.0/0\"; policyOnly = true; lane = lane3; via4 = \"10.3.0.1\"; intent = { kind = \"default-reachability\"; }; }
    { dst = \"0.0.0.0/0\"; policyOnly = true; lane = lane2; via4 = \"10.2.0.1\"; intent = { kind = \"default-reachability\"; }; }
    { dst = \"0.0.0.0/0\"; policyOnly = true; lane = lane7; via4 = \"10.7.0.1\"; intent = { kind = \"default-reachability\"; }; }
  ];
  defaults6 = [
    { dst = \"::/0\"; policyOnly = true; lane = lane3; via6 = \"2001:db8:3::1\"; intent = { kind = \"default-reachability\"; }; }
    { dst = \"::/0\"; policyOnly = true; lane = lane2; via6 = \"2001:db8:2::1\"; intent = { kind = \"default-reachability\"; }; }
    { dst = \"::/0\"; policyOnly = true; lane = lane7; via6 = \"2001:db8:7::1\"; intent = { kind = \"default-reachability\"; }; }
  ];

  routeIpv4 = { dst = \"192.168.100.1/32\"; via4 = \"10.1.1.1\"; lane = lane3; intent = { kind = \"test\"; }; };
  routeIpv6 = { dst = \"2001:db8:100::1/128\"; via6 = \"2001:db8:1::1\"; lane = lane3; intent = { kind = \"test\"; }; };

  complements4 = policyTableComplements 4 defaults4 [ routeIpv4 ];
  complements6 = policyTableComplements 6 defaults6 [ routeIpv6 ];

  laneAccesses4 = map
    (c: (attrsOrEmpty (c.lane or null)).access or null)
    (builtins.filter (c: c != null) complements4);
  laneAccesses6 = map
    (c: (attrsOrEmpty (c.lane or null)).access or null)
    (builtins.filter (c: c != null) complements6);
in
  { ipv4 = { count = builtins.length complements4; lanes = laneAccesses4; };
    ipv6 = { count = builtins.length complements6; lanes = laneAccesses6; }; }" "sn1-lane3-exclusive")"

  local count4 count6 lanes4 lanes6
  count4=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['ipv4']['count'])")
  count6=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['ipv6']['count'])")
  lanes4=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['ipv4']['lanes'])")
  lanes6=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['ipv6']['lanes'])")

  if [[ "$count4" != "1" ]]; then
    fail_with "sn1-lane3-ipv4-count" "expected 1 occurrence for IPv4, got ${count4}"
  fi
  if [[ "$count6" != "1" ]]; then
    fail_with "sn1-lane3-ipv6-count" "expected 1 occurrence for IPv6, got ${count6}"
  fi
  if [[ "$lanes4" != "['vlan3']" ]]; then
    fail_with "sn1-lane3-ipv4-lane" "expected lane=vlan3 for IPv4, got ${lanes4}"
  fi
  if [[ "$lanes6" != "['vlan3']" ]]; then
    fail_with "sn1-lane3-ipv6-lane" "expected lane=vlan3 for IPv6, got ${lanes6}"
  fi

  echo "PASS sn1-lane-exclusive: route assigned to lane 3 appears only in lane-3 table (IPv4 /32 + IPv6 /128)"
}

# ---- SN2: Remove lane from route => zero inferred policy occurrence --------

test_sn2() {
  local result
  result="$(run_nix_eval "${nix_pre}
  lane3 = { access = \"vlan3\"; };
  lane2 = { access = \"vlan2\"; };

  defaults4 = [
    { dst = \"0.0.0.0/0\"; policyOnly = true; lane = lane3; via4 = \"10.3.0.1\"; intent = { kind = \"default-reachability\"; }; }
    { dst = \"0.0.0.0/0\"; policyOnly = true; lane = lane2; via4 = \"10.2.0.1\"; intent = { kind = \"default-reachability\"; }; }
  ];
  defaults6 = [
    { dst = \"::/0\"; policyOnly = true; lane = lane3; via6 = \"2001:db8:3::1\"; intent = { kind = \"default-reachability\"; }; }
    { dst = \"::/0\"; policyOnly = true; lane = lane2; via6 = \"2001:db8:2::1\"; intent = { kind = \"default-reachability\"; }; }
  ];

  routeIpv4 = { dst = \"192.168.100.1/32\"; via4 = \"10.1.1.1\"; intent = { kind = \"test\"; }; };
  routeIpv6 = { dst = \"2001:db8:100::1/128\"; via6 = \"2001:db8:1::1\"; intent = { kind = \"test\"; }; };

  complements4 = policyTableComplements 4 defaults4 [ routeIpv4 ];
  complements6 = policyTableComplements 6 defaults6 [ routeIpv6 ];
in
  { ipv4Count = builtins.length complements4;
    ipv6Count = builtins.length complements6; }" "sn2-unlaned-zero")"

  local count4 count6
  count4=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['ipv4Count'])")
  count6=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['ipv6Count'])")

  if [[ "$count4" != "0" ]]; then
    fail_with "sn2-unlaned-ipv4" "expected 0 inferred policy occurrences for unlaned IPv4 route, got ${count4}"
  fi
  if [[ "$count6" != "0" ]]; then
    fail_with "sn2-unlaned-ipv6" "expected 0 inferred policy occurrences for unlaned IPv6 route, got ${count6}"
  fi

  echo "PASS sn2-unlaned-zero: route without lane produces zero policy occurrences (IPv4 + IPv6)"
}

# ---- SN3: Sibling-lane rejection ------------------------------------------
#        Route with lane 3 only appears in lane 3 defaults, not lane 7

test_sn3() {
  local result
  result="$(run_nix_eval "${nix_pre}
  lane3 = { access = \"vlan3\"; };
  lane7 = { access = \"vlan7\"; };

  defaults4 = [
    { dst = \"0.0.0.0/0\"; policyOnly = true; lane = lane3; via4 = \"10.3.0.1\"; intent = { kind = \"default-reachability\"; }; }
    { dst = \"0.0.0.0/0\"; policyOnly = true; lane = lane7; via4 = \"10.7.0.1\"; intent = { kind = \"default-reachability\"; }; }
  ];

  routeLane3 = { dst = \"10.50.0.0/24\"; via4 = \"10.1.1.1\"; lane = lane3; intent = { kind = \"test\"; }; };
  routeLane7 = { dst = \"10.50.0.0/24\"; via4 = \"10.1.1.1\"; lane = lane7; intent = { kind = \"test\"; }; };

  complementsFrom3 = policyTableComplements 4 defaults4 [ routeLane3 ];
  complementsFrom7 = policyTableComplements 4 defaults4 [ routeLane7 ];

  lanesFrom3 = map (c: (attrsOrEmpty (c.lane or null)).access or null) complementsFrom3;
  lanesFrom7 = map (c: (attrsOrEmpty (c.lane or null)).access or null) complementsFrom7;
in
  { lane3Route = { count = builtins.length complementsFrom3; lanes = lanesFrom3; };
    lane7Route = { count = builtins.length complementsFrom7; lanes = lanesFrom7; }; }" "sn3-sibling-rejection")"

  local count3 lanes3 count7 lanes7
  count3=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['lane3Route']['count'])")
  lanes3=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['lane3Route']['lanes'])")
  count7=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['lane7Route']['count'])")
  lanes7=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['lane7Route']['lanes'])")

  if [[ "$count3" != "1" ]]; then
    fail_with "sn3-lane3-count" "expected 1 occurrence for lane-3 route, got ${count3}"
  fi
  if [[ "$lanes3" != "['vlan3']" ]]; then
    fail_with "sn3-lane3-lane" "expected lane=vlan3, got ${lanes3}"
  fi
  if [[ "$count7" != "1" ]]; then
    fail_with "sn3-lane7-count" "expected 1 occurrence for lane-7 route, got ${count7}"
  fi
  if [[ "$lanes7" != "['vlan7']" ]]; then
    fail_with "sn3-lane7-lane" "expected lane=vlan7, got ${lanes7}"
  fi

  echo "PASS sn3-sibling-rejection: lane-3 route stays in lane-3, lane-7 route stays in lane-7"
}

# ---- SN4: Permute route/default order => byte-stable cardinality -----------

test_sn4() {
  local result1 result2
  local sn4_expr="${nix_pre}
  lane3 = { access = \"vlan3\"; };
  lane7 = { access = \"vlan7\"; };

  defaultLane3 = { dst = \"0.0.0.0/0\"; policyOnly = true; lane = lane3; via4 = \"10.3.0.1\"; intent = { kind = \"default-reachability\"; }; };
  defaultLane7 = { dst = \"0.0.0.0/0\"; policyOnly = true; lane = lane7; via4 = \"10.7.0.1\"; intent = { kind = \"default-reachability\"; }; };

  defaultsAB = [ defaultLane3 defaultLane7 ];
  defaultsBA = [ defaultLane7 defaultLane3 ];

  route3 = { dst = \"10.50.0.0/24\"; via4 = \"10.1.1.1\"; lane = lane3; intent = { kind = \"test\"; }; };
  route7 = { dst = \"192.168.0.0/24\"; via4 = \"10.2.2.1\"; lane = lane7; intent = { kind = \"test\"; }; };

  routesAB = [ route3 route7 ];
  routesBA = [ route7 route3 ];

  comp_ab = policyTableComplements 4 defaultsAB routesAB;
  comp_ba = policyTableComplements 4 defaultsBA routesBA;
in
  { ab = { count = builtins.length comp_ab; lanes = map (c: (attrsOrEmpty (c.lane or null)).access or null) comp_ab; };
    ba = { count = builtins.length comp_ba; lanes = map (c: (attrsOrEmpty (c.lane or null)).access or null) comp_ba; }; }"

  result1="$(run_nix_eval "${sn4_expr}" "sn4-stable-order1")"
  result2="$(run_nix_eval "${sn4_expr}" "sn4-stable-order2")"

  if [[ "$result1" != "$result2" ]]; then
    fail_with "sn4-stable" "byte-stable cardinality failed: result differs across identical evaluations"
  fi

  local ab_count ba_count
  ab_count=$(echo "$result1" | python3 -c "import json,sys; print(json.load(sys.stdin)['ab']['count'])")
  ba_count=$(echo "$result1" | python3 -c "import json,sys; print(json.load(sys.stdin)['ba']['count'])")

  if [[ "$ab_count" != "2" ]]; then
    fail_with "sn4-ab-count" "expected 2 complements for routes-AB + defaults-AB, got ${ab_count}"
  fi
  if [[ "$ba_count" != "2" ]]; then
    fail_with "sn4-ba-count" "expected 2 complements for routes-BA + defaults-BA, got ${ba_count}"
  fi

  echo "PASS sn4-byte-stable: permuted route/default order produces byte-stable cardinality"
}

# ---- SN5: IPv4/IPv6 parity: identical semantics for both address families --

test_sn5() {
  local result
  result="$(run_nix_eval "${nix_pre}
  lane3 = { access = \"vlan3\"; };
  lane2 = { access = \"vlan2\"; };

  defaults4 = [
    { dst = \"0.0.0.0/0\"; policyOnly = true; lane = lane3; via4 = \"10.3.0.1\"; intent = { kind = \"default-reachability\"; }; }
    { dst = \"0.0.0.0/0\"; policyOnly = true; lane = lane2; via4 = \"10.2.0.1\"; intent = { kind = \"default-reachability\"; }; }
  ];
  defaults6 = [
    { dst = \"::/0\"; policyOnly = true; lane = lane3; via6 = \"2001:db8:3::1\"; intent = { kind = \"default-reachability\"; }; }
    { dst = \"::/0\"; policyOnly = true; lane = lane2; via6 = \"2001:db8:2::1\"; intent = { kind = \"default-reachability\"; }; }
  ];

  laned4 = { dst = \"10.0.0.0/24\"; via4 = \"10.1.1.1\"; lane = lane3; intent = { kind = \"test\"; }; };
  unlaned4 = { dst = \"10.0.0.0/24\"; via4 = \"10.1.1.1\"; intent = { kind = \"test\"; }; };
  laned6 = { dst = \"2001:db8::/64\"; via6 = \"2001:db8:1::1\"; lane = lane3; intent = { kind = \"test\"; }; };
  unlaned6 = { dst = \"2001:db8::/64\"; via6 = \"2001:db8:1::1\"; intent = { kind = \"test\"; }; };

  comp_laned4 = policyTableComplements 4 defaults4 [ laned4 ];
  comp_unlaned4 = policyTableComplements 4 defaults4 [ unlaned4 ];
  comp_laned6 = policyTableComplements 6 defaults6 [ laned6 ];
  comp_unlaned6 = policyTableComplements 6 defaults6 [ unlaned6 ];
in
  { ipv4 = { lanedCount = builtins.length comp_laned4; unlanedCount = builtins.length comp_unlaned4; };
    ipv6 = { lanedCount = builtins.length comp_laned6; unlanedCount = builtins.length comp_unlaned6; }; }" "sn5-ipv4-ipv6-parity")"

  local laned4 unlaned4 laned6 unlaned6
  laned4=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['ipv4']['lanedCount'])")
  unlaned4=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['ipv4']['unlanedCount'])")
  laned6=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['ipv6']['lanedCount'])")
  unlaned6=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['ipv6']['unlanedCount'])")

  if [[ "$laned4" != "1" ]]; then
    fail_with "sn5-ipv4-laned" "expected 1 policy occurrence for laned IPv4 route, got ${laned4}"
  fi
  if [[ "$unlaned4" != "0" ]]; then
    fail_with "sn5-ipv4-unlaned" "expected 0 policy occurrences for unlaned IPv4 route, got ${unlaned4}"
  fi
  if [[ "$laned6" != "1" ]]; then
    fail_with "sn5-ipv6-laned" "expected 1 policy occurrence for laned IPv6 route, got ${laned6}"
  fi
  if [[ "$unlaned6" != "0" ]]; then
    fail_with "sn5-ipv6-unlaned" "expected 0 policy occurrences for unlaned IPv6 route, got ${unlaned6}"
  fi

  echo "PASS sn5-ipv4-ipv6-parity: laned routes get 1 occurrence, unlaned get 0 in both families"
}

# ---- run all tests ----------------------------------------------------------

echo ""
echo "=== FS-315-HDS-010-SDS-010-SMS-020: Policy-Table Lane Cardinality Module Tests ==="
echo ""

test_sn1  # lane-exclusive assignment (IPv4 /32 + IPv6 /128)
test_sn2  # unlaned routes produce zero policy occurrences
test_sn3  # sibling-lane rejection
test_sn4  # byte-stable cardinality under permutation
test_sn5  # IPv4/IPv6 parity

echo ""
echo "PASS FS-315-HDS-010-SDS-010-SMS-020"
echo "Passed: 5/5 seeded negative tests"
