{ lib
, common
, overlayNames ? [ ]
, attachments ? [ ]
, routedPrefixesByTenant ? { }
,
}:

let
  inherit (common) attrsOrEmpty listOrEmpty;

  defaultDst = family: if family == 4 then "0.0.0.0/0" else "::/0";
  routeIdentity = import ./runtime-route-identity.nix { inherit attrsOrEmpty defaultDst; };
  inherit (routeIdentity) uniqueRoutes isPolicyDefault;
  routePolicy = import ./runtime-route-policy.nix {
    inherit
      lib
      attrsOrEmpty
      listOrEmpty
      defaultDst
      ;
  };
  inherit (routePolicy)
    rolesWithPolicyDefaults
    runtimePrefixExitNodes
    classifyRoute
    policyDefaultRoutes
    policyTableComplements
    ;
  inherit (import ./route-kernel-defaults.nix { inherit defaultDst; }) uniqueKernelDefaults;
  inherit (import ./route-defaults.nix { inherit attrsOrEmpty defaultDst; })
    dropDuplicateUnlanedDefaults
    ;
  runtimeOriginRoutes = import ./runtime-origin-route-helpers.nix {
    inherit
      lib
      attrsOrEmpty
      listOrEmpty
      defaultDst
      ;
  };
  inherit (runtimeOriginRoutes)
    laneKind
    runtimeOriginPrefixesFromTarget
    isRuntimeOriginSourceRouteOnPolicyUplink
    isRuntimeOriginSourcePolicyComplementOnPolicyUplink
    runtimeOriginReturnRoutes
    canGeneratePolicyTableComplement
    ;
  runtimeExitNodes = runtimePrefixExitNodes { inherit attachments routedPrefixesByTenant; };

  normalizeRuntimeTargetRoutes =
    target:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
      targetRole = target.role or "";
      runtimeOriginPrefixes = runtimeOriginPrefixesFromTarget target;
      classifyTargetRoute = classifyRoute { inherit overlayNames runtimeExitNodes targetRole; };
      classifiedInterfaces = builtins.mapAttrs
        (
          _ifName: iface:
            let
              routes = attrsOrEmpty (iface.routes or null);
              dropWrongRuntimeOriginRoute = isRuntimeOriginSourceRouteOnPolicyUplink targetRole runtimeOriginPrefixes iface;
              ipv4 = uniqueKernelDefaults 4 (
                dropDuplicateUnlanedDefaults 4 (
                  builtins.filter (route: route != null) (
                    builtins.map (classifyTargetRoute 4) (
                      builtins.filter (route: !dropWrongRuntimeOriginRoute route) (listOrEmpty (routes.ipv4 or null))
                    )
                  )
                )
              );
              ipv6 = uniqueKernelDefaults 6 (
                dropDuplicateUnlanedDefaults 6 (
                  builtins.filter (route: route != null) (
                    builtins.map (classifyTargetRoute 6) (
                      builtins.filter (route: !dropWrongRuntimeOriginRoute route) (listOrEmpty (routes.ipv6 or null))
                    )
                  )
                )
              );
            in
            if ipv4 == [ ] && ipv6 == [ ] then
              iface
            else
              iface
              // {
                routes = routes // {
                  ipv4 = uniqueRoutes 4 ipv4;
                  ipv6 = uniqueRoutes 6 ipv6;
                };
              }
        )
        interfaces;
      policyDefaults4 =
        if builtins.hasAttr targetRole rolesWithPolicyDefaults then
          policyDefaultRoutes { inherit isPolicyDefault; } 4 classifiedInterfaces
        else
          [ ];
      policyDefaults6 =
        if builtins.hasAttr targetRole rolesWithPolicyDefaults then
          policyDefaultRoutes { inherit isPolicyDefault; } 6 classifiedInterfaces
        else
          [ ];
      normalizedInterfaces = builtins.mapAttrs
        (
          _ifName: iface:
            let
              routes = attrsOrEmpty (iface.routes or null);
              ipv4 = listOrEmpty (routes.ipv4 or null);
              ipv6 = listOrEmpty (routes.ipv6 or null);
              base4 = ipv4 ++ runtimeOriginReturnRoutes 4 target iface ipv4;
              base6 = ipv6 ++ runtimeOriginReturnRoutes 6 target iface ipv6;
              dropWrongRuntimeOriginComplement =
                isRuntimeOriginSourcePolicyComplementOnPolicyUplink targetRole runtimeOriginPrefixes iface;
              complementBase4 = builtins.filter canGeneratePolicyTableComplement base4;
              complementBase6 = builtins.filter canGeneratePolicyTableComplement base6;
              augmented4 = builtins.filter (route: !dropWrongRuntimeOriginComplement route) (
                base4 ++ policyTableComplements 4 policyDefaults4 complementBase4
              );
              augmented6 = builtins.filter (route: !dropWrongRuntimeOriginComplement route) (
                base6 ++ policyTableComplements 6 policyDefaults6 complementBase6
              );
            in
            iface
            // {
              routes = routes // {
                ipv4 = uniqueRoutes 4 augmented4;
                ipv6 = uniqueRoutes 6 augmented6;
              };
            }
        )
        classifiedInterfaces;
    in
    if interfaces == { } then
      target
    else
      target
      // {
        effectiveRuntimeRealization = effective // {
          interfaces = normalizedInterfaces;
        };
      };
in
{
  inherit normalizeRuntimeTargetRoutes uniqueRoutes;
}
