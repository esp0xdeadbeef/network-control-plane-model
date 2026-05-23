{ common, endpointContext, familyRoutes, routeIntent }:

let
  inherit (endpointContext) attrsOrEmpty coreInterfaces policyInterfaces;

in
let
      isStaticIpv4RoutedSource =
        route:
        let
          intent = routeIntent route;
        in
        builtins.isAttrs route
        && builtins.isString (route.dst or null)
        && !(builtins.match ".*:.*" route.dst != null)
        && (route.family or 4) == 4
        && (intent.kind or null) == "overlay-reachability";

      runtimeRoutedPrefixStaticSources =
        iface:
        map
          (prefix: {
            family = 4;
            inherit prefix;
          })
          (
            builtins.attrNames (
              builtins.listToAttrs (
                map (route: {
                  name = route.dst;
                  value = true;
                }) (builtins.filter isStaticIpv4RoutedSource (familyRoutes (attrsOrEmpty (iface.routes or null))))
              )
            )
          );

      runtimeRoutedPrefixSourceFiles =
        iface:
        builtins.filter (sourceFile: builtins.isString sourceFile && sourceFile != "") (
          map (route: route.sourceFile or null) (
            builtins.filter (
              route:
              builtins.isAttrs route && ((routeIntent route).kind or null) == "runtime-routed-prefix-return"
            ) (familyRoutes (attrsOrEmpty (iface.routes or null)))
          )
        );
      fromCoresWithSourceScopes =
        builtins.filter (entry: entry.sourceFiles != [ ] || entry.sourcePrefixes != [ ])
          (
            map (iface: {
              inherit iface;
              sourceFiles = runtimeRoutedPrefixSourceFiles iface;
              sourcePrefixes = runtimeRoutedPrefixStaticSources iface;
            }) coreInterfaces
          );
      policyInterfacesForCore =
        coreIface:
        let
          matches = builtins.sort (a: b: (a.runtimeIfName or "") < (b.runtimeIfName or "")) (
            builtins.filter (
              policyIface:
              builtins.any (uplink: builtins.elem uplink (common.uplinks coreIface)) (common.uplinks policyIface)
            ) policyInterfaces
          );
        in
        if matches == [ ] then [ ] else [ (builtins.head matches) ];
      exitPolicyInterfacesFor =
        ingressPolicyIface:
        builtins.filter (
          iface:
          iface.runtimeIfName != ingressPolicyIface.runtimeIfName
          && (common.laneAccess iface) == (common.laneAccess ingressPolicyIface)
          && !builtins.any (uplink: builtins.elem uplink (common.uplinks ingressPolicyIface)) (
            common.uplinks iface
          )
        ) policyInterfaces;
      exitCoreInterfacesFor =
        exitPolicyIface:
        builtins.filter (
          coreIface:
          builtins.any (uplink: builtins.elem uplink (common.uplinks exitPolicyIface)) (
            common.uplinks coreIface
          )
        ) coreInterfaces;
      publicEgressExitRulesFor =
        sourceScope: ingressPolicyIface:
        builtins.concatLists (
          map (
            exitPolicyIface:
            map (
              coreIface:
              {
                action = "accept";
                intent = {
                  kind = "runtime-routed-prefix-public-egress";
                  source = "intent-routed-prefix";
                  stage = "policy-to-public-uplink";
                };
                fromInterface = exitPolicyIface.runtimeIfName;
                toInterface = coreIface.runtimeIfName;
                inherit (sourceScope) sourceFiles sourcePrefixes;
                applyTcpMssClamp = false;
              }
              // (if sourceScope.sourceFiles != [ ] then { family = 6; } else { })
            ) (exitCoreInterfacesFor exitPolicyIface)
          ) (exitPolicyInterfacesFor ingressPolicyIface)
        );
    in
    builtins.concatLists (
      map (
        fromEntry:
        builtins.concatLists (
          map (
            toIface:
            if toIface.runtimeIfName == fromEntry.iface.runtimeIfName then
              [ ]
            else
              [
                (
                  {
                    action = "accept";
                    intent = {
                      kind = "runtime-routed-prefix-public-egress";
                      source = "intent-routed-prefix";
                      stage = "overlay-to-policy";
                    };
                    fromInterface = fromEntry.iface.runtimeIfName;
                    toInterface = toIface.runtimeIfName;
                    inherit (fromEntry) sourceFiles sourcePrefixes;
                    applyTcpMssClamp = false;
                  }
                  // (if fromEntry.sourceFiles != [ ] then { family = 6; } else { })
                )
              ]
              ++ publicEgressExitRulesFor fromEntry toIface
          ) (policyInterfacesForCore fromEntry.iface)
        )
      ) fromCoresWithSourceScopes
    )
