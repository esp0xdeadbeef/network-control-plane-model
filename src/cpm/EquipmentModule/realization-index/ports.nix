{
  helpers,
  failInventory,
  hostIndex,
  requireRoutes,
}:

let
  inherit (helpers)
    ensureUniqueEntries
    hasAttr
    isNonEmptyString
    requireAttrs
    requireString
    sortedNames
    ;

  validAdapterName = value:
    builtins.isString value && builtins.match "^[a-z][a-z0-9-]*$" value != null;

  hostDefFor = hostName:
    if hasAttr hostName hostIndex then
      hostIndex.${hostName}
    else
      failInventory "inventory.deployment.hosts.${hostName}" "missing host definition for realized target";

  resolveHostUplinkFromBridge = targetHostName: portPath: bridgeName:
    let
      hostDef = hostDefFor targetHostName;
      bridgeDef =
        if hasAttr bridgeName hostDef.bridges then
          hostDef.bridges.${bridgeName}
        else
          failInventory "${portPath}.attach.bridge" "references unknown host bridge '${bridgeName}'";
      parentUplink = bridgeDef.parentUplink or null;
    in
    if isNonEmptyString parentUplink then
      if hasAttr parentUplink hostDef.uplinks then
        hostDef.uplinks.${parentUplink}
      else
        failInventory "${portPath}.attach.bridge" "resolved parent uplink '${parentUplink}' is not declared on host '${targetHostName}'"
    else
      null;

  normalizeAttach = targetHostName: attachPath: attach:
    let
      attachAttrs = requireAttrs attachPath attach;
      kind = requireString "${attachPath}.kind" (attachAttrs.kind or null);
    in
    if kind == "bridge" then
      let
        bridgeName = requireString "${attachPath}.bridge" (attachAttrs.bridge or null);
        hostDef = hostDefFor targetHostName;
        bridgeDef =
          if hasAttr bridgeName hostDef.bridges then
            hostDef.bridges.${bridgeName}
          else
            failInventory "${attachPath}.bridge" "references unknown host bridge '${bridgeName}'";
      in
      {
        kind = "bridge";
        bridge = bridgeName;
      }
      // (if builtins.isInt (bridgeDef.vlan or null) then { vlan = bridgeDef.vlan; } else { })
      // (if isNonEmptyString (bridgeDef.parentUplink or null) then { parentUplink = bridgeDef.parentUplink; } else { })
    else if kind == "direct" then
      { kind = "direct"; }
    else
      failInventory "${attachPath}.kind" "attach.kind must be one of: \"bridge\", \"direct\"";

  normalizeContainerBinding = targetPath: containerName: container:
    let
      containerPath = "${targetPath}.containers.${containerName}";
      containerAttrs = requireAttrs containerPath container;
      runtimeName = requireString "${containerPath}.runtimeName" (containerAttrs.runtimeName or null);
    in
    {
      name = containerName;
      value = {
        logicalName = containerName;
        runtimeName = runtimeName;
      };
    };

  portSelector = portPath: portAttrs:
    if isNonEmptyString (portAttrs.link or null) then
      {
        kind = "link";
        key = portAttrs.link;
      }
    else if isNonEmptyString (portAttrs.logicalInterface or null) then
      {
        kind = "logicalInterface";
        key = portAttrs.logicalInterface;
      }
    else if (portAttrs.external or false) == true then
      {
        kind = "uplink";
        key = requireString "${portPath}.uplink" (portAttrs.uplink or null);
      }
    else if isNonEmptyString (portAttrs.uplink or null) then
      {
        kind = "uplink";
        key = portAttrs.uplink;
      }
    else
      failInventory portPath "port must declare exactly one selector via link, logicalInterface, or uplink/external";

  adapterNameFor = portPath: portAttrs: selector:
    if selector.kind == "link" then
      let
        requiredAdapterName = requireString "${portPath}.adapterName" (portAttrs.adapterName or null);
      in
      if validAdapterName requiredAdapterName then
        requiredAdapterName
      else
        failInventory "${portPath}.adapterName" "must match ^[a-z][a-z0-9-]*$ (example: br-isp-a)"
    else if isNonEmptyString (portAttrs.adapterName or null) then
      failInventory "${portPath}.adapterName" "is only supported for ports that select a p2p link via .link"
    else
      null;

  hostUplinkFor = targetHostName: portPath: selector: attach:
    if selector.kind == "uplink" && attach != null && (attach.kind or null) == "bridge" then
      resolveHostUplinkFromBridge targetHostName portPath attach.bridge
    else if selector.kind == "uplink" then
      let
        hostDef = hostDefFor targetHostName;
        uplinkName = selector.key;
      in
      if hasAttr uplinkName hostDef.uplinks then hostDef.uplinks.${uplinkName} else null
    else if attach != null && (attach.kind or null) == "bridge" then
      resolveHostUplinkFromBridge targetHostName portPath attach.bridge
    else
      null;

  normalizePortBinding = targetPath: targetHostName: portName: port:
    let
      portPath = "${targetPath}.ports.${portName}";
      portAttrs = requireAttrs portPath port;
      interfaceAttrs = requireAttrs "${portPath}.interface" (portAttrs.interface or null);
      runtimeIfName = requireString "${portPath}.interface.name" (interfaceAttrs.name or null);
      attach =
        if builtins.isAttrs (portAttrs.attach or null) then
          normalizeAttach targetHostName "${portPath}.attach" portAttrs.attach
        else
          null;
      interfaceAddr4 = if isNonEmptyString (interfaceAttrs.addr4 or null) then interfaceAttrs.addr4 else null;
      interfaceAddr6 = if isNonEmptyString (interfaceAttrs.addr6 or null) then interfaceAttrs.addr6 else null;
      interfaceRoutes =
        if builtins.isAttrs (interfaceAttrs.routes or null) then
          requireRoutes "${portPath}.interface.routes" interfaceAttrs.routes
        else
          null;
      selector = portSelector portPath portAttrs;
      adapterName = adapterNameFor portPath portAttrs selector;
      hostUplink = hostUplinkFor targetHostName portPath selector attach;
    in
    {
      name = portName;
      value =
        {
          inherit selector runtimeIfName;
        }
        // (if attach != null then { inherit attach; } else { })
        // (if interfaceAddr4 != null then { inherit interfaceAddr4; } else { })
        // (if interfaceAddr6 != null then { inherit interfaceAddr6; } else { })
        // (if interfaceRoutes != null then { inherit interfaceRoutes; } else { })
        // (if hostUplink != null then { inherit hostUplink; } else { })
        // (if adapterName != null then { inherit adapterName; } else { });
    };

  buildSelectorIndex = targetPath: portDefs: kind:
    ensureUniqueEntries "${targetPath}.ports" (
      builtins.filter
        (entry: entry != null)
        (builtins.map
          (portName:
            let
              portDef = portDefs.${portName};
            in
            if portDef.selector.kind == kind then
              {
                name = portDef.selector.key;
                value = portDef;
              }
            else
              null)
          (sortedNames portDefs))
    );

in
{
  inherit
    buildSelectorIndex
    normalizeContainerBinding
    normalizePortBinding
    ;
}
