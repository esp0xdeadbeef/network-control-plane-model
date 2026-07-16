{ laneAccess
, sourcePrefixesForInterface
, sourcePrefixesReachableVia
, sourcePrefixesWithRouteVia
, hasDefaultRoute
, hasAnyRuntimeOriginRoute
, sourcePrefixesAllowedToInterface
, uniqueSourcePrefixes
, withSourcePrefixes
, selectorRuntimeRuleAudit ? null
,
}:

{ runtimeOriginSourcePrefixes
, interfaces
, isIngressIface ? (_: true)
, isDefaultIface ? (_: true)
,
}:
let
  defaultIfaces = builtins.filter (iface: isDefaultIface iface && hasDefaultRoute iface) interfaces;
  ingressIfaces = builtins.filter
    (
      iface:
      isIngressIface iface
      && (
        hasDefaultRoute iface
        || sourcePrefixesForInterface runtimeOriginSourcePrefixes iface != [ ]
        || hasAnyRuntimeOriginRoute runtimeOriginSourcePrefixes iface
        || sourcePrefixesWithRouteVia runtimeOriginSourcePrefixes iface != [ ]
      )
    )
    interfaces;
  sourceScopeFor =
    iface:
    let
      laneScope = sourcePrefixesForInterface runtimeOriginSourcePrefixes iface;
      localScope = sourcePrefixesReachableVia laneScope iface;
      routedPeerScope = sourcePrefixesWithRouteVia runtimeOriginSourcePrefixes iface;
      combinedScope = uniqueSourcePrefixes (laneScope ++ routedPeerScope);
    in
    if localScope != [ ] then localScope else combinedScope;
in
builtins.concatLists (
  map
    (
      fromIface:
      let
        sourcePrefixes = sourceScopeFor fromIface;
        fromAccess = laneAccess fromIface;
        defaultIfacesForIngress =
          let
            sameAccessDefaults = builtins.filter
              (
                toIface: fromAccess != null && laneAccess toIface == fromAccess
              )
              defaultIfaces;
          in
          if sameAccessDefaults != [ ] then sameAccessDefaults else defaultIfaces;
      in
      if sourcePrefixes == [ ] then
        [ ]
      else
        builtins.concatMap
          (
            toIface:
            let
              egressPrefixes = sourcePrefixesAllowedToInterface sourcePrefixes toIface;
            in
            if egressPrefixes == [ ] then
              [ ]
            else
              [
                (withSourcePrefixes
                  ({
                    action = "accept";
                    relationId = "runtime-origin-egress";
                    comment = "runtime-origin-egress";
                    trafficType = "any";
                    direction = "selector-default-egress";
                    priority = 19;
                    intent = {
                      kind = "runtime-origin-egress";
                      source = "loopback-runtime-identity";
                      stage = "selector-default-egress";
                    };
                    fromInterface = fromIface.runtimeIfName;
                    toInterface = toIface.runtimeIfName;
                    applyTcpMssClamp = false;
                  } // (
                    if selectorRuntimeRuleAudit == null then
                      { }
                    else
                      selectorRuntimeRuleAudit {
                        relationId = "runtime-origin-egress";
                        direction = "selector-default-egress";
                        fromIface = fromIface;
                        toIface = toIface;
                        decomposed = true;
                        sourcePrefixes = egressPrefixes;
                      }
                  ))
                  egressPrefixes)
              ]
          )
          (builtins.filter (toIface: toIface.runtimeIfName != fromIface.runtimeIfName) defaultIfacesForIngress)
    )
    ingressIfaces
)
