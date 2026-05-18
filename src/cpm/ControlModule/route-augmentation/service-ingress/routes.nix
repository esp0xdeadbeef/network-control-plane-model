{ helpers, common, routePresent }:

let
  inherit (helpers) isNonEmptyString;
  inherit (common) attrsOrEmpty listOrEmpty;

  routeFamily = destination: if builtins.match ".*:.*" destination == null then 4 else 6;

  routesFor =
    family: iface:
    let routes = attrsOrEmpty (iface.routes or null);
    in
    if family == 4 then listOrEmpty (routes.ipv4 or null) else listOrEmpty (routes.ipv6 or null);

  addRouteToInterface =
    family: route: destination: ifName: interfacesAcc:
    let
      iface = interfacesAcc.${ifName};
      existingRoutes = routesFor family iface;
    in
    if routePresent family existingRoutes destination then
      interfacesAcc
    else
      interfacesAcc
      // {
        ${ifName} = iface // {
          routes =
            (attrsOrEmpty (iface.routes or null))
            // (if family == 4 then { ipv4 = existingRoutes ++ [ route ]; } else { ipv6 = existingRoutes ++ [ route ]; });
        };
      };

  routeForPeer =
    family: serviceName: relationId: trafficType: endpoint: peer:
    { dst = endpoint; proto = "service-ingress"; }
    // (if family == 4 then { via4 = peer; } else { via6 = peer; })
    // {
      intent = {
        kind = "service-ingress";
        service = serviceName;
        source = "service-ingress";
      }
      // (if relationId != null then { relation = relationId; } else { })
      // (if trafficType != null then { inherit trafficType; } else { });
    };

in
{
  inherit
    addRouteToInterface
    isNonEmptyString
    routeFamily
    routeForPeer
    routesFor
    ;
}
