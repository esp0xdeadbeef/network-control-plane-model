{ common }:

{ tenantPrefixOwners ? { }
, transitInterfaces
, uplinkInterfaces
,
}:
let
  delegatedOverlayEgress = import ./core-delegated-overlay-egress.nix { inherit tenantPrefixOwners; };

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
              })
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
meshRules ++ exitRules
