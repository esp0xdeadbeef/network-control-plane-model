{ helpers }:

let
  inherit (helpers) requireAttrs requireString sortedNames;
in
targetPath: target:
let
  effective = requireAttrs "${targetPath}.effectiveRuntimeRealization" (target.effectiveRuntimeRealization or null);
  interfaces = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces" (effective.interfaces or null);
in
builtins.map
  (ifName:
  let iface = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}" interfaces.${ifName};
  in
  iface // {
    sourceInterfaceName = ifName;
    runtimeIfName = requireString "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}.runtimeIfName" (iface.runtimeIfName or null);
    sourceKind = requireString "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}.sourceKind" (iface.sourceKind or null);
  })
  (sortedNames interfaces)
