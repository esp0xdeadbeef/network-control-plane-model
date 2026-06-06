{ helpers, targetDefs }:

let
  inherit (helpers)
    ensureUniqueEntries
    forceAll
    sortedNames
    ;

  validateUniqueLinkAdapterNamesPerHost =
    ensureUniqueEntries
      "inventory.realization.nodes.*.ports.*.adapterName (must be unique per deployment host for link selectors)"
      (
        builtins.concatLists (
          builtins.map
            (targetName:
              let
                targetDef = targetDefs.${targetName};
                hostName = targetDef.host;
                targetPath = targetDef.nodePath;
              in
              builtins.concatLists (
                builtins.map
                  (portName:
                    let
                      portDef = targetDef.portBindings.portDefs.${portName};
                    in
                    if portDef.selector.kind == "link" then
                      [
                        {
                          name = "${hostName}|${portDef.adapterName}";
                          value = {
                            host = hostName;
                            target = targetName;
                            port = portName;
                            path = "${targetPath}.ports.${portName}.adapterName";
                          };
                        }
                      ]
                    else
                      [ ])
                  (sortedNames targetDef.portBindings.portDefs)
              ))
            (sortedNames targetDefs)
        )
      );

  validateUniqueRuntimeIfNamesPerTarget =
    forceAll (builtins.map
      (targetName:
        let
          targetDef = targetDefs.${targetName};
          targetPath = targetDef.nodePath;
        in
        ensureUniqueEntries
          "${targetPath}.ports.*.interface.name (must be unique per realized target)"
          (
            builtins.map
              (portName:
                let
                  portDef = targetDef.portBindings.portDefs.${portName};
                in
                {
                  name = portDef.runtimeIfName;
                  value = {
                    target = targetName;
                    port = portName;
                    path = "${targetPath}.ports.${portName}.interface.name";
                  };
                })
              (sortedNames targetDef.portBindings.portDefs)
          ))
      (sortedNames targetDefs));

  validateUniqueFabricLinksPerTarget =
    forceAll (builtins.map
      (targetName:
        targetDefs.${targetName}.fabricLinkBindings.byLink)
      (sortedNames targetDefs));
in
{
  inherit
    validateUniqueFabricLinksPerTarget
    validateUniqueLinkAdapterNamesPerHost
    validateUniqueRuntimeIfNamesPerTarget
    ;
}
