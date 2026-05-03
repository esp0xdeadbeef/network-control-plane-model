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

  interfaceNameHasUplinkWanPreference =
    interfaceName:
    builtins.match ".*--uplink-wan$" interfaceName != null;

  interfaceNameTargetsDestination =
    interfaceName: destinationNode:
    builtins.match ".*(^|-)${destinationNode}(-|$).*" interfaceName != null;

  interfaceBackingKind =
    targetPath: interfaces: interfaceName:
    let
      iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${interfaceName}" interfaces.${interfaceName};
      backingRef = attrsOrEmpty (iface.backingRef or null);
    in
    backingRef.kind or null;

in
{
  inherit
    findInterfaceNameForAdjacency
    interfaceBackingKind
    interfaceHasDefaultForFamily
    interfaceNameHasUplinkWanPreference
    interfaceNameTargetsDestination
    ;
}
