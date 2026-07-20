#!/usr/bin/env bash
# GAMP-ID: FS-525-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
cd "$repo_root"

expr='
let
  flake = builtins.getFlake ("path:" + toString ./.);
  system = builtins.currentSystem;
  lib = flake.inputs.nixpkgs.lib;
  labs = flake.inputs.network-labs.outPath;
  built = flake.libBySystem.${system}.compileAndBuildFromPaths {
    inputPath = labs + "/GAMP/SMT/FS-525-HDS-010-SDS-010-SMS-010/intent.nix";
    inventoryPath = labs + "/GAMP/SMT/FS-525-HDS-010-SDS-010-SMS-010/inventory-nixos.nix";
  };
  site = built.control_plane_model.data.mini-smt."FS-525-HDS-010-SDS-010-SMS-010";
  forwardingSite = built.forwardingOut.enterprise.mini-smt.site."FS-525-HDS-010-SDS-010-SMS-010";
  targetFor = logicalName:
    builtins.head (
      builtins.filter
        (target: (target.logicalNode.name or null) == logicalName)
        (builtins.attrValues site.runtimeTargets)
    );
  serviceFor = serviceName:
    builtins.head (builtins.filter (service: service.name == serviceName) site.services);
  stripPrefix = value: builtins.head (builtins.match "([^/]+)/.*" value);
  coreNode = forwardingSite.nodes."core-primary";
  coreLoopback4 = stripPrefix coreNode.loopback.ipv4;
  coreLoopback6 = stripPrefix coreNode.loopback.ipv6;
  access = targetFor "access-dns";
  core = targetFor "core-primary";
  accessDns = access.services.dns;
  accessUpstream = builtins.head accessDns.upstreamResolvers;
  coreDns = core.services.dns;
  coreInterfaces = builtins.attrValues core.effectiveRuntimeRealization.interfaces;
  coreTerminalInterfaces = builtins.filter
    (iface:
      (iface.sourceKind or null) == "p2p"
      && builtins.elem "isp-primary" ((iface.backingRef or { }).uplinks or [ ]))
    coreInterfaces;
  terminalEndpoints = lib.unique (lib.concatMap
    (iface: [ (stripPrefix iface.addr4) (stripPrefix iface.addr6) ])
    coreTerminalInterfaces);
  terminal4 = builtins.head (builtins.filter (address: builtins.match ".*:.*" address == null) terminalEndpoints);
  terminal6 = builtins.head (builtins.filter (address: builtins.match ".*:.*" address != null) terminalEndpoints);
  coreEgressRules = builtins.filter
    (rule: (rule.intent.kind or null) == "dns-service-public-egress")
    (core.forwardingIntent.rules or [ ]);
  coreService = serviceFor "core-dns";
  relation = builtins.head (
    builtins.filter
      (entry: entry.id == "FS-525-HDS-010-SDS-010-SMS-010__access-dns-to-core-dns")
      site.communicationContract.allowedRelations
  );
  relationRules = builtins.concatLists (builtins.map
    (target: builtins.filter
      (rule: (rule.relationId or null) == relation.id)
      (target.forwardingIntent.rules or [ ]))
    (builtins.attrValues site.runtimeTargets));
in
  site.dns == forwardingSite.dns
  && (site.dns.warnings or [ ]) == [ ]
  && coreService.providerEndpoints == [ { name = "core-primary"; ipv4 = [ terminal4 ]; ipv6 = [ terminal6 ]; } ]
  && coreService.preferredUplinks == [ "isp-primary" ]
  && accessUpstream.addresses == [ terminal4 terminal6 ]
  && accessUpstream.service == "core-dns"
  && accessUpstream.node == "core-primary"
  && !(builtins.any
    (address: builtins.elem address [ "1.1.1.1" "9.9.9.9" "2606:4700:4700::1111" "2620:fe::fe" ])
    (accessDns.forwarders or [ ]))
  && accessDns.recursionMode == "forwarding"
  && coreDns.listen == [ terminal4 terminal6 ]
  && !(builtins.elem coreLoopback4 coreDns.listen)
  && !(builtins.elem coreLoopback6 coreDns.listen)
  && (coreDns.forwarders or [ ]) == [ ]
  && coreDns.recursionMode == "iterative"
  && coreDns.egress.uplinks == [ "isp-primary" ]
  && core.runtimeOriginEgress.uplinks == [ "isp-primary" ]
  && core.runtimeOriginEgress.policyRoutingRequired == true
  && core.runtimeOriginEgress.policyRouting == {
    source = "control-plane-model";
    selectedUplink = "isp-primary";
    selectedInterface = "isp-primary";
    runtimeIfName = "wan0";
    tableId = 1002;
    rulePriority = 1002;
    firewallMark = 1002;
  }
  && coreEgressRules != [ ]
  && builtins.all (rule: rule.toInterface == "wan0") coreEgressRules
  && relation.returnBehavior == "symmetric"
  && builtins.any (rule: (rule.direction or null) == "relation-forward") relationRules
  && builtins.any (rule: (rule.direction or null) == "relation-reverse") relationRules
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$expr" | grep -qx true; then
  echo "PASS FS-525 named core resolver binding"
else
  echo "FAIL FS-525 named core resolver binding" >&2
  exit 1
fi

endpoint_alias_expr='
let
  flake = builtins.getFlake ("path:" + toString ./.);
  system = builtins.currentSystem;
  labs = flake.inputs.network-labs.outPath;
  traceId = "FS-525-HDS-010-SDS-010-SMS-010";
  source = import (labs + "/GAMP/SMT/FS-525-HDS-010-SDS-010-SMS-010/intent.nix");
  inventory = import (labs + "/GAMP/SMT/FS-525-HDS-010-SDS-010-SMS-010/inventory-nixos.nix");
  site = source.mini-smt.${traceId};
  accessEndpoint = builtins.head (
    builtins.filter (endpoint: endpoint.name == "access-dns") site.ownership.endpoints
  );
  aliasedService = service:
    if service.name == "access-dns" then
      service // { providers = [ "access-dns-endpoint" ]; }
    else
      service;
  aliasedInput = {
    mini-smt.${traceId} = site // {
      communicationContract = site.communicationContract // {
        services = map aliasedService site.communicationContract.services;
      };
      ownership = site.ownership // {
        endpoints = site.ownership.endpoints ++ [
          (accessEndpoint // { name = "access-dns-endpoint"; })
        ];
      };
    };
  };
  aliasedInventory = inventory // {
    endpoints = {
      access-dns-endpoint = {
        inherit (accessEndpoint) ipv4 ipv6;
      };
    };
  };
  built = flake.libBySystem.${system}.compileAndBuild {
    input = aliasedInput;
    inventory = aliasedInventory;
  };
  runtimeTargets = built.control_plane_model.data.mini-smt.${traceId}.runtimeTargets;
  accessTargets = builtins.filter
    (target: (target.logicalNode.name or null) == "access-dns")
    (builtins.attrValues runtimeTargets);
  accessDns = (builtins.head accessTargets).services.dns;
in
  builtins.length accessTargets == 1
  && builtins.length accessDns.upstreamResolvers == 1
  && (builtins.head accessDns.upstreamResolvers).service == "core-dns"
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$endpoint_alias_expr" | grep -qx true; then
  echo "PASS FS-525 requester provider endpoint binds to one modeled access node"
else
  echo "FAIL FS-525 requester provider endpoint binding" >&2
  exit 1
fi

path_mismatch_expr='
let
  flake = builtins.getFlake ("path:" + toString ./.);
  lib = flake.inputs.nixpkgs.lib;
  common = {
    attrsOrEmpty = value: if builtins.isAttrs value then value else {};
    failForwarding = path: message: throw "${path}: ${message}";
    uniqueStrings = values:
      lib.sort builtins.lessThan (lib.unique (builtins.filter
        (value: builtins.isString value && value != "") values));
  };
  bind = import ./src/cpm/ControlModule/runtime-targets/named-dns-binding.nix {
    inherit lib common;
    enterpriseName = "mini-smt";
    siteName = "path-mismatch";
    sitePath = "mini-smt.path-mismatch";
    inventoryEndpoints = {};
    serviceDefinitions = {
      access-dns = { providers = [ "access" ]; trafficType = "dns"; };
      core-dns = {
        providers = [ "core" ];
        providerNode = "core";
        trafficType = "dns";
        recursionMode = "iterative";
      };
    };
    allowedRelations = [
      {
        id = "access-to-core";
        from = { kind = "service"; name = "access-dns"; };
        to = { kind = "service"; name = "core-dns"; };
        trafficType = "dns";
        action = "allow";
      }
      {
        id = "core-to-isp-a";
        from = { kind = "service"; name = "core-dns"; };
        to = { kind = "external"; uplinks = [ "isp-a" ]; };
        trafficType = "dns";
        action = "allow";
      }
    ];
    siteDns = {
      warnings = [];
      recursive.bindings = [
        {
          advertisedResolver = { kind = "service"; name = "access-dns"; };
          upstreamResolver = { kind = "service"; name = "core-dns"; node = "core"; };
          allowedAddressFamilies = [ "ipv4" "ipv6" ];
          egressSurface = { kind = "external"; uplinks = [ "isp-a" ]; };
          returnBehavior = "symmetric";
        }
      ];
    };
  };
  targets = {
    access = {
      logicalNode.name = "access";
      effectiveRuntimeRealization.interfaces.tenant = {
        sourceKind = "tenant";
        addr4 = "192.0.2.1/24";
        addr6 = "2001:db8:1::1/64";
      };
      services.dns = {};
    };
    core = {
      logicalNode.name = "core";
      effectiveRuntimeRealization = {
        loopback = { addr4 = "198.51.100.1/32"; addr6 = "2001:db8:ffff::1/128"; };
        interfaces.terminal = {
          sourceKind = "p2p";
          addr4 = "198.51.100.2/31";
          addr6 = "2001:db8:fffe::2/127";
          backingRef = {
            id = "modeled-link-b";
            uplinks = [ "isp-b" ];
          };
        };
      };
      services.dns = {};
    };
  };
  result = bind targets;
  warnings = result.access.services.dns.reproducibilityWarnings;
in
  builtins.length warnings == 1
  && (builtins.head warnings).code == "DNS_CORE_ENDPOINT_PATH_MISMATCH"
  && (builtins.head warnings).candidateIds == []
  && !((result.access.services.dns or {}) ? upstreamResolvers)
  && !((result.core.services.dns or {}) ? listen)
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$path_mismatch_expr" | grep -qx true; then
  echo "PASS FS-525 relation endpoint mismatch warns and fails closed"
else
  echo "FAIL FS-525 relation endpoint mismatch warning" >&2
  exit 1
fi

acl_scope_expr='
let
  flake = builtins.getFlake ("path:" + toString ./.);
  lib = flake.inputs.nixpkgs.lib;
  common = {
    attrsOrEmpty = value: if builtins.isAttrs value then value else {};
    failForwarding = path: message: throw "${path}: ${message}";
    ipam = import ./src/cpm/ipam.nix { inherit lib; };
    uniqueStrings = values:
      lib.sort builtins.lessThan (lib.unique (builtins.filter
        (value: builtins.isString value && value != "") values));
  };
  bind = import ./src/cpm/ControlModule/runtime-targets/named-dns-binding.nix {
    inherit lib common;
    enterpriseName = "mini-smt";
    siteName = "acl-scope";
    sitePath = "mini-smt.acl-scope";
    inventoryEndpoints = {};
    serviceDefinitions = {
      access-dns = { providers = [ "access" ]; trafficType = "dns"; };
      core-dns = {
        providers = [ "core" ];
        providerNode = "core";
        trafficType = "dns";
        recursionMode = "iterative";
      };
    };
    allowedRelations = [
      {
        id = "access-to-core";
        from = { kind = "service"; name = "access-dns"; };
        to = { kind = "service"; name = "core-dns"; };
        trafficType = "dns";
        action = "allow";
      }
      {
        id = "client-to-core";
        from = { kind = "tenant"; name = "client"; };
        to = { kind = "service"; name = "core-dns"; };
        trafficType = "dns";
        action = "allow";
      }
      {
        id = "core-to-isp-a";
        from = { kind = "service"; name = "core-dns"; };
        to = { kind = "external"; uplinks = [ "isp-a" ]; };
        trafficType = "dns";
        action = "allow";
      }
    ];
    siteDns = {
      warnings = [];
      recursive.bindings = [
        {
          advertisedResolver = { kind = "service"; name = "access-dns"; };
          upstreamResolver = { kind = "service"; name = "core-dns"; node = "core"; };
          allowedAddressFamilies = [ "ipv4" "ipv6" ];
          egressSurface = { kind = "external"; uplinks = [ "isp-a" ]; };
          returnBehavior = "symmetric";
        }
      ];
    };
  };
  targets = {
    access = {
      logicalNode.name = "access";
      effectiveRuntimeRealization.interfaces.tenant = {
        sourceKind = "tenant";
        addr4 = "192.0.2.1/24";
        addr6 = "2001:db8:1:2fff::1/60";
        backingRef = { kind = "attachment"; name = "client"; };
      };
      services.dns = {};
    };
    core = {
      logicalNode.name = "core";
      effectiveRuntimeRealization.interfaces = {
        terminal = {
          sourceKind = "p2p";
          addr4 = "198.51.100.2/31";
          addr6 = "2001:db8:fffe::2/127";
          backingRef = { id = "modeled-link-a"; uplinks = [ "isp-a" ]; };
        };
        isp-a = {
          sourceKind = "wan";
          runtimeIfName = "wan0";
          backingRef = { id = "uplink-a"; name = "isp-a"; };
          policyRoutingAllocation = {
            source = "control-plane-model";
            tableId = 1002;
            tableRulePriority = 1002;
          };
        };
      };
      services.dns.allowFrom = [ "203.0.113.0/24" ];
    };
  };
  result = bind targets;
in
  result.core.services.dns.allowFrom == [
    "192.0.2.0/24"
    "192.0.2.1/32"
    "2001:db8:1:2ff0:0:0:0:0/60"
    "2001:db8:1:2fff::1/128"
  ]
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$acl_scope_expr" | grep -qx true; then
  echo "PASS FS-525 core ACL is derived only from explicit requester relations"
else
  echo "FAIL FS-525 core requester ACL scope" >&2
  exit 1
fi

egress_warning_expr='
let
  flake = builtins.getFlake ("path:" + toString ./.);
  lib = flake.inputs.nixpkgs.lib;
  common = {
    attrsOrEmpty = value: if builtins.isAttrs value then value else {};
    failForwarding = path: message: throw "${path}: ${message}";
    uniqueStrings = values:
      lib.sort builtins.lessThan (lib.unique (builtins.filter
        (value: builtins.isString value && value != "") values));
  };
  bindFor = selectedUplinks: includeSecondary:
    let
      bind = import ./src/cpm/ControlModule/runtime-targets/named-dns-binding.nix {
        inherit lib common;
        enterpriseName = "mini-smt";
        siteName = "egress-warning";
        sitePath = "mini-smt.egress-warning";
        inventoryEndpoints = {};
        serviceDefinitions = {
          access-dns = { providers = [ "access" ]; trafficType = "dns"; };
          core-dns = {
            providers = [ "core" ];
            providerNode = "core";
            trafficType = "dns";
            recursionMode = "iterative";
          };
        };
        allowedRelations = [
          {
            id = "access-to-core";
            from = { kind = "service"; name = "access-dns"; };
            to = { kind = "service"; name = "core-dns"; };
            trafficType = "dns";
            action = "allow";
          }
          {
            id = "core-to-selected-provider";
            from = { kind = "service"; name = "core-dns"; };
            to = { kind = "external"; uplinks = selectedUplinks; };
            trafficType = "dns";
            action = "allow";
          }
        ];
        siteDns = {
          warnings = [];
          recursive.bindings = [
            {
              advertisedResolver = { kind = "service"; name = "access-dns"; };
              upstreamResolver = { kind = "service"; name = "core-dns"; node = "core"; };
              allowedAddressFamilies = [ "ipv4" "ipv6" ];
              egressSurface = { kind = "external"; uplinks = [ "isp-a" ]; };
              returnBehavior = "symmetric";
            }
          ];
        };
      };
      allocation = tableId: {
        source = "control-plane-model";
        inherit tableId;
        tableRulePriority = tableId;
      };
      targets = {
        access = {
          logicalNode.name = "access";
          effectiveRuntimeRealization.interfaces.tenant = {
            sourceKind = "tenant";
            addr4 = "192.0.2.1/24";
            addr6 = "2001:db8:1::1/64";
          };
          services.dns = {};
        };
        core = {
          logicalNode.name = "core";
          effectiveRuntimeRealization.interfaces = {
            terminal = {
              sourceKind = "p2p";
              addr4 = "198.51.100.2/31";
              addr6 = "2001:db8:fffe::2/127";
              backingRef = { id = "modeled-link-a"; uplinks = [ "isp-a" ]; };
            };
            isp-a = {
              sourceKind = "wan";
              runtimeIfName = "wan0";
              backingRef = { id = "uplink-a"; name = "isp-a"; };
              policyRoutingAllocation = allocation 1002;
            };
          } // lib.optionalAttrs includeSecondary {
            isp-b = {
              sourceKind = "wan";
              runtimeIfName = "wan1";
              backingRef = { id = "uplink-b"; name = "isp-b"; };
              policyRoutingAllocation = allocation 1003;
            };
          };
          services.dns = {};
        };
      };
    in
    bind targets;
  missing = bindFor [] false;
  ambiguous = bindFor [ "isp-b" "isp-a" ] true;
  missingWarning = builtins.head missing.core.services.dns.reproducibilityWarnings;
  ambiguousWarning = builtins.head ambiguous.core.services.dns.reproducibilityWarnings;
in
  missingWarning.code == "DNS_EGRESS_SELECTION_MISSING"
  && missingWarning.disposition == "fail-closed"
  && missingWarning.candidateIds == []
  && !(missing.core ? runtimeOriginEgress)
  && !(missing.access.services.dns ? forwarders)
  && ambiguousWarning.code == "DNS_EGRESS_SELECTION_AMBIGUOUS"
  && ambiguousWarning.disposition == "fail-closed"
  && ambiguousWarning.candidateIds == [ "isp-a" "isp-b" ]
  && !(ambiguous.core ? runtimeOriginEgress)
  && !(ambiguous.access.services.dns ? forwarders)
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$egress_warning_expr" | grep -qx true; then
  echo "PASS FS-525/FS-540 missing and ambiguous DNS egress warn redacted and fail closed"
else
  echo "FAIL FS-525/FS-540 DNS egress warning contract" >&2
  exit 1
fi
