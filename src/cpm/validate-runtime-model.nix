{ helpers }:

{ cpm }:

let
  inherit (helpers)
    requireAttrs
    sortedNames
    ;

  forceAll = values:
    builtins.deepSeq values true;

  baseValidator =
    (import ../../invariants/default.nix {
      lib = {
        attrNamesSorted = sortedNames;
      };
    }).validateCPMData;

  validateCoreRuntimeTarget = enterpriseName: siteName: targetName: target:
    let
      targetPath = "control_plane_model.data.${enterpriseName}.${siteName}.runtimeTargets.${targetName}";
      targetAttrs = requireAttrs targetPath target;
      role = targetAttrs.role or null;
    in
    if role != "core" then
      true
    else
      let
        effective =
          requireAttrs
            "${targetPath}.effectiveRuntimeRealization"
            (targetAttrs.effectiveRuntimeRealization or null);
        interfaces =
          requireAttrs
            "${targetPath}.effectiveRuntimeRealization.interfaces"
            (effective.interfaces or null);
        interfaceNames = sortedNames interfaces;

        hasUsableWANInterface =
          builtins.any
            (ifName:
              let
                ifacePath = "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}";
                iface = requireAttrs ifacePath interfaces.${ifName};
              in
              (iface.sourceKind or null) == "wan")
            interfaceNames;

        egressIntent =
          if builtins.isAttrs (targetAttrs.egressIntent or null) then
            targetAttrs.egressIntent
          else
            null;

        exitEnabled =
          egressIntent != null
          && (egressIntent.exit or false) == true;
      in
      if exitEnabled && !hasUsableWANInterface then
        throw "control plane model validation failure: core exit intent requires a realized WAN interface before rendering"
      else if builtins.length interfaceNames < 2 then
        throw "control plane model validation failure: core role requires at least two adapters before rendering"
      else
        true;

  validateRuntimeData = cpmData:
    forceAll (
      builtins.map
        (enterpriseName:
          let
            sites = requireAttrs "control_plane_model.data.${enterpriseName}" cpmData.${enterpriseName};
          in
          forceAll (
            builtins.map
              (siteName:
                let
                  sitePath = "control_plane_model.data.${enterpriseName}.${siteName}";
                  site = requireAttrs sitePath sites.${siteName};
                  runtimeTargets = requireAttrs "${sitePath}.runtimeTargets" (site.runtimeTargets or null);
                in
                forceAll (
                  builtins.map
                    (targetName:
                      validateCoreRuntimeTarget enterpriseName siteName targetName runtimeTargets.${targetName})
                    (sortedNames runtimeTargets)
                ))
              (sortedNames sites)
          ))
        (sortedNames cpmData)
    );

  cpmAttrs = requireAttrs "control_plane_model" cpm;
  data = requireAttrs "control_plane_model.data" (cpmAttrs.data or null);
in
builtins.seq
  (baseValidator data)
  (validateRuntimeData data)
