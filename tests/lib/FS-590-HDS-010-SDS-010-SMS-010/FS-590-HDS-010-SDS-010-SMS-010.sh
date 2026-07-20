#!/usr/bin/env bash
# GAMP-ID: FS-590-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

nix eval --impure --expr '
let
  flake = builtins.getFlake (toString '"${repo_root}"');
  system = builtins.currentSystem;
  pkgs = import flake.inputs.nixpkgs { inherit system; };
  helpers = import '"${repo_root}"'/lib/contract.nix { lib = pkgs.lib; };
  failInventory = path: message:
    throw "inventory contract failure: ${path}: ${message}";
  mdns = import '"${repo_root}"'/src/cpm/Unit/runtime-services/mdns.nix {
    lib = pkgs.lib;
    inherit helpers failInventory;
  };

  normalize = value:
    mdns.normalizeMdnsService "inventory.realization.nodes.access-runtime.services" value;

  relationship = {
    id = "tenant-a-printer-mdns";
    requesterScope = "tenant-a";
    responderScope = "printer-net";
    advertisedService = "printer-01";
    serviceType = "_ipp._tcp";
    discoveryProtocol = "mdns";
    direction = "requester-to-responder";
    boundary = "reflector";
    allowedAdvertisementData = {
      hostName = "printer-01.local";
      addresses = [ "192.0.2.50" ];
      txt = [ "rp=printers/printer-01" ];
    };
  };

  valid = normalize {
    discoveryPolicy.relationships = [ relationship ];
  };

  expectFailure = label: value:
    let attempt = builtins.tryEval (builtins.deepSeq (normalize value) true);
    in
    if attempt.success then
      throw "FS-590 accepted invalid mDNS discovery policy for ${label}"
    else
      true;
in
  valid.reflector
  && valid.allowInterfaces == [ "tenant-a" "printer-net" ]
  && valid.discoveryPolicy.defaultDecision == "deny-unmodeled-visibility"
  && valid.discoveryPolicy.relationships == [ relationship ]
  && valid.discoveryRelationships == [ relationship ]
  && expectFailure "legacy-reflector-without-relationship" {
    reflector = true;
    allowInterfaces = [ "tenant-a" "printer-net" ];
  }
  && expectFailure "missing-requester-scope" {
    discoveryPolicy.relationships = [ (builtins.removeAttrs relationship [ "requesterScope" ]) ];
  }
  && expectFailure "missing-responder-scope" {
    discoveryPolicy.relationships = [ (builtins.removeAttrs relationship [ "responderScope" ]) ];
  }
  && expectFailure "missing-advertisement-data" {
    discoveryPolicy.relationships = [ (builtins.removeAttrs relationship [ "allowedAdvertisementData" ]) ];
  }
  && expectFailure "empty-advertisement-data" {
    discoveryPolicy.relationships = [ (relationship // { allowedAdvertisementData = { }; }) ];
  }
' | grep -qx true

echo "PASS fs590-discovery-policy-contract"
