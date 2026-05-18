{ lib, common }:

let
  inherit (common)
    fail
    forceAll
    hasDuplicates
    isNonEmptyString
    requireAttrs
    requireList
    requireString
    requireStringList
    ;

  validateRuntimeTarget = context: targetName: target:
    let
      targetContext = context // { target = targetName; };
      targetAttrs = requireAttrs targetContext "runtimeTargets.${targetName}" target;
      placement = requireAttrs targetContext "runtimeTargets.${targetName}.placement" (targetAttrs.placement or null);
      effective = requireAttrs targetContext "runtimeTargets.${targetName}.effectiveRuntimeRealization" (targetAttrs.effectiveRuntimeRealization or null);
      loopback = requireAttrs targetContext "runtimeTargets.${targetName}.effectiveRuntimeRealization.loopback" (effective.loopback or null);
      interfaces = requireAttrs targetContext "runtimeTargets.${targetName}.effectiveRuntimeRealization.interfaces" (effective.interfaces or null);
      renderedNames =
        builtins.map
          (ifName:
            let
              ifaceContext = targetContext // { interface = ifName; };
              iface = requireAttrs ifaceContext "effectiveRuntimeRealization.interfaces.${ifName}" interfaces.${ifName};
              backingRef = requireAttrs ifaceContext "effectiveRuntimeRealization.interfaces.${ifName}.backingRef" (iface.backingRef or null);
              kind = backingRef.kind or null;
            in
            builtins.seq
              (requireString ifaceContext "effectiveRuntimeRealization.interfaces.${ifName}.runtimeIfName" (iface.runtimeIfName or null))
              (builtins.seq
                (requireString ifaceContext "effectiveRuntimeRealization.interfaces.${ifName}.renderedIfName" (iface.renderedIfName or null))
                (builtins.seq
                  (if kind == "link" || kind == "attachment" || kind == "overlay" then true else fail ifaceContext "ambiguous backing reference")
                  (builtins.seq
                    (if builtins.isAttrs (iface.routes or null) then true else fail ifaceContext "routes are required for renderer-ready interfaces")
                    (iface.renderedIfName or null)))))
          (lib.attrNamesSorted interfaces);
    in
    builtins.seq
      (requireString targetContext "runtimeTargets.${targetName}.placement.kind" (placement.kind or null))
      (builtins.seq
        (if !isNonEmptyString (loopback.addr4 or null) || !isNonEmptyString (loopback.addr6 or null) then
          fail targetContext "loopback must contain addr4 and addr6"
        else
          true)
        (if hasDuplicates renderedNames then fail targetContext "duplicate rendered interface names are not allowed" else true));

  validateSite = enterpriseName: siteName: site:
    let
      context = { enterprise = enterpriseName; site = siteName; };
      siteAttrs = requireAttrs context "control_plane_model.data.${enterpriseName}.${siteName}" site;
      transit = requireAttrs context "transit" (siteAttrs.transit or null);
      adjacencies = requireList context "transit.adjacencies" (transit.adjacencies or null);
      ordering = requireStringList context "transit.ordering" (transit.ordering or null);
      runtimeTargets = requireAttrs context "runtimeTargets" (siteAttrs.runtimeTargets or null);
      adjacencyIds =
        builtins.genList
          (idx:
            let adjacency = builtins.elemAt adjacencies idx;
            in
            if !builtins.isAttrs adjacency then
              fail context "transit.adjacencies[${toString idx}] must be an attribute set"
            else if !isNonEmptyString (adjacency.id or null) then
              fail context "transit.adjacencies[${toString idx}].id is required"
            else
              adjacency.id)
          (builtins.length adjacencies);
    in
    builtins.seq
      (if hasDuplicates adjacencyIds then fail context "transit.adjacencies contains duplicate ids" else true)
      (builtins.seq
        (if hasDuplicates ordering then fail context "transit.ordering contains duplicate adjacency IDs" else true)
        (forceAll (
          builtins.map
            (targetName: validateRuntimeTarget context targetName runtimeTargets.${targetName})
            (lib.attrNamesSorted runtimeTargets)
        )));

in
{
  validateData = cpmData:
    if !builtins.isAttrs cpmData then
      throw "control_plane_model.data must be an attribute set"
    else
      forceAll (
        builtins.map
          (enterpriseName:
            let
              sites = requireAttrs { enterprise = enterpriseName; } "control_plane_model.data.${enterpriseName}" cpmData.${enterpriseName};
            in
            forceAll (
              builtins.map
                (siteName: validateSite enterpriseName siteName sites.${siteName})
                (lib.attrNamesSorted sites)
            ))
          (lib.attrNamesSorted cpmData)
      );
}
