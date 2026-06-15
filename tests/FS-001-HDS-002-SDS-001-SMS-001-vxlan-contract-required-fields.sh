#!/usr/bin/env bash
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-002-SMS-001-001
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-002-SMS-001-CMC-001-001
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-002-SMS-001-002
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-002-SMS-001-CMC-001-002
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-002-SMS-001-003
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-002-SMS-001-CMC-001-003
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-002-SMS-001-004
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-002-SMS-001-CMC-001-004
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-002-SMS-001-005
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-002-SMS-001-CMC-001-005
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-002-SMS-001-006
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-002-SMS-001-CMC-001-006
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-003-SMS-001-001
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-003-SMS-001-CMC-001-001
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-003-SMS-001-002
# GAMP-ID: USR-OVERLAY-001-FS-001-HDS-002-SDS-001-003-SMS-001-CMC-001-002
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

nix eval --impure --expr '
let
  helpers = import '"${repo_root}"'/lib/contract.nix { };
  goodVxlan = {
    vni = 11001;
    localEndpoint = "192.0.2.10";
    remoteEndpoint = "192.0.2.20";
    underlayInterface = "wan0";
    mtu = 1450;
    bridgeAttachment.bridge = "br-vxlan-test";
  };

  mkInventory = vxlan: {
    deployment.hosts.vxlan-host.bridgeNetworks."br-vxlan-test" = { };
    realization.nodes.vxlan-runtime = {
      host = "vxlan-host";
      platform = "linux";
      logicalNode = {
        enterprise = "acme";
        site = "ams";
        name = "vxlan-node";
      };
      ports.vxlan-lan = {
        logicalInterface = "tenant-client";
        interface.name = "vxlan0";
        inherit vxlan;
      };
    };
  };

  normalizePort = vxlan:
    (import '"${repo_root}"'/src/cpm/realization-index.nix {
      inherit helpers;
      inventory = mkInventory vxlan;
    }).targetDefs.vxlan-runtime.portBindings.portDefs.vxlan-lan;

  normalize = vxlan:
    (normalizePort vxlan).vxlan;

  expectFailure = label: vxlan:
    let
      attempt = builtins.tryEval (builtins.deepSeq (normalize vxlan) true);
    in
    if attempt.success then
      throw "vxlan contract accepted incomplete input for ${label}"
    else
      true;

  normalizedPort = normalizePort goodVxlan;
  normalized = normalizedPort.vxlan;
in
  normalized.vni == 11001
  && normalized.localEndpoint == "192.0.2.10"
  && normalized.remoteEndpoint == "192.0.2.20"
  && normalized.underlayInterface == "wan0"
  && normalized.mtu == 1450
  && normalized.bridgeAttachment.bridge == "br-vxlan-test"
  && !(normalizedPort ? interfaceAddr4)
  && !(normalizedPort ? interfaceAddr6)
  && !(normalized ? clientGua)
  && !(normalized ? delegatedPrefixAuthority)
  && !(normalized ? delegatedPrefixes)
  && !(normalized ? routedPrefixes)
  && expectFailure "vni" (builtins.removeAttrs goodVxlan [ "vni" ])
  && expectFailure "localEndpoint" (builtins.removeAttrs goodVxlan [ "localEndpoint" ])
  && expectFailure "remoteEndpoint" (builtins.removeAttrs goodVxlan [ "remoteEndpoint" ])
  && expectFailure "underlayInterface" (builtins.removeAttrs goodVxlan [ "underlayInterface" ])
  && expectFailure "mtu" (builtins.removeAttrs goodVxlan [ "mtu" ])
  && expectFailure "bridgeAttachment" (builtins.removeAttrs goodVxlan [ "bridgeAttachment" ])
' | grep -qx true

echo "PASS vxlan-contract-required-fields"
