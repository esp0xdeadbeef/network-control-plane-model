{
  helpers,
  common,
  sitePath,
  siteAttrs,
  runtimeTargets,
}:

let
  inherit (helpers) hasAttr requireAttrs requireString sortedNames;
  inherit (common)
    attrsOrEmpty
    listOrEmpty
    makeStringSet
    overlayNameFromInterfaceName
    uniqueStrings
    ;

  runtimeTargetNames = sortedNames runtimeTargets;

  runtimeTargetsByNode =
    builtins.listToAttrs (
      builtins.map
        (targetName:
          let
            targetPath = "${sitePath}.runtimeTargets.${targetName}";
            target = requireAttrs targetPath runtimeTargets.${targetName};
            logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
            nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
          in
          {
            name = nodeName;
            value = {
              inherit targetName target;
            };
          })
        runtimeTargetNames
    );

  forwardingSemantics = attrsOrEmpty (siteAttrs.forwardingSemantics or null);
  forwardingSemanticsNodes = attrsOrEmpty (forwardingSemantics.nodes or null);
  siteEgressIntent = attrsOrEmpty (siteAttrs.egressIntent or null);
  transportAttrs = attrsOrEmpty (siteAttrs.transport or null);

  siteOverlayNames =
    uniqueStrings (
      sortedNames (attrsOrEmpty (siteAttrs.overlays or null))
      ++ builtins.map
        (overlay: overlay.name or null)
        (listOrEmpty (transportAttrs.overlays or null))
      ++ builtins.concatLists (
        builtins.map
          (targetName:
            let
              target = requireAttrs "${sitePath}.runtimeTargets.${targetName}" runtimeTargets.${targetName};
              effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
              interfaces = attrsOrEmpty (effective.interfaces or null);
            in
            builtins.map
              (ifName:
                let
                  iface = attrsOrEmpty interfaces.${ifName};
                in
                if (iface.sourceKind or null) == "overlay" then
                  overlayNameFromInterfaceName ifName
                else
                  null)
              (sortedNames interfaces))
          runtimeTargetNames
      )
    );

  siteOverlayNameSet = makeStringSet siteOverlayNames;

  exitNodeNamesFromSite =
    if builtins.isList (siteEgressIntent.exitNodeNames or null) then
      builtins.filter helpers.isNonEmptyString siteEgressIntent.exitNodeNames
    else
      [ ];

  exitNodeNamesFromForwardingSemantics =
    builtins.filter
      (nodeName:
        let
          nodeSemantics = attrsOrEmpty forwardingSemanticsNodes.${nodeName};
          egressIntent = attrsOrEmpty (nodeSemantics.egressIntent or null);
        in
        (egressIntent.exit or false) == true)
      (sortedNames forwardingSemanticsNodes);

  exitNodeNamesFromRuntimeTargets =
    builtins.filter
      (nodeName:
        let
          target = runtimeTargetsByNode.${nodeName}.target;
          egressIntent = attrsOrEmpty (target.egressIntent or null);
        in
        (egressIntent.exit or false) == true)
      (sortedNames runtimeTargetsByNode);

  exitNodeSet =
    makeStringSet (
      exitNodeNamesFromSite
      ++ exitNodeNamesFromForwardingSemantics
      ++ exitNodeNamesFromRuntimeTargets
    );

in
{
  inherit
    exitNodeSet
    forwardingSemantics
    forwardingSemanticsNodes
    runtimeTargetNames
    runtimeTargetsByNode
    siteOverlayNameSet
    siteOverlayNames
    ;
}
