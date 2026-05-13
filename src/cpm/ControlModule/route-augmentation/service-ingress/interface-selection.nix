{
  lib,
  helpers,
  interfaceNames,
  interfaces,
  routeForCoveringDst,
  routesFor,
}:

let
  inherit (helpers) isNonEmptyString;

  laneHelpers = import ../../../Site/topology/lane-metadata.nix { inherit helpers; };
  inherit (laneHelpers) interfaceLane laneUplinks;

  providerInterfaceFor =
    family: destination: providerAccessNodes:
    let
      matchingInterface =
        kind:
        lib.findFirst
          (ifName:
            let iface = interfaces.${ifName};
            in
            (interfaceLane iface).kind or null == kind
            && routeForCoveringDst { inherit family destination; routes = routesFor family iface; } != null)
          null
          interfaceNames;
      accessIfName = matchingInterface "access";
      providerAccessIfName =
        lib.findFirst
          (ifName:
            let lane = interfaceLane interfaces.${ifName};
            in
            (lane.kind or null) == "access"
            && builtins.elem (lane.access or null) providerAccessNodes)
          null
          interfaceNames;
    in
    if accessIfName != null then
      accessIfName
    else if providerAccessIfName != null then
      providerAccessIfName
    else
      matchingInterface "access-uplink";

  ingressInterfaceFor =
    providerAccessNodes: providerIfName: uplinkName:
    let
      providerLane =
        if providerIfName == null then { } else interfaceLane interfaces.${providerIfName};
      providerAccess =
        if providerIfName == null then
          providerAccessNodes
        else if isNonEmptyString (providerLane.access or null) then
          [ providerLane.access ]
        else
          [ ];
    in
    lib.findFirst
      (ifName:
        let lane = interfaceLane interfaces.${ifName};
        in
        (lane.kind or null) == "access-uplink"
        && builtins.elem (lane.access or null) providerAccess
        && builtins.elem uplinkName (laneUplinks lane))
      null
      interfaceNames;

  externalIngressInterfacesFor =
    uplinkName:
    builtins.filter
      (ifName:
        let lane = interfaceLane interfaces.${ifName};
        in
        (lane.kind or null) == "uplink"
        && builtins.elem uplinkName (laneUplinks lane))
      interfaceNames;
in
{
  inherit externalIngressInterfacesFor ingressInterfaceFor providerInterfaceFor;
}
