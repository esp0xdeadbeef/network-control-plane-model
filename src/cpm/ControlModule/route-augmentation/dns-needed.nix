{ helpers, common, routeHelpers }:

let
  inherit (helpers) isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty;
  inherit (routeHelpers) routeWithExactDstPresent;

  interfaceLane =
    iface:
    let backingRef = attrsOrEmpty (iface.backingRef or null);
    in attrsOrEmpty (backingRef.lane or null);

  laneUplinks =
    lane:
    if builtins.isList (lane.uplinks or null) then
      lane.uplinks
    else if isNonEmptyString (lane.uplink or null) then
      [ lane.uplink ]
    else
      [ ];

  routePresent =
    family: routes: destination:
    if family == 4 then
      routeWithExactDstPresent routes destination
    else
      builtins.any (route: builtins.isAttrs route && (route.dst or null) == destination) (listOrEmpty routes);

  serviceHasRouteContracts =
    target:
    let
      dns = attrsOrEmpty ((attrsOrEmpty (target.services or null)).dns or null);
    in
    listOrEmpty (dns.routeContracts or null) != [ ] || listOrEmpty (dns.forwarders or null) != [ ];

  interfaceMatchesDnsSpec =
    iface: spec:
    let
      routes = attrsOrEmpty (iface.routes or null);
      routes4 = listOrEmpty (routes.ipv4 or null);
      routes6 = listOrEmpty (routes.ipv6 or null);
      uplinks = laneUplinks (interfaceLane iface);
      preferredUplinks =
        (listOrEmpty (spec.preferredUplinks or null))
        ++ (listOrEmpty (spec.ingressPreferredUplinks or null));
    in
    builtins.any (destination: routePresent 4 routes4 destination) (listOrEmpty (spec.consumerPrefixes4 or null))
    || builtins.any (destination: routePresent 6 routes6 destination) (listOrEmpty (spec.consumerPrefixes6 or null))
    || (preferredUplinks != [ ] && builtins.any (uplink: builtins.elem uplink preferredUplinks) uplinks);

in
{ dnsServiceRouteSpecs, target }:
let
  effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
  interfaces = attrsOrEmpty (effective.interfaces or null);
in
serviceHasRouteContracts target
|| (
  dnsServiceRouteSpecs != [ ]
  && builtins.any
    (ifName:
      builtins.any
        (spec: interfaceMatchesDnsSpec (attrsOrEmpty (interfaces.${ifName} or null)) spec)
        dnsServiceRouteSpecs)
    (sortedNames interfaces)
)
