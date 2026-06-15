#!/usr/bin/env bash
# GAMP-ID: SMT-CPM-DNS-FORWARDER-CONTRACTS-ALL-ROLES-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-010-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-010-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-010-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-010-SMS-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-011-SMS-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-011-SMS-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-011-SMS-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-011-SMS-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-010-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-010-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-010-SMS-001-CMC-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-010-SMS-001-CMC-001-004
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-011-SMS-001-CMC-001-001
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-011-SMS-001-CMC-001-002
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-011-SMS-001-CMC-001-003
# GAMP-ID: USR-DNS-001-FS-001-HDS-001-SDS-001-011-SMS-001-CMC-001-004
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
cd "${repo_root}"

expr='
let
  flake = builtins.getFlake ("path:" + toString ./.);
  system = builtins.currentSystem;
  pkgs = import flake.inputs.nixpkgs { inherit system; };
  lib = pkgs.lib;
  helpers = import ./src/cpm/cpm-contract-support.nix { inherit lib; };
  common = import ./src/cpm/ControlModule/lib/common.nix { inherit helpers; };
  addDnsContracts = import ./src/cpm/ControlModule/runtime-targets/dns-contracts.nix {
    inherit lib helpers common;
    policyDerivedDnsAllowedClassesForListeners = _listeners: [ ];
    policyDerivedDnsForwardersForListeners = _listeners: [ ];
  };
  target = {
    role = "core";
    logicalNode.name = "core-with-dns-forwarders";
    services.dns = {
      forwarders = [
        "1.1.1.1"
        "fd42:dead:beef:10::1"
      ];
      allowedUpstreamClasses = [ "local-access" ];
      routeContracts = [ ];
      policyMatrix = [ ];
    };
  };
  rendered = addDnsContracts target;
  dns = rendered.services.dns;
  hasForwarderContract = dst:
    builtins.any
      (contract:
        (contract.dst or null) == dst
        && (contract.source or null) == "dns-service")
      (dns.routeContracts or [ ]);
  hasForwarderPolicy = dst:
    builtins.any
      (contract:
        (contract.dst or null) == dst
        && (contract.source or null) == "dns-service")
      (dns.policyMatrix or [ ]);
in
  hasForwarderContract "1.1.1.1"
  && hasForwarderContract "fd42:dead:beef:10::1"
  && hasForwarderPolicy "1.1.1.1"
  && hasForwarderPolicy "fd42:dead:beef:10::1"
  && builtins.elem "explicit-egress-default" (dns.allowedUpstreamClasses or [ ])
  && builtins.elem "explicit-egress-default" (dns.roles.recursion.allowedUpstreamClasses or [ ])
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "${expr}" | grep -qx true; then
  echo "PASS dns-forwarder-route-contracts-all-roles"
else
  echo "FAIL dns-forwarder-route-contracts-all-roles" >&2
  exit 1
fi
