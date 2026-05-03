{
  helpers,
  common,
  sitePath,
  overlayProvisioning,
  resolveBackingRef,
  requireExplicitHostUplinkAddressing,
}:

let
  inherit (helpers) hasAttr isNonEmptyString requireAttrs requireRoutes requireString;
  inherit (common) attrsOrEmpty failInventory mergeRoutes;

  portBindingForInterface =
    { sourceKind, backingRef, ifName, portBindings }:
    if sourceKind == "p2p" then
      if hasAttr backingRef.name portBindings.byLink then portBindings.byLink.${backingRef.name} else null
    else if sourceKind == "wan" then
      if hasAttr (backingRef.upstreamAlias or "") portBindings.byUplink then portBindings.byUplink.${backingRef.upstreamAlias} else null
    else if sourceKind == "tenant" && hasAttr ifName portBindings.byLogicalInterface then
      portBindings.byLogicalInterface.${ifName}
    else
      null;

  overlayAddress =
    { sourceKind, backingRef, nodeName, family }:
    let
      overlayNodes =
        if sourceKind == "overlay" && hasAttr (backingRef.name or "") overlayProvisioning then
          attrsOrEmpty (overlayProvisioning.${backingRef.name}.nodes or null)
        else
          { };
      nodeOverlay = attrsOrEmpty (overlayNodes.${nodeName} or null);
    in
    if family == 4 then nodeOverlay.addr4 or null else nodeOverlay.addr6 or null;
in
{ nodeName, ifName, iface, portBindings, targetHostName, targetId, realizedTarget }:
let
  ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
  ifaceAttrs = requireAttrs ifacePath iface;
  sourceKind = requireString "${ifacePath}.kind" (ifaceAttrs.kind or null);
  sourceIfName = requireString "${ifacePath}.interface" (ifaceAttrs.interface or null);
  backingRef = resolveBackingRef nodeName ifName ifaceAttrs;
  portBinding = portBindingForInterface { inherit sourceKind backingRef ifName portBindings; };

  requiresExplicitPortRealization = realizedTarget && (sourceKind == "p2p" || sourceKind == "wan");
  _requiredPortBinding =
    if requiresExplicitPortRealization && portBinding == null then
      if sourceKind == "p2p" then
        failInventory "${targetId}.ports" "${ifacePath} on realized target '${targetId}' requires explicit port realization for backing link '${backingRef.id}'"
      else
        failInventory "${targetId}.ports" "${ifacePath} on realized target '${targetId}' requires explicit uplink port realization for uplink '${backingRef.upstreamAlias}'"
    else
      true;

  runtimeIfName = if portBinding != null then portBinding.runtimeIfName else sourceIfName;
  overlayAddr4 = overlayAddress { inherit sourceKind backingRef nodeName; family = 4; };
  overlayAddr6 = overlayAddress { inherit sourceKind backingRef nodeName; family = 6; };
  effectiveAddr4 =
    if sourceKind == "overlay" && isNonEmptyString overlayAddr4 then overlayAddr4
    else if portBinding != null && isNonEmptyString (portBinding.interfaceAddr4 or null) then portBinding.interfaceAddr4
    else ifaceAttrs.addr4 or null;
  effectiveAddr6 =
    if sourceKind == "overlay" && isNonEmptyString overlayAddr6 then overlayAddr6
    else if portBinding != null && isNonEmptyString (portBinding.interfaceAddr6 or null) then portBinding.interfaceAddr6
    else ifaceAttrs.addr6 or null;

  resolvedHostUplink = if portBinding != null && builtins.isAttrs (portBinding.hostUplink or null) then portBinding.hostUplink else null;
  validatedHostUplink =
    if realizedTarget && sourceKind == "wan" then
      if resolvedHostUplink == null then
        failInventory
          "inventory.deployment.hosts.${targetHostName}.uplinks"
          "${ifacePath} on realized target '${targetId}' requires explicit host uplink bridge mapping in inventory.deployment.hosts.${targetHostName}.uplinks"
      else
        builtins.seq
          (requireExplicitHostUplinkAddressing { inherit ifacePath targetHostName targetId; hostUplink = resolvedHostUplink; })
          resolvedHostUplink
    else
      resolvedHostUplink;

  interfaceRoutes = requireRoutes ifacePath (ifaceAttrs.routes or null);
  effectiveRoutes =
    if portBinding != null && builtins.isAttrs (portBinding.interfaceRoutes or null) then
      mergeRoutes interfaceRoutes portBinding.interfaceRoutes
    else
      interfaceRoutes;

  value =
    {
      runtimeTarget = targetId;
      logicalNode = nodeName;
      sourceInterface = ifName;
      sourceKind = sourceKind;
      runtimeIfName = runtimeIfName;
      renderedIfName = runtimeIfName;
      addr4 = effectiveAddr4;
      addr6 = effectiveAddr6;
      routes = effectiveRoutes;
      backingRef = builtins.removeAttrs backingRef [ "linkKind" "upstreamAlias" ];
    }
    // (if portBinding != null && isNonEmptyString (portBinding.adapterName or null) then { adapterName = portBinding.adapterName; } else { })
    // (if portBinding != null && builtins.isAttrs (portBinding.attach or null) then { attach = portBinding.attach; } else { })
    // (if sourceKind == "wan" then { upstream = requireString "${ifacePath}.upstream" (ifaceAttrs.upstream or null); } else { })
    // (if sourceKind == "wan" && builtins.isAttrs (ifaceAttrs.wan or null) then { wan = ifaceAttrs.wan; } else { })
    // (if sourceKind == "tenant" && ((ifaceAttrs.logical or false) == true) then { logical = true; } else { })
    // (if sourceKind == "wan" && validatedHostUplink != null then { hostUplink = validatedHostUplink; } else { })
    // (if sourceKind == "wan" && builtins.isAttrs (validatedHostUplink.ipv4 or null) then { ipv4 = validatedHostUplink.ipv4; } else { })
    // (if sourceKind == "wan" && builtins.isAttrs (validatedHostUplink.ipv6 or null) then { ipv6 = validatedHostUplink.ipv6; } else { });
in
builtins.seq _requiredPortBinding { name = ifName; value = value; }
