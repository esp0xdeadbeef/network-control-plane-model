{
  helpers,
  common,
  sitePath,
  forwardingSemantics,
  forwardingSemanticsNodes,
  runtimeTargetNames,
  runtimeTargetsByNode,
  runtimeTargetsWithSynthesizedDefaults,
  targetHasDefaultReachabilityForFamily,
}:

let
  inherit (helpers) hasAttr requireAttrs requireString sortedNames;
  inherit (common) attrsOrEmpty makeStringSet;

  targetHasAnyDefaultReachability = targetName: target:
    targetHasDefaultReachabilityForFamily 4 targetName target
    || targetHasDefaultReachabilityForFamily 6 targetName target;

  updatedRoutingAuthority =
    builtins.listToAttrs (
      builtins.map
        (targetName: {
          name = targetName;
          value = {
            defaultReachability =
              targetHasAnyDefaultReachability targetName runtimeTargetsWithSynthesizedDefaults.${targetName};
          };
        })
        runtimeTargetNames
    );

  runtimeTargetsWithUpdatedRoutingAuthority =
    builtins.listToAttrs (
      builtins.map
        (targetName:
          let
            target = runtimeTargetsWithSynthesizedDefaults.${targetName};
            existingRoutingAuthority =
              if builtins.isAttrs (target.routingAuthority or null) then target.routingAuthority else { };
            resolvedRoutingAuthority =
              if hasAttr targetName updatedRoutingAuthority && builtins.isAttrs updatedRoutingAuthority.${targetName} then
                updatedRoutingAuthority.${targetName}
              else
                { };
            defaultReachability =
              if builtins.hasAttr "defaultReachability" resolvedRoutingAuthority then
                resolvedRoutingAuthority.defaultReachability
              else if builtins.hasAttr "defaultReachability" existingRoutingAuthority then
                existingRoutingAuthority.defaultReachability
              else if builtins.hasAttr "defaultReachability" target then
                target.defaultReachability
              else
                false;
          in
          {
            name = targetName;
            value = target // {
              routingAuthority = existingRoutingAuthority // resolvedRoutingAuthority // { inherit defaultReachability; };
            };
          })
        runtimeTargetNames
    );

  defaultReachabilityByNode =
    builtins.listToAttrs (
      builtins.map
        (targetName:
          let
            target = runtimeTargetsWithUpdatedRoutingAuthority.${targetName};
            targetPath = "${sitePath}.runtimeTargets.${targetName}";
            logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
            nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
          in
          {
            name = nodeName;
            value = target.routingAuthority.defaultReachability or false;
          })
        runtimeTargetNames
    );

  forwardingSemanticsNodeNames =
    sortedNames (makeStringSet ((sortedNames runtimeTargetsByNode) ++ (sortedNames forwardingSemanticsNodes)));

  updatedForwardingSemanticsNodes =
    builtins.listToAttrs (
      builtins.map
        (nodeName:
          let
            existingNodeSemantics =
              if hasAttr nodeName forwardingSemanticsNodes then attrsOrEmpty forwardingSemanticsNodes.${nodeName} else { };
            existingRoutingAuthority = attrsOrEmpty (existingNodeSemantics.routingAuthority or null);
            defaultReachability =
              if hasAttr nodeName defaultReachabilityByNode then
                defaultReachabilityByNode.${nodeName}
              else if builtins.hasAttr "defaultReachability" existingRoutingAuthority then
                existingRoutingAuthority.defaultReachability
              else
                false;
          in
          {
            name = nodeName;
            value =
              existingNodeSemantics
              // {
                routingAuthority = existingRoutingAuthority // { inherit defaultReachability; };
              };
          })
        forwardingSemanticsNodeNames
    );

in
{
  runtimeTargets = runtimeTargetsWithUpdatedRoutingAuthority;
  forwardingSemantics = forwardingSemantics // { nodes = updatedForwardingSemanticsNodes; };
}
