{ helpers
, common
, sitePath
, overlayProvisioning
, uplinkRouting
, siteIpv6Cfg
, siteTenantsCfg
, routedPrefixesByTenant
, resolveBackingRef
, requireExplicitHostUplinkAddressing
,
}:

let
  inherit (helpers) hasAttr isNonEmptyString requireAttrs requireRoutes requireString;
  inherit (common) attrsOrEmpty failInventory mergeRoutes;
  staticUplinkRoutes = import ./uplink-static-routes.nix { inherit common; };
  runtimeRoutedPrefixRoutesFor = import ./runtime-routed-prefix-routes.nix { inherit helpers common; };
  routeFilter = import ./default-route-filter.nix { inherit helpers common uplinkRouting; };
  binderSourceAudit = import ../../../binder-source-audit.nix { inherit helpers; };
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
  fabricLinkBindingForInterface =
    { sourceKind, backingRef, targetDef }:
    if sourceKind == "p2p" && targetDef != null && hasAttr backingRef.name targetDef.fabricLinkBindings.byLink then
      targetDef.fabricLinkBindings.byLink.${backingRef.name}
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
  overlayRuntimeInterfaceName =
    { sourceKind, backingRef, nodeName }:
    let
      overlay =
        if sourceKind == "overlay" && hasAttr (backingRef.name or "") overlayProvisioning then
          attrsOrEmpty (overlayProvisioning.${backingRef.name} or null)
        else
          { };
      runtimeNode = attrsOrEmpty ((attrsOrEmpty (overlay.runtimeNodes or null)).${nodeName} or null);
      service = attrsOrEmpty (runtimeNode.service or null);
    in
    if isNonEmptyString (service.interface or null) then service.interface else null;
in
{ nodeName, nodeRole, ifName, iface, portBindings, targetDef, targetHostName, targetId, realizedTarget }:
let
  ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
  ifaceAttrs = requireAttrs ifacePath iface;
  sourceKind = requireString "${ifacePath}.kind" (ifaceAttrs.kind or null);
  sourceIfName = requireString "${ifacePath}.interface" (ifaceAttrs.interface or null);
  backingRef = resolveBackingRef nodeName ifName ifaceAttrs;
  portBinding = portBindingForInterface { inherit sourceKind backingRef ifName portBindings; };
  fabricLinkBinding = fabricLinkBindingForInterface { inherit sourceKind backingRef targetDef; };
  isSelectorFabricRole = nodeRole == "downstream-selector" || nodeRole == "upstream-selector";
  hasSelectorFabricLink = isSelectorFabricRole && fabricLinkBinding != null;
  requiresExplicitPortRealization =
    realizedTarget && (sourceKind == "wan" || (sourceKind == "p2p" && !hasSelectorFabricLink));
  _requiredPortBinding =
    if requiresExplicitPortRealization && portBinding == null then
      if sourceKind == "p2p" then
        failInventory "${targetId}.ports" "${ifacePath} on realized target '${targetId}' requires explicit port realization for backing link '${backingRef.id}'"
      else
        failInventory "${targetId}.ports" "${ifacePath} on realized target '${targetId}' requires explicit uplink port realization for uplink '${backingRef.upstreamAlias}'"
    else
      true;
  overlayRuntimeIfName = overlayRuntimeInterfaceName { inherit sourceKind backingRef nodeName; };
  runtimeIfName =
    if overlayRuntimeIfName != null then
      overlayRuntimeIfName
    else if portBinding != null then
      portBinding.runtimeIfName
    else if fabricLinkBinding != null && isNonEmptyString (fabricLinkBinding.runtimeIfName or null) then
      fabricLinkBinding.runtimeIfName
    else
      sourceIfName;
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
  effectiveMtu =
    if portBinding != null && builtins.isInt (portBinding.mtu or null) then
      portBinding.mtu
    else if builtins.isInt (ifaceAttrs.mtu or null) then
      ifaceAttrs.mtu
    else
      null;
  tenantName = if sourceKind == "tenant" then requireString "${ifacePath}.tenant" (ifaceAttrs.tenant or null) else null;
  tenantCfg = if tenantName != null then attrsOrEmpty (siteTenantsCfg.${tenantName} or null) else { };
  modelTenantIpv6Cfg =
    if tenantName != null then
      attrsOrEmpty ((attrsOrEmpty (siteIpv6Cfg.tenants or null)).${tenantName} or null)
    else
      { };
  tenantIpv6Cfg = modelTenantIpv6Cfg // attrsOrEmpty (tenantCfg.ipv6 or null);
  tenantIpv6Mode =
    if builtins.isString (tenantIpv6Cfg.mode or null) && (tenantIpv6Cfg.mode or "") != "" then
      tenantIpv6Cfg.mode
    else if (siteIpv6Cfg.pd or null) == null then
      "slaac"
    else
      "none";
  dynamicAddressing =
    if
      sourceKind == "tenant"
      && ((ifaceAttrs.logical or false) == true)
      && !isNonEmptyString effectiveAddr4
      && !isNonEmptyString effectiveAddr6
    then
      {
        ipv4 = {
          enable = true;
          method = "dhcp";
          dhcp = true;
        };
        ipv6 = {
          enable = tenantIpv6Mode == "slaac";
          method = if tenantIpv6Mode == "slaac" then "slaac" else "none";
          acceptRA = tenantIpv6Mode == "slaac";
          dhcp = false;
          dhcpv6PD = false;
        };
      }
    else
      null;
  runtimeRoutedPrefixRoutes = runtimeRoutedPrefixRoutesFor {
    inherit nodeName tenantName routedPrefixesByTenant;
  };

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
  uplinkStaticRoutes =
    if sourceKind == "wan" && hasAttr (backingRef.upstreamAlias or "") uplinkRouting then
      staticUplinkRoutes uplinkRouting.${backingRef.upstreamAlias}
    else
      { ipv4 = [ ]; ipv6 = [ ]; };
  effectiveRoutesRaw =
    if portBinding != null && builtins.isAttrs (portBinding.interfaceRoutes or null) then
      mergeRoutes (mergeRoutes (mergeRoutes interfaceRoutes portBinding.interfaceRoutes) uplinkStaticRoutes) runtimeRoutedPrefixRoutes
    else
      mergeRoutes (mergeRoutes interfaceRoutes uplinkStaticRoutes) runtimeRoutedPrefixRoutes;
  effectiveRoutes = {
    ipv4 = routeFilter.filterUnavailableDefaultRoutes 4 (effectiveRoutesRaw.ipv4 or null);
    ipv6 = routeFilter.filterUnavailableDefaultRoutes 6 (effectiveRoutesRaw.ipv6 or null);
  };
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
    // binderSourceAudit.make {
      path = ifacePath;
      field = "effectiveRuntimeRealization.interfaces.${ifName}";
      binderSourceClass = if portBinding != null || fabricLinkBinding != null then "public-inventory" else "runtime-facts";
      binderSourcePath =
        if portBinding != null then
          "${targetId}.ports"
        else if fabricLinkBinding != null then
          fabricLinkBinding.sourcePath
        else
          ifacePath;
      upstreamBehaviorRef = ifacePath;
    }
    // (if portBinding != null && isNonEmptyString (portBinding.adapterName or null) then { adapterName = portBinding.adapterName; } else { })
    // (if portBinding != null && builtins.isAttrs (portBinding.attach or null) then { attach = portBinding.attach; } else { })
    // (if effectiveMtu != null then { mtu = effectiveMtu; } else { })
    // (if portBinding != null && builtins.isAttrs (portBinding.vxlan or null) then { vxlan = portBinding.vxlan; } else { })
    // (if fabricLinkBinding != null then { fabricLink = fabricLinkBinding; } else { })
    // (if sourceKind == "wan" then { upstream = requireString "${ifacePath}.upstream" (ifaceAttrs.upstream or null); } else { })
    // (if sourceKind == "wan" && builtins.isAttrs (ifaceAttrs.wan or null) then { wan = ifaceAttrs.wan; } else { })
    // (if sourceKind == "tenant" then { tenant = tenantName; } else { })
    // (if sourceKind == "tenant" && ((ifaceAttrs.logical or false) == true) then { logical = true; } else { })
    // (if dynamicAddressing != null then { inherit dynamicAddressing; } else { })
    // (if sourceKind == "wan" && validatedHostUplink != null then { hostUplink = validatedHostUplink; } else { })
    // (if sourceKind == "wan" && builtins.isAttrs (validatedHostUplink.ipv4 or null) then { ipv4 = validatedHostUplink.ipv4; } else { })
    // (if sourceKind == "wan" && builtins.isAttrs (validatedHostUplink.ipv6 or null) then { ipv6 = validatedHostUplink.ipv6; } else { });
in
builtins.seq _requiredPortBinding { name = ifName; value = value; }
