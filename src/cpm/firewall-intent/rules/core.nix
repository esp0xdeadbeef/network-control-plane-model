{ common }:

{ tenantPrefixOwners ? { }
, transitInterfaces
, uplinkInterfaces
, dnsServicePublicEgressRules ? [ ]
,
}:
let
  delegatedOverlayEgress = import ./core-delegated-overlay-egress.nix { inherit tenantPrefixOwners; };

  traceIdFor = iface:
    let
      scope = common.interfaceScope iface;
      ref = scope.backingRef or { };
    in
    if builtins.isString (ref.id or null) && ref.id != "" then
      ref.id
    else if builtins.isString (scope.logicalInterface or null) && scope.logicalInterface != "" then
      scope.logicalInterface
    else
      iface.runtimeIfName;

  originRefFor = iface:
    let
      scope = common.interfaceScope iface;
    in
    {
      backingRef = scope.backingRef or { };
      logicalInterface = scope.logicalInterface or null;
      sourceKind = scope.sourceKind or null;
    };

  coreTransitAudit = fromIface: toIface:
    let
      direction = "core-transit-mesh";
      relationId = "core-transit-mesh--${traceIdFor fromIface}--${traceIdFor toIface}";
    in
    {
      inherit relationId direction;
      comment = relationId;
      trafficType = "any";
      from = common.interfaceScope fromIface;
      to = common.interfaceScope toIface;
      intent = {
        kind = "core-transit-mesh";
        source = "forwarding-model-transit";
        from = originRefFor fromIface;
        to = originRefFor toIface;
      };
      relationCardinality = {
        unit = "core-transit-mesh-rule";
        decomposition = "one-rule-per-core-transit-interface-pair";
        decomposed = true;
      };
    }
    // common.relationHandoff {
      inherit relationId direction fromIface toIface;
      action = "accept";
      policyPoint = "core-transit-mesh";
    };

  reverseRule = transitIface: uplinkIface: {
    action = "accept";
    fromInterface = uplinkIface.runtimeIfName;
    toInterface = transitIface.runtimeIfName;
    applyTcpMssClamp = false;
  };

  uplinkPairRules =
    transitIface: uplinkIface:
    if uplinkIface.sourceKind == "overlay" && delegatedOverlayEgress.exitNodesFor uplinkIface != [ ] then
      delegatedOverlayEgress.rulesFor transitIface uplinkIface ++ [ (reverseRule transitIface uplinkIface) ]
    else
      common.selectorPairRule transitIface uplinkIface;

  meshRules =
    builtins.concatLists (
      builtins.map
        (fromIface:
          builtins.map
            (toIface:
              {
                action = "accept";
                fromInterface = fromIface.runtimeIfName;
                toInterface = toIface.runtimeIfName;
                applyTcpMssClamp = false;
              } // coreTransitAudit fromIface toIface)
            (builtins.filter
              (toIface: toIface.runtimeIfName != fromIface.runtimeIfName)
              transitInterfaces))
        transitInterfaces
    );

  exitRules =
    builtins.concatLists (
      builtins.map
        (transitIface:
          builtins.concatLists (
            builtins.map
              (uplinkIface: uplinkPairRules transitIface uplinkIface)
              uplinkInterfaces
          ))
        transitInterfaces
    );
in
meshRules ++ dnsServicePublicEgressRules ++ exitRules
