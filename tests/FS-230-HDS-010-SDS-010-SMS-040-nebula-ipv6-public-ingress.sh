#!/usr/bin/env bash
set -euo pipefail
# GAMP-ID: FS-230-HDS-010-SDS-010-SMS-040
# GAMP-SCOPE: software-module-test

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

REPO_ROOT="${repo_root}" nix eval --impure --expr '
  let
    root = builtins.getEnv "REPO_ROOT";
    flake = builtins.getFlake ("path:" + root);
    lib = flake.inputs.nixpkgs.lib;
    ipam = import (root + "/src/cpm/ipam.nix") { inherit lib; };
    helpers = import (root + "/src/cpm/cpm-contract-support.nix") { inherit lib; };
    common = import (root + "/src/cpm/Site/build-data/common.nix") {
      inherit helpers ipam;
      enterpriseRoot = { };
    };
    build = import (root + "/src/cpm/firewall-intent/public-ingress.nix") {
      inherit helpers lib ipam;
    };
    sourceFile = "/run/secrets/lab-dmz-ipv6-prefix";
    runtimePrefix = {
      allocation = "runtime";
      family = "ipv6";
      name = "dmz-public";
      source = "intent-routed-prefix";
      inherit sourceFile;
      delegatedPrefixLength = 48;
      perTenantPrefixLength = 64;
      slot = 7;
    };
    ipv6Authority = {
      sourceScope = "internet";
      targetService = "nebula";
      targetPort = 4242;
      returnBehavior = "stateful-return";
      sourcePreservation = "preserve-source";
      translationMode = "none";
      family = "ipv6";
      tuples = [ { protocol = "udp"; publicPort = 4242; } ];
    };
    relation = {
      id = "allow-wan-to-nebula-ipv6";
      action = "allow";
      from = { kind = "external"; uplinks = [ "wan" ]; };
      to = { kind = "service"; name = "nebula"; };
      publicIngressTupleAuthority = ipv6Authority;
    };
    services = [ {
      name = "nebula";
      providerTenants = [ "dmz" ];
      providerEndpoints = [ {
        name = "nebula-endpoint";
        ipv4 = [ "192.0.2.42" ];
        ipv6 = [ "fd00:7::4242" ];
      } ];
    } ];
    policyEndpointBindings.tenants.dmz.runtimeBindings = [ { logicalNode = "access-dmz"; } ];
    core = {
      role = "core";
      effectiveRuntimeRealization = {
        loopback.addr4 = "10.19.0.3/32";
        interfaces = {
          ppp0 = {
            sourceKind = "pppoe-session";
            runtimeIfName = "ppp0";
            backingRef.name = "wan";
          };
          core-upstream = {
            sourceKind = "p2p";
            runtimeIfName = "ens3";
            addr4 = "10.10.0.6/31";
            addr6 = "fd00:1000::6/127";
            backingRef.lane = { kind = "uplink"; uplink = "wan"; };
            routes.ipv6 = [ runtimePrefix ];
          };
        };
      };
    };
    records = build {
      siteAttrs.communicationContract.relations = [ relation ];
      inherit services policyEndpointBindings;
      interfaceRecords = builtins.attrValues core.effectiveRuntimeRealization.interfaces;
      routedPrefixesByTenant.dmz = [ runtimePrefix ];
      target = core;
      targetName = "core";
    };
    record = builtins.head records;
    routeAugment = import (root + "/src/cpm/ControlModule/runtime-targets/public-ingress-routes.nix") {
      inherit lib common;
    };
    routeIface = runtimeIfName: lane: {
      sourceKind = "p2p";
      inherit runtimeIfName;
      backingRef.lane = lane;
      routes.ipv6 = [ runtimePrefix ];
    };
    runtimeTargets = {
      core = core // { natIntent.publicIngress = [ record ]; };
      upstream = {
        role = "upstream-selector";
        effectiveRuntimeRealization.interfaces = {
          to-policy = routeIface "policy-dmz" { kind = "access-uplink"; access = "access-dmz"; uplink = "wan"; };
          to-core = routeIface "core" { kind = "uplink"; uplink = "wan"; };
        };
      };
      policy = {
        role = "policy";
        effectiveRuntimeRealization.interfaces = {
          to-downstream = routeIface "down-dmz" { kind = "access"; access = "access-dmz"; };
          to-upstream = routeIface "up-dmz" { kind = "access-uplink"; access = "access-dmz"; uplink = "wan"; };
        };
      };
      downstream = {
        role = "downstream-selector";
        effectiveRuntimeRealization.interfaces = {
          to-access = routeIface "access-dmz" { kind = "access-edge"; access = "access-dmz"; };
          to-policy = routeIface "policy-dmz" { kind = "access"; access = "access-dmz"; };
        };
      };
      access = {
        role = "access";
        logicalNode.name = "access-dmz";
        effectiveRuntimeRealization.interfaces = {
          tenant = (routeIface "tenant-dmz" { kind = "tenant"; }) // {
            sourceKind = "tenant";
            backingRef.name = "dmz";
          };
          to-downstream = routeIface "downstream" { kind = "access-edge"; access = "access-dmz"; };
        };
      };
    };
    augmented = routeAugment runtimeTargets;
    rulesFor = name: augmented.${name}.forwardingIntent.rules or [ ];
    exactRuleFor = name: builtins.head (builtins.filter
      (rule: (rule.relationId or null) == relation.id)
      (rulesFor name));
    checks = {
      oneRecord = builtins.length records == 1;
      family = record.family == 6;
      inventoryOwnedBindings =
        record.publicSurface == "wan"
        && record.target.endpoint == "nebula-endpoint";
      noTranslation = record.destinationTranslation == false && record.sourceTranslation.mode == "none";
      exactTuple = record.tupleRecords == [ { protocol = "udp"; publicPort = 4242; targetPort = 4242; } ];
      protectedRuntimeDestination = record.runtimeDestination == {
        sourceClass = "protected";
        source = "intent-routed-prefix";
        sourceFile = sourceFile;
        prefixName = "dmz-public";
        interfaceIdentifier = "0:0:0:0:0:0:0:4242";
        delegatedPrefixLength = 48;
        perTenantPrefixLength = 64;
        slot = 7;
        targetPrefixLength = 128;
      };
      corePath = (exactRuleFor "core").fromInterface == "ppp0" && (exactRuleFor "core").toInterface == "ens3";
      allFiveNodes = builtins.all
        (name:
          let rule = exactRuleFor name;
          in
          rule.matches == [ { family = "ipv6"; proto = "udp"; dports = [ 4242 ]; } ]
          && rule.destinationPrefixes == [ ]
          && rule.destinationRuntimeAddresses == [ record.runtimeDestination ]
          && rule.returnBehavior == "stateful-return"
          && rule.translationMode == "none"
          && rule.sourcePreservation == "preserve-source"
          && rule.destinationTranslation == false)
        [ "core" "upstream" "policy" "downstream" "access" ];
    };
    missingSource = builtins.tryEval (builtins.deepSeq (build {
      siteAttrs.communicationContract.relations = [ relation ];
      inherit services policyEndpointBindings;
      interfaceRecords = builtins.attrValues core.effectiveRuntimeRealization.interfaces;
      routedPrefixesByTenant.dmz = [ ];
      target = core;
      targetName = "core";
    }) true);
    conflictingLegacyBinding = builtins.tryEval (builtins.deepSeq (build {
      siteAttrs.communicationContract.relations = [ (relation // {
        publicIngressTupleAuthority = ipv6Authority // {
          publicSurface = "wrong-uplink";
          targetEndpoint = "wrong-endpoint";
        };
      }) ];
      inherit services policyEndpointBindings;
      interfaceRecords = builtins.attrValues core.effectiveRuntimeRealization.interfaces;
      routedPrefixesByTenant.dmz = [ runtimePrefix ];
      target = core;
      targetName = "core";
    }) true);
    ambiguousInventoryEndpoint = builtins.tryEval (builtins.deepSeq (build {
      siteAttrs.communicationContract.relations = [ relation ];
      services = [ ((builtins.head services) // {
        providerEndpoints = (builtins.head services).providerEndpoints ++ [ {
          name = "second-nebula-endpoint";
          ipv6 = [ "fd00:7::4343" ];
        } ];
      }) ];
      inherit policyEndpointBindings;
      interfaceRecords = builtins.attrValues core.effectiveRuntimeRealization.interfaces;
      routedPrefixesByTenant.dmz = [ runtimePrefix ];
      target = core;
      targetName = "core";
    }) true);
    familyNeutral = build {
      siteAttrs.communicationContract.relations = [ (relation // {
        publicIngressTupleAuthority = builtins.removeAttrs ipv6Authority [ "family" ];
      }) ];
      inherit services policyEndpointBindings;
      interfaceRecords = builtins.attrValues core.effectiveRuntimeRealization.interfaces;
      routedPrefixesByTenant.dmz = [ runtimePrefix ];
      target = core;
      targetName = "core";
    };
    failed = builtins.filter (name: !checks.${name}) (builtins.attrNames checks);
  in
  if failed != [ ] then
    throw ("failed checks: " + builtins.concatStringsSep ", " failed)
  else if missingSource.success then
    throw "missing protected runtime source was accepted"
  else if conflictingLegacyBinding.success then
    throw "conflicting relation-owned surface or endpoint was accepted"
  else if ambiguousInventoryEndpoint.success then
    throw "ambiguous inventory-owned endpoint was accepted"
  else if familyNeutral != [ ] then
    throw "family-neutral no-translation tuple was expanded to IPv6"
  else
    true
' >/dev/null

echo "PASS FS-230-HDS-010-SDS-010-SMS-040: protected Nebula IPv6 public ingress control-plane contract"
