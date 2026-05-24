{
  lib,
  common,
  overlayNames ? [ ],
  attachments ? [ ],
  routedPrefixesByTenant ? { },
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
  runtimeExitNodes = runtimePrefixExitNodes { inherit attachments routedPrefixesByTenant; };

  viaFieldFor = family: if family == 4 then "via4" else "via6";

  routeVia =
    family: route:
    route.${viaFieldFor family} or null;

  laneAccess =
    iface:
    (attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null)).access or null;

  laneKind =
    iface:
    (attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null)).kind or null;

  routeCanSupplyReturnVia =
    family: route:
    builtins.isAttrs route
    && (route.policyOnly or false) != true
    && (route.dst or null) != null
    && (route.dst or null) != defaultDst family
    && routeVia family route != null;

  firstReturnViaRoute =
    family: routes:
    let
      candidates = builtins.filter (routeCanSupplyReturnVia family) routes;
    in
    if candidates == [ ] then null else builtins.head candidates;

  hasNonPolicyRouteToPrefix =
    family: prefix: routes:
    builtins.any (
      route:
      builtins.isAttrs route
      && (route.dst or null) == prefix
      && (route.policyOnly or false) != true
      && routeVia family route != null
    ) routes;

  prefixMatchesAccess =
    accessName: prefix:
    accessName != null
    && builtins.any (originAccess: originAccess == accessName) (
      listOrEmpty ((attrsOrEmpty (prefix.origin or null)).accesses or null)
    );

  runtimeOriginPrefixesFromTarget =
    target:
    lib.unique (
      lib.concatMap
        (
          rule:
          if (rule.relationId or null) == "runtime-origin-egress" then
            builtins.map (prefix: prefix.prefix) (
              builtins.filter (prefix: builtins.isString (prefix.prefix or null)) (
                listOrEmpty (rule.sourcePrefixes or null)
              )
            )
          else
            [ ]
        )
        (listOrEmpty ((attrsOrEmpty (target.forwardingIntent or null)).rules or null))
    );

  isRuntimeOriginSourceRouteOnPolicyUplink =
    targetRole: runtimeOriginPrefixes: iface: route:
    targetRole == "policy"
    && laneKind iface == "access-uplink"
    && builtins.elem (route.dst or null) runtimeOriginPrefixes
    && (route.policyOnly or false) != true;

  runtimeOriginReturnPrefixesForInterface =
    target: iface:
    let
      ifaceName = iface.runtimeIfName or null;
      accessName = laneAccess iface;
      forwardingIntent = attrsOrEmpty (target.forwardingIntent or null);
      rules = listOrEmpty (forwardingIntent.rules or null);
    in
    if ifaceName == null || accessName == null || laneKind iface != "access" then
      [ ]
    else
      lib.concatMap (
        rule:
        if
          (rule.relationId or null) == "runtime-origin-egress"
          && (rule.fromInterface or null) == ifaceName
        then
          builtins.filter (prefixMatchesAccess accessName) (listOrEmpty (rule.sourcePrefixes or null))
        else
          [ ]
      ) rules;

  runtimeOriginReturnRoutes =
    family: target: iface: routes:
    let
      viaRoute = firstReturnViaRoute family routes;
      prefixes = builtins.filter (
        prefix:
        (prefix.family or null) == family
        && builtins.isString (prefix.prefix or null)
        && !hasNonPolicyRouteToPrefix family prefix.prefix routes
      ) (runtimeOriginReturnPrefixesForInterface target iface);
    in
    if viaRoute == null then
      [ ]
    else
      builtins.map (
        prefix:
        {
          dst = prefix.prefix;
          intent = {
            kind = "internal-reachability";
            source = "runtime-origin-return";
          };
          reason = "runtime-origin-return";
        }
        // {
          ${viaFieldFor family} = routeVia family viaRoute;
        }
      ) prefixes;

  normalizeRuntimeTargetRoutes =
    target:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
      targetRole = target.role or "";
      runtimeOriginPrefixes = runtimeOriginPrefixesFromTarget target;
      classifyTargetRoute = classifyRoute { inherit overlayNames runtimeExitNodes targetRole; };
      classifiedInterfaces = builtins.mapAttrs (
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
      ) interfaces;
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
      normalizedInterfaces = builtins.mapAttrs (
        _ifName: iface:
        let
          routes = attrsOrEmpty (iface.routes or null);
          ipv4 = listOrEmpty (routes.ipv4 or null);
          ipv6 = listOrEmpty (routes.ipv6 or null);
          base4 = ipv4 ++ runtimeOriginReturnRoutes 4 target iface ipv4;
          base6 = ipv6 ++ runtimeOriginReturnRoutes 6 target iface ipv6;
          augmented4 = base4 ++ policyTableComplements 4 policyDefaults4 base4;
          augmented6 = base6 ++ policyTableComplements 6 policyDefaults6 base6;
        in
        iface
        // {
          routes = routes // {
            ipv4 = uniqueRoutes 4 augmented4;
            ipv6 = uniqueRoutes 6 augmented6;
          };
        }
      ) classifiedInterfaces;
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
