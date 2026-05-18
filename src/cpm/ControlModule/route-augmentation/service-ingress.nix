{
  lib,
  helpers,
  common,
  ipam,
  routeHelpers,
  sitePath,
  allowedRelations,
  attachments,
  nodes,
  serviceDefinitions,
  providerEndpointForServiceProvider,
  providerTenantsForServiceProvider,
}:

let
  inherit (helpers) isNonEmptyString requireAttrs;
  inherit (common) attrsOrEmpty listOrEmpty;

  laneHelpers = import ../../Site/topology/lane-metadata.nix { inherit helpers; };
  inherit (laneHelpers) interfaceLane;

  destinationHelpers = import ./dns/destinations.nix {
    inherit lib common ipam;
    inherit routeHelpers;
  };
  inherit (destinationHelpers) routeForCoveringDst routePresent;

  p2pPeers = import ./p2p-peers.nix { inherit lib; };

  serviceIngressContext = import ./service-ingress/context.nix {
    inherit lib helpers common allowedRelations serviceDefinitions providerEndpointForServiceProvider;
  };
  inherit (serviceIngressContext)
    endpointAddressesForService
    relationUplinks
    serviceIngressRelations
    ;

  providerAccess = import ./service-ingress/provider-access.nix {
    inherit lib helpers common sitePath attachments nodes serviceDefinitions providerTenantsForServiceProvider;
  };
  inherit (providerAccess) providerAccessNodesForService;
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

  routeUtils = import ./service-ingress/routes.nix {
    inherit helpers common routePresent;
  };
  inherit (routeUtils)
    addRouteToInterface
    routeFamily
    routeForPeer
    routesFor
    ;

  interfaceSelection = import ./service-ingress/interface-selection.nix {
    inherit lib helpers interfaceNames interfaces routeForCoveringDst routesFor;
  };
  inherit (interfaceSelection) externalIngressInterfacesFor ingressInterfaceFor providerInterfaceFor;

  routeIntent = route: attrsOrEmpty (route.intent or null);

  overlayReturnRoutes =
    family: ifName: interfacesAcc:
    let
      peer = p2pPeers.peerForInterface family interfacesAcc.${ifName};
      existingRoutes = routesFor family interfacesAcc.${ifName};
      candidateRoutes =
        lib.concatMap
          (sourceIfName:
            builtins.filter
              (route:
                builtins.isAttrs route
                && ((routeIntent route).kind or null) == "overlay-reachability"
                && isNonEmptyString (route.dst or null)
                && !routePresent family existingRoutes route.dst)
              (routesFor family interfacesAcc.${sourceIfName}))
          interfaceNames;
    in
    if !isNonEmptyString peer then
      [ ]
    else
      builtins.map
        (route:
          (builtins.removeAttrs route [ "via4" "via6" ])
          // (if family == 4 then { via4 = peer; } else { via6 = peer; }))
        candidateRoutes;

  addRoute =
    interfacesAcc: relation:
    let
      serviceName = (attrsOrEmpty (relation.to or null)).name or null;
      endpoints = endpointAddressesForService serviceName;
      providerAccessNodes = providerAccessNodesForService serviceName;
      uplinks = relationUplinks relation;
      relationId = relation.id or relation.name or null;
      trafficType = relation.trafficType or (serviceDefinitions.${serviceName}.trafficType or null);
    in
    builtins.foldl'
      (outer: endpoint:
        let
          family = routeFamily endpoint;
          providerIfName = providerInterfaceFor family endpoint providerAccessNodes;
        in
        if providerIfName == null && providerAccessNodes == [ ] then
          outer
        else
          builtins.foldl'
            (inner: uplinkName:
              let
                ingressIfName = ingressInterfaceFor providerAccessNodes providerIfName uplinkName;
                providerIface = if providerIfName == null then null else inner.${providerIfName};
                providerLane = if providerIface == null then { } else interfaceLane providerIface;
                ingressPeer =
                  if ingressIfName == null then
                    null
                  else if (providerLane.kind or null) == "access" then
                    p2pPeers.peerForInterface family providerIface
                  else
                    p2pPeers.peerForInterface family inner.${ingressIfName};
                routeIfNames =
                  if ingressIfName != null then
                    [ ingressIfName ] ++ externalIngressInterfacesFor uplinkName
                  else
                    externalIngressInterfacesFor uplinkName;
              in
              if routeIfNames == [ ] then
                inner
              else
                builtins.foldl'
                  (acc: ifName:
                    let
                      peer = if ingressIfName == null then p2pPeers.peerForInterface family acc.${ifName} else ingressPeer;
                      routeAcc =
                        if !isNonEmptyString peer then
                          acc
                        else
                          addRouteToInterface family (routeForPeer family serviceName relationId trafficType endpoint peer) endpoint ifName acc;
                    in
                    if ingressIfName == null || ifName != ingressIfName then
                      routeAcc
                    else
                      builtins.foldl'
                        (returnAcc: returnRoute: addRouteToInterface family returnRoute returnRoute.dst ifName returnAcc)
                        routeAcc
                        (overlayReturnRoutes family ifName routeAcc))
                  inner
                  routeIfNames)
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
