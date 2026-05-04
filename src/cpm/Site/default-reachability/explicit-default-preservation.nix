{ helpers, common, sitePath }:

let
  inherit (helpers) requireAttrs sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty routesContainDefault;

  defaultRoutesForFamily =
    family: routes:
    builtins.filter (route: routesContainDefault family [ route ]) (listOrEmpty routes);

  mergeMissingDefaults =
    family: originalRoutes: resolvedRoutes:
    let
      defaults = defaultRoutesForFamily family originalRoutes;
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
                ipv4 = mergeMissingDefaults 4 (originalRoutes.ipv4 or [ ]) (resolvedRoutes.ipv4 or [ ]);
                ipv6 = mergeMissingDefaults 6 (originalRoutes.ipv6 or [ ]) (resolvedRoutes.ipv6 or [ ]);
              };
            })
          resolvedInterfaces;
    in
    resolvedTarget // { effectiveRuntimeRealization = resolvedEffective // { interfaces = mergedInterfaces; }; };
}
