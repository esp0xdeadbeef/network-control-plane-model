{ lib, attrsOrEmpty, listOrEmpty, defaultDst }:

let
  viaFieldFor = family: if family == 4 then "via4" else "via6";

  routeVia =
    family: route:
      route.${viaFieldFor family} or null;

  lane =
    iface:
    attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null);

  laneAccess = iface: (lane iface).access or null;

  laneKind = iface: (lane iface).kind or null;

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
    builtins.any
      (
        route:
        builtins.isAttrs route
        && (route.dst or null) == prefix
        && (route.policyOnly or false) != true
        && routeVia family route != null
      )
      routes;

  prefixMatchesAccess =
    accessName: prefix:
    accessName != null
    && builtins.any (originAccess: originAccess == accessName) (
      listOrEmpty ((attrsOrEmpty (prefix.origin or null)).accesses or null)
    );

  runtimeOriginPrefixesFromTarget =
    target:
    lib.unique (
      builtins.concatLists (builtins.map
        (rule:
        if (rule.relationId or null) == "runtime-origin-egress" then
          builtins.map (prefix: prefix.prefix)
            (
              builtins.filter (prefix: builtins.isString (prefix.prefix or null)) (
                listOrEmpty (rule.sourcePrefixes or null)
              )
            )
        else
          [ ])
        (listOrEmpty ((attrsOrEmpty (target.forwardingIntent or null)).rules or null)))
    );

  isRuntimeOriginSourceRouteOnPolicyUplink =
    targetRole: runtimeOriginPrefixes: iface: route:
    targetRole == "policy"
    && laneKind iface == "access-uplink"
    && builtins.elem (route.dst or null) runtimeOriginPrefixes
    && (route.policyOnly or false) != true;

  isRuntimeOriginSourcePolicyComplementOnPolicyUplink =
    targetRole: runtimeOriginPrefixes: iface: route:
    targetRole == "policy"
    && laneKind iface == "access-uplink"
    && builtins.elem (route.dst or null) runtimeOriginPrefixes
    && (route.reason or null) == "policy-table-internal-reachability";

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
      builtins.concatLists (builtins.map
        (rule:
        if
          (rule.relationId or null) == "runtime-origin-egress"
          && (rule.fromInterface or null) == ifaceName
        then
          builtins.filter (prefixMatchesAccess accessName) (listOrEmpty (rule.sourcePrefixes or null))
        else
          [ ])
        rules);

  runtimeOriginReturnRoutes =
    family: target: iface: routes:
    let
      viaRoute = firstReturnViaRoute family routes;
      prefixes = builtins.filter
        (
          prefix:
          (prefix.family or null) == family
          && builtins.isString (prefix.prefix or null)
          && !hasNonPolicyRouteToPrefix family prefix.prefix routes
        )
        (runtimeOriginReturnPrefixesForInterface target iface);
    in
    if viaRoute == null then
      [ ]
    else
      builtins.map
        (
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
        )
        prefixes;

  canGeneratePolicyTableComplement =
    route:
    (route.reason or null) != "runtime-origin-return"
    && ((attrsOrEmpty (route.intent or null)).source or null) != "runtime-origin-return";
in
{
  inherit
    laneKind
    runtimeOriginPrefixesFromTarget
    isRuntimeOriginSourceRouteOnPolicyUplink
    isRuntimeOriginSourcePolicyComplementOnPolicyUplink
    runtimeOriginReturnRoutes
    canGeneratePolicyTableComplement
    ;
}
