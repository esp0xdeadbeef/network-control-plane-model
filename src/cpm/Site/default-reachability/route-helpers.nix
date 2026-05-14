{
  helpers,
  common,
  sitePath,
}:

let
  inherit (helpers) requireAttrs sortedNames;
  inherit (common) attrsOrEmpty routesContainDefault;

  findInterfaceNameForAdjacency = targetName: target: adjacencyId:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      effective = requireAttrs "${targetPath}.effectiveRuntimeRealization" (target.effectiveRuntimeRealization or null);
      interfaces = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces" (effective.interfaces or null);
      matchingNames =
        builtins.filter
          (ifName:
            let
              iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}" interfaces.${ifName};
              backingRef = attrsOrEmpty (iface.backingRef or null);
            in
            (backingRef.id or null) == adjacencyId)
          (sortedNames interfaces);
    in
    if matchingNames == [ ] then null else builtins.elemAt matchingNames 0;

  interfaceHasDefaultForFamily =
    family: iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
    in
    routesContainDefault family (if family == 4 then routes.ipv4 or [ ] else routes.ipv6 or [ ]);

  interfaceBackingKind =
    targetPath: interfaces: interfaceName:
    let
      iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}" interfaces.${interfaceName};
      backingRef = attrsOrEmpty (iface.backingRef or null);
    in
    backingRef.kind or null;

  interfaceLane =
    targetPath: interfaces: interfaceName:
    let
      iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}" interfaces.${interfaceName};
      backingRef = attrsOrEmpty (iface.backingRef or null);
    in
    attrsOrEmpty (backingRef.lane or null);

  interfaceHasUplinkPreference =
    targetPath: interfaces: interfaceName: uplinkName:
    let
      lane = interfaceLane targetPath interfaces interfaceName;
      uplinks = if builtins.isList (lane.uplinks or null) then lane.uplinks else [ ];
    in
    (lane.uplink or null) == uplinkName || builtins.elem uplinkName uplinks;

in
{
  inherit
    findInterfaceNameForAdjacency
    interfaceBackingKind
    interfaceHasDefaultForFamily
    interfaceHasUplinkPreference
    interfaceLane
    ;
}
