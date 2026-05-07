{
  lib,
  helpers,
  common,
  ipam,
  routeHelpers,
  sitePath,
  allowedRelations,
  serviceDefinitions,
  providerEndpointForServiceProvider,
}:

let
  inherit (helpers) isNonEmptyString requireAttrs;
  inherit (common) attrsOrEmpty listOrEmpty;

  laneHelpers = import ../../Site/topology/lane-metadata.nix { inherit helpers; };
  inherit (laneHelpers) interfaceLane laneUplinks;

  destinationHelpers = import ./dns/destinations.nix {
    inherit lib common ipam;
    inherit routeHelpers;
  };
  inherit (destinationHelpers) routeForCoveringDst routePresent;

  p2pPeers = import ./p2p-peers.nix { inherit lib; };

  relationUplinks =
    relation:
    let from = attrsOrEmpty (relation.from or null);
    in
    if builtins.isList (from.uplinks or null) then
      from.uplinks
    else if isNonEmptyString (from.name or null) then
      [ from.name ]
    else
      [ ];

  serviceIngressRelations =
    builtins.filter
      (relation:
        let
          attrs = attrsOrEmpty relation;
          from = attrsOrEmpty (attrs.from or null);
          to = attrsOrEmpty (attrs.to or null);
        in
        (attrs.action or "allow") == "allow"
        && (from.kind or null) == "external"
        && relationUplinks attrs != [ ]
        && (to.kind or null) == "service"
        && isNonEmptyString (to.name or null)
        && attrsOrEmpty (serviceDefinitions.${to.name} or null) != { })
      allowedRelations;

  endpointAddressesForService =
    serviceName:
    lib.concatMap
      (provider:
        let endpoint = providerEndpointForServiceProvider provider;
        in
        (endpoint.ipv4 or [ ]) ++ (endpoint.ipv6 or [ ]))
      (listOrEmpty ((serviceDefinitions.${serviceName} or { }).providers or null));
in
targetName: target:
let
  targetPath = "${sitePath}.runtimeTargets.${targetName}";
  effective =
    requireAttrs
      "${targetPath}.effectiveRuntimeRealization"
      (target.effectiveRuntimeRealization or null);
  interfaces =
    requireAttrs
      "${targetPath}.effectiveRuntimeRealization.interfaces"
      (effective.interfaces or null);
  interfaceNames = builtins.attrNames interfaces;

  routeFamily = destination: if builtins.match ".*:.*" destination == null then 4 else 6;
  routesFor =
    family: iface:
    let routes = attrsOrEmpty (iface.routes or null);
    in
    if family == 4 then listOrEmpty (routes.ipv4 or null) else listOrEmpty (routes.ipv6 or null);

  providerInterfaceFor =
    family: destination:
    lib.findFirst
      (ifName:
        let iface = interfaces.${ifName};
        in
        (interfaceLane iface).kind or null == "access-uplink"
        && routeForCoveringDst { inherit family destination; routes = routesFor family iface; } != null)
      null
      interfaceNames;

  ingressInterfaceFor =
    providerIfName: uplinkName:
    let providerLane = interfaceLane interfaces.${providerIfName};
    in
    lib.findFirst
      (ifName:
        let lane = interfaceLane interfaces.${ifName};
        in
        (lane.kind or null) == "access-uplink"
        && (lane.access or null) == (providerLane.access or null)
        && builtins.elem uplinkName (laneUplinks lane))
      null
      interfaceNames;

  addRoute =
    interfacesAcc: relation:
    let
      serviceName = (attrsOrEmpty (relation.to or null)).name or null;
      endpoints = endpointAddressesForService serviceName;
      uplinks = relationUplinks relation;
      relationId = relation.id or relation.name or null;
      trafficType = relation.trafficType or (serviceDefinitions.${serviceName}.trafficType or null);
    in
    builtins.foldl'
      (outer: endpoint:
        let
          family = routeFamily endpoint;
          providerIfName = providerInterfaceFor family endpoint;
        in
        if providerIfName == null then
          outer
        else
          builtins.foldl'
            (inner: uplinkName:
              let
                ingressIfName = ingressInterfaceFor providerIfName uplinkName;
                iface = if ingressIfName == null then { } else inner.${ingressIfName};
                peer = if ingressIfName == null then null else p2pPeers.peerForInterface family iface;
                routes = if ingressIfName == null then [ ] else routesFor family iface;
                route =
                  { dst = endpoint; proto = "service-ingress"; }
                  // (if family == 4 then { via4 = peer; } else { via6 = peer; })
                  // {
                    intent = {
                      kind = "service-ingress";
                      service = serviceName;
                      source = "service-ingress";
                    }
                    // lib.optionalAttrs (relationId != null) { relation = relationId; }
                    // lib.optionalAttrs (trafficType != null) { inherit trafficType; };
                  };
              in
              if ingressIfName == null || !isNonEmptyString peer || routePresent family routes endpoint then
                inner
              else
                inner
                // {
                  ${ingressIfName} =
                    iface
                    // {
                      routes =
                        (attrsOrEmpty (iface.routes or null))
                        // (
                          if family == 4 then
                            { ipv4 = routes ++ [ route ]; }
                          else
                            { ipv6 = routes ++ [ route ]; }
                        );
                    };
                })
            outer
            uplinks)
      interfacesAcc
      endpoints;

  updatedInterfaces = builtins.foldl' addRoute interfaces serviceIngressRelations;
in
if serviceIngressRelations == [ ] then
  target
else
  target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; }
