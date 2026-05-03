{ helpers, common, sitePath }:

let
  inherit (helpers) ensureUniqueEntries hasAttr isNonEmptyString requireAttrs requireString sortedNames;
  inherit (common) failForwarding failInventory;

  normalizeDeclaredContainer = nodePath: _nodeName: containerIndex: containerValue:
    let
      containerPath = "${nodePath}.containers[${toString containerIndex}]";
      container =
        if builtins.isAttrs containerValue then
          requireAttrs containerPath containerValue
        else if builtins.isString containerValue then
          { name = requireString containerPath containerValue; }
        else
          failForwarding containerPath "container declarations must be strings or attribute sets with explicit names";
    in
    if !isNonEmptyString (container.name or null) then
      failForwarding "${containerPath}.name" "container name is required"
    else
      {
        logicalName = container.name;
      }
      // (if builtins.isString (container.kind or null) && container.kind != "" then { kind = container.kind; } else { })
      // (if builtins.isList (container.services or null) then { services = container.services; } else { })
      // (if builtins.isAttrs (container.meta or null) then { meta = container.meta; } else { });

  resolveRuntimeContainers = { nodePath, nodeName, realizedTarget, targetId, targetDef, nodeAttrs }:
    let
      declaredContainersRaw = if builtins.isList (nodeAttrs.containers or null) then nodeAttrs.containers else [ ];
      declaredContainers =
        builtins.map
          (idx: normalizeDeclaredContainer nodePath nodeName idx (builtins.elemAt declaredContainersRaw idx))
          (builtins.genList (idx: idx) (builtins.length declaredContainersRaw));
      declaredByName =
        ensureUniqueEntries
          "${nodePath}.containers"
          (builtins.map (container: { name = container.logicalName; value = container; }) declaredContainers);
      realizedBindings = if realizedTarget then targetDef.containerBindings or { } else { };
      _coverage =
        if realizedTarget then
          builtins.deepSeq
            (builtins.map
              (containerName:
                if hasAttr containerName realizedBindings then
                  true
                else
                  failInventory
                    "${targetDef.nodePath}.containers.${containerName}"
                    "runtime target '${targetId}' must explicitly realize forwarding-model container '${containerName}'")
              (sortedNames declaredByName))
            true
        else
          true;
      _noUnexpected =
        if realizedTarget then
          builtins.deepSeq
            (builtins.map
              (containerName:
                if hasAttr containerName declaredByName then
                  true
                else
                  failInventory
                    "${targetDef.nodePath}.containers.${containerName}"
                    "references unknown forwarding-model container '${containerName}' on logical node '${nodeName}'")
              (sortedNames realizedBindings))
            true
        else
          true;
      merged =
        builtins.map
          (containerName:
            let
              declared = declaredByName.${containerName};
              realized = if hasAttr containerName realizedBindings then realizedBindings.${containerName} else null;
              runtimeName =
                if realized != null then
                  requireString "${targetDef.nodePath}.containers.${containerName}.runtimeName" (realized.runtimeName or null)
                else
                  containerName;
            in
            declared // { name = containerName; logicalName = containerName; runtimeName = runtimeName; container = runtimeName; })
          (sortedNames declaredByName);
    in
    builtins.seq _coverage (builtins.seq _noUnexpected merged);
in
{
  inherit resolveRuntimeContainers;
}
