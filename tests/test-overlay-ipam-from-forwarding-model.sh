#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

nix eval --impure --expr "
let
  lib = import <nixpkgs/lib>;
  helpers = import ${repo_root}/lib/contract.nix { inherit lib; };
  ipam = import ${repo_root}/src/cpm/ipam.nix { inherit lib; };
  common = import ${repo_root}/src/cpm/Site/build-data/common.nix {
    inherit helpers ipam;
    enterpriseRoot = { };
  };
  overlayProvisioning = import ${repo_root}/src/cpm/Site/build-data/overlay-provisioning.nix {
    inherit lib helpers common ipam;
    sitePath = \"forwardingModel.enterprise.acme.site.ams\";
    siteAttrs = {
      overlayReachability.east-west = {
        overlay = \"east-west\";
        terminateOn = [ \"core-nebula\" \"relay-node\" ];
      };
      overlayAddressPools.east-west = {
        ipv4 = {
          prefix = \"100.96.10.0/24\";
          perNodePrefixLength = 32;
          offsetStart = 10;
        };
        ipv6 = {
          prefix = \"fd42:dead:beef:ee::/64\";
          perNodePrefixLength = 128;
          offsetStart = 10;
        };
      };
    };
    siteOverlays.east-west = {
      provider = \"nebula\";
      nodes.core-nebula = {
        addr4 = \"100.96.10.1/32\";
        addr6 = \"fd42:dead:beef:ee::1/128\";
      };
      nodes.relay-node = {
        addr4 = \"100.96.10.11/32\";
        addr6 = \"fd42:dead:beef:ee::b/128\";
      };
    };
  };
  overlay = overlayProvisioning.overlayProvisioning.east-west;
in
  overlay.ipam.ipv4.prefix == \"100.96.10.0/24\"
  && overlay.ipam.ipv6.prefix == \"fd42:dead:beef:ee::/64\"
  && overlay.nodes.core-nebula.addr4 == \"100.96.10.1/32\"
  && overlay.nodes.core-nebula.addr6 == \"fd42:dead:beef:ee::1/128\"
  && overlay.nodes.relay-node.addr4 == \"100.96.10.11/32\"
  && overlay.nodes.relay-node.addr6 == \"fd42:dead:beef:ee::b/128\"
" >/dev/null

echo "PASS overlay-ipam-from-forwarding-model"
