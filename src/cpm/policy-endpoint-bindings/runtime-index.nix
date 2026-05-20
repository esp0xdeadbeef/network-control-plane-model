{ helpers, bindingCommon }:

{ sitePath, runtimeTargets }:

let
  inherit (helpers) isNonEmptyString requireAttrs requireString sortedNames;
  inherit (bindingCommon) attrsOrEmpty appendListValue;

  foldRuntimeInterfaces =
    step: initial:
    builtins.foldl'
      (acc: targetName:
      let
        targetPath = "${sitePath}.runtimeTargets.${targetName}";
        target = requireAttrs targetPath runtimeTargets.${targetName};
        logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
        nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
        egressIntent = attrsOrEmpty (target.egressIntent or null);
        effective = requireAttrs "${targetPath}.effectiveRuntimeRealization" (target.effectiveRuntimeRealization or null);
        interfaces = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces" (effective.interfaces or null);
      in
      builtins.foldl'
        (inner: ifName:
        let
          iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}" interfaces.${ifName};
          runtimeInterface = requireString "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}.runtimeIfName" (iface.runtimeIfName or null);
        in
        step inner {
          inherit targetName targetPath nodeName egressIntent ifName iface runtimeInterface;
        })
        acc
        (sortedNames interfaces))
      initial
      (sortedNames runtimeTargets);

  tenantBindings =
    foldRuntimeInterfaces
      (acc: ctx:
        let
          backingRef = attrsOrEmpty (ctx.iface.backingRef or null);
          tenantName = backingRef.name or null;
        in
        if (backingRef.kind or null) != "attachment" || !isNonEmptyString tenantName then
          acc
        else
          appendListValue acc tenantName {
            runtimeTarget = ctx.targetName;
            logicalNode = ctx.nodeName;
            sourceInterface = ctx.ifName;
            runtimeInterface = ctx.runtimeInterface;
            attachmentId = backingRef.id or null;
          })
      { };

  externalBindings =
    foldRuntimeInterfaces
      (acc: ctx:
        let
          backingRef = attrsOrEmpty (ctx.iface.backingRef or null);
          sourceKind = ctx.iface.sourceKind or null;
          add = externalName: extra:
            if !isNonEmptyString externalName then
              acc
            else
              appendListValue acc externalName ({
                runtimeTarget = ctx.targetName;
                logicalNode = ctx.nodeName;
                sourceInterface = ctx.ifName;
                runtimeInterface = ctx.runtimeInterface;
                inherit sourceKind;
                externalName = externalName;
                exit = false;
              } // extra);
        in
        if sourceKind == "wan" then
          let externalName = ctx.iface.upstream or null;
          in add externalName { uplink = externalName; exit = (ctx.egressIntent.exit or false) == true; }
        else if sourceKind == "overlay" then
          let externalName = backingRef.name or null;
          in add externalName { overlay = externalName; }
        else
          acc)
      { };

in
{
  runtimeTenantBindingsByTenant = tenantBindings;
  runtimeExternalBindingsByName = externalBindings;
}
