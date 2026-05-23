{ resolveRuntimeServices }:

{
  nodePath,
  nodeName,
  nodeAttrs,
  realizedTarget,
  targetDef,
  loopback,
}:
let
  logicalServices = if builtins.isAttrs (nodeAttrs.services or null) then nodeAttrs.services else { };
  inventoryServices =
    if realizedTarget && builtins.isAttrs (targetDef.node.services or null) then
      targetDef.node.services
    else
      { };
  mergedServices = logicalServices // inventoryServices;
  targetDefWithServices =
    if realizedTarget then
      targetDef
      // {
    node = targetDef.node // {
      services = mergedServices;
    };
      }
    else
      targetDef;
  runtimeServices =
    if realizedTarget && mergedServices != { } then
      resolveRuntimeServices {
    inherit nodePath nodeName nodeAttrs;
    inherit loopback;
    targetDef = targetDefWithServices;
      }
    else
      null;
in
runtimeServices
