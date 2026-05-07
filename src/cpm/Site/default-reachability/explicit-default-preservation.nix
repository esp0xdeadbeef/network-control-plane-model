{
  helpers,
  common,
  sitePath,
  siteOverlayNameSet,
  isDelegatedIPv6AccessNode,
}:

let
  inherit (helpers) hasAttr isNonEmptyString requireAttrs sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty routesContainDefault;

  laneHelpers = import ../topology/lane-metadata.nix { inherit helpers; };
  inherit (laneHelpers) effectiveRouteLane;

  defaultAllowed =
    targetRole: family: iface: route:
    let
      lane = effectiveRouteLane iface route;
      uplinkName = lane.uplink or null;
      accessNodeName = lane.access or null;
      usesOverlay = isNonEmptyString uplinkName && hasAttr uplinkName siteOverlayNameSet;
      delegatedAccess = isNonEmptyString accessNodeName && isDelegatedIPv6AccessNode accessNodeName;
    in
    (
      !isNonEmptyString uplinkName
      || !usesOverlay
      || targetRole == "core"
      || delegatedAccess
    )
    && !(family == 6 && delegatedAccess && isNonEmptyString uplinkName && !usesOverlay);

  defaultRoutesForFamily =
    targetRole: family: iface: routes:
    builtins.filter
      (route:
        let
          intent = attrsOrEmpty (route.intent or null);
        in
        routesContainDefault family [ route ]
        && defaultAllowed targetRole family iface route
        && (
          targetRole == "core"
          || (intent.source or null) == "explicit-uplink"
          || (route.proto or null) == "upstream"
        ))
      (listOrEmpty routes);

  mergeMissingDefaults =
    targetRole: family: originalIface: originalRoutes: resolvedRoutes:
    let
      defaults = defaultRoutesForFamily targetRole family originalIface originalRoutes;
      hasDefault = routesContainDefault family resolvedRoutes;
    in
    if hasDefault || defaults == [ ] then resolvedRoutes else defaults ++ resolvedRoutes;
in
{
  restore =
    { targetName, originalTarget, resolvedTarget }:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      originalEffective = requireAttrs "${targetPath}.effectiveRuntimeRealization" (originalTarget.effectiveRuntimeRealization or null);
      resolvedEffective = requireAttrs "${targetPath}.effectiveRuntimeRealization" (resolvedTarget.effectiveRuntimeRealization or null);
      targetRole = originalTarget.role or null;
      originalInterfaces = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces" (originalEffective.interfaces or null);
      resolvedInterfaces = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces" (resolvedEffective.interfaces or null);
      mergedInterfaces =
        builtins.mapAttrs
          (interfaceName: resolvedIface:
            let
              originalIface = attrsOrEmpty (originalInterfaces.${interfaceName} or null);
              originalRoutes = attrsOrEmpty (originalIface.routes or null);
              resolvedRoutes = attrsOrEmpty (resolvedIface.routes or null);
            in
            resolvedIface
            // {
              routes = resolvedRoutes // {
                ipv4 = mergeMissingDefaults targetRole 4 originalIface (originalRoutes.ipv4 or [ ]) (resolvedRoutes.ipv4 or [ ]);
                ipv6 = mergeMissingDefaults targetRole 6 originalIface (originalRoutes.ipv6 or [ ]) (resolvedRoutes.ipv6 or [ ]);
              };
            })
          resolvedInterfaces;
    in
    resolvedTarget // { effectiveRuntimeRealization = resolvedEffective // { interfaces = mergedInterfaces; }; };
}
