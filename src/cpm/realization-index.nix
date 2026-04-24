{ helpers, inventory }:

let
  inherit (helpers)
    ensureUniqueEntries
    hasAttr
    isNonEmptyString
    optionalAttrs
    requireAttrs
    requireString
    sortedNames
    ;

  failInventory = path: message:
    throw "inventory.nix update required: ${path}: ${message}";

  validAdapterName = value:
    builtins.isString value && builtins.match "^[a-z][a-z0-9-]*$" value != null;

  requireInt = path: value:
    if builtins.isInt value then
      value
    else
      failInventory path "must be an integer";

  normalizeRoute = family: routePath: routeValue:
    let
      route =
        if builtins.isAttrs routeValue then
          routeValue
        else
          failInventory routePath "must be an attribute set";

      dst =
        requireString "${routePath}.prefix" (route.prefix or null);

      via =
        requireString "${routePath}.via" (route.via or null);
    in
    {
      inherit dst;
      intent = {
        kind = "realized-interface-route";
        source = "inventory-realization";
      };
      proto = "realized";
      ${if family == 4 then "via4" else "via6"} = via;
    };

  requireRoutes = path: value:
    let
      routes =
        if builtins.isAttrs value then
          value
        else
          failInventory path "must be an attrset with routes.ipv4/routes.ipv6 lists";

      requireRouteList = routePath: routeValue:
        if builtins.isList routeValue then
          routeValue
        else
          failInventory routePath "must be a list";
    in
    {
      ipv4 =
        builtins.map
          (route: normalizeRoute 4 "${path}.ipv4[]" route)
          (requireRouteList "${path}.ipv4" (routes.ipv4 or [ ]));
      ipv6 =
        builtins.map
          (route: normalizeRoute 6 "${path}.ipv6[]" route)
          (requireRouteList "${path}.ipv6" (routes.ipv6 or [ ]));
    };

  inventoryRoot = optionalAttrs inventory;

  deployment =
    requireAttrs
      "inventory.deployment"
      (inventoryRoot.deployment or { });

  hostsRoot =
    requireAttrs
      "inventory.deployment.hosts"
      (deployment.hosts or { });

  realization =
    requireAttrs
      "inventory.realization"
      (inventoryRoot.realization or { });

  nodesRoot =
    requireAttrs
      "inventory.realization.nodes"
      (realization.nodes or { });

  buildHostUplinkIndex = hostPath: host:
    let
      uplinks =
        if builtins.isAttrs (host.uplinks or null) then
          requireAttrs "${hostPath}.uplinks" host.uplinks
        else
          { };
    in
    builtins.listToAttrs (
      builtins.map
        (uplinkName:
          let
            uplinkPath = "${hostPath}.uplinks.${uplinkName}";
            uplink = requireAttrs uplinkPath uplinks.${uplinkName};
          in
          {
            name = uplinkName;
            value =
              {
                uplinkName = uplinkName;
                name = uplinkName;
                parent = requireString "${uplinkPath}.parent" (uplink.parent or null);
                bridge = requireString "${uplinkPath}.bridge" (uplink.bridge or null);
              }
              // (
                if builtins.isAttrs (uplink.ipv4 or null) then
                  { ipv4 = uplink.ipv4; }
                else
                  { }
              )
              // (
                if builtins.isAttrs (uplink.ipv6 or null) then
                  { ipv6 = uplink.ipv6; }
                else
                  { }
              );
          })
        (sortedNames uplinks)
    );

  buildTransitBridgeIndex = hostPath: uplinkIndex: host:
    let
      transitBridges =
        if builtins.isAttrs (host.transitBridges or null) then
          requireAttrs "${hostPath}.transitBridges" host.transitBridges
        else
          { };
    in
    builtins.listToAttrs (
      builtins.map
        (bridgeName:
          let
            bridgePath = "${hostPath}.transitBridges.${bridgeName}";
            bridge = requireAttrs bridgePath transitBridges.${bridgeName};
            parentUplink =
              requireString
                "${bridgePath}.parentUplink"
                (bridge.parentUplink or null);

            _nameCheck =
              if bridge ? name then
                if bridge.name == bridgeName then
                  true
                else
                  failInventory "${bridgePath}.name" "must equal the attribute name"
              else
                true;

            vlan =
              requireInt "${bridgePath}.vlan" (bridge.vlan or null);

            _parentCheck =
              if hasAttr parentUplink uplinkIndex then
                true
              else
                failInventory "${bridgePath}.parentUplink" "references unknown uplink '${parentUplink}'";
          in
          builtins.seq
            _nameCheck
            (builtins.seq
              _parentCheck
              {
                name = bridgeName;
                value = {
                  kind = "transitBridge";
                  bridge = bridgeName;
                  vlan = vlan;
                  parentUplink = parentUplink;
                };
              }))
        (sortedNames transitBridges)
    );

  buildGenericBridgeIndex = hostPath: host:
    let
      bridgeNetworks =
        if builtins.isAttrs (host.bridgeNetworks or null) then
          requireAttrs "${hostPath}.bridgeNetworks" host.bridgeNetworks
        else
          { };
    in
    builtins.listToAttrs (
      builtins.map
        (bridgeName:
          let
            bridgePath = "${hostPath}.bridgeNetworks.${bridgeName}";
            bridge = requireAttrs bridgePath bridgeNetworks.${bridgeName};
          in
          {
            name = bridgeName;
            value = {
              kind = "bridgeNetwork";
              bridge = bridgeName;
            }
            // (
              if isNonEmptyString (bridge.parentUplink or null) then
                { parentUplink = bridge.parentUplink; }
              else
                { }
            )
            // (
              if builtins.isInt (bridge.vlan or null) then
                { vlan = bridge.vlan; }
              else
                { }
            );
          })
        (sortedNames bridgeNetworks)
    );

  buildUplinkBridgeIndex = uplinkIndex:
    builtins.listToAttrs (
      builtins.map
        (uplinkName:
          let
            uplink = uplinkIndex.${uplinkName};
          in
          {
            name = uplink.bridge;
            value = {
              kind = "uplinkBridge";
              bridge = uplink.bridge;
              parentUplink = uplinkName;
            };
          })
        (sortedNames uplinkIndex)
    );

  mergeBridgeIndexes = indexes:
    ensureUniqueEntries
      "inventory.deployment.hosts.*.(transitBridges|bridgeNetworks|uplinks[*].bridge)"
      (builtins.concatLists (
        builtins.map
          (attrs:
            builtins.map
              (name: {
                inherit name;
                value = attrs.${name};
              })
              (sortedNames attrs))
          indexes
      ));

  buildHostIndex = hostName:
    let
      hostPath = "inventory.deployment.hosts.${hostName}";
      host = requireAttrs hostPath hostsRoot.${hostName};

      uplinks = buildHostUplinkIndex hostPath host;
      transitBridges = buildTransitBridgeIndex hostPath uplinks host;
      bridgeNetworks = buildGenericBridgeIndex hostPath host;
      uplinkBridges = buildUplinkBridgeIndex uplinks;
      bridges = mergeBridgeIndexes [ transitBridges bridgeNetworks uplinkBridges ];
    in
    {
      name = hostName;
      value = {
        uplinks = uplinks;
        bridges = bridges;
      };
    };

  hostIndex =
    builtins.listToAttrs (
      builtins.map
        buildHostIndex
        (sortedNames hostsRoot)
    );

  resolveHostUplinkFromBridge = targetHostName: portPath: bridgeName:
    let
      hostDef =
        if hasAttr targetHostName hostIndex then
          hostIndex.${targetHostName}
        else
          failInventory "inventory.deployment.hosts.${targetHostName}" "missing host definition for realized target";

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
        hostDef =
          if hasAttr targetHostName hostIndex then
            hostIndex.${targetHostName}
          else
            failInventory "inventory.deployment.hosts.${targetHostName}" "missing host definition for realized target";
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
      // (
        if builtins.isInt (bridgeDef.vlan or null) then
          { vlan = bridgeDef.vlan; }
        else
          { }
      )
      // (
        if isNonEmptyString (bridgeDef.parentUplink or null) then
          { parentUplink = bridgeDef.parentUplink; }
        else
          { }
      )
    else if kind == "direct" then
      {
        kind = "direct";
      }
    else
      failInventory "${attachPath}.kind" "attach.kind must be one of: \"bridge\", \"direct\"";

  normalizeContainerBinding = targetPath: containerName: container:
    let
      containerPath = "${targetPath}.containers.${containerName}";
      containerAttrs = requireAttrs containerPath container;
      runtimeName =
        requireString "${containerPath}.runtimeName" (containerAttrs.runtimeName or null);
    in
    {
      name = containerName;
      value = {
        logicalName = containerName;
        runtimeName = runtimeName;
      };
    };

  normalizePortBinding = targetPath: targetHostName: portName: port:
    let
      portPath = "${targetPath}.ports.${portName}";
      portAttrs = requireAttrs portPath port;

      interfaceAttrs =
        requireAttrs "${portPath}.interface" (portAttrs.interface or null);

      runtimeIfName =
        requireString "${portPath}.interface.name" (interfaceAttrs.name or null);

      attach =
        if builtins.isAttrs (portAttrs.attach or null) then
          normalizeAttach targetHostName "${portPath}.attach" portAttrs.attach
        else
          null;

      interfaceAddr4 =
        if isNonEmptyString (interfaceAttrs.addr4 or null) then
          interfaceAttrs.addr4
        else
          null;

      interfaceAddr6 =
        if isNonEmptyString (interfaceAttrs.addr6 or null) then
          interfaceAttrs.addr6
        else
          null;

      interfaceRoutes =
        if builtins.isAttrs (interfaceAttrs.routes or null) then
          requireRoutes "${portPath}.interface.routes" interfaceAttrs.routes
        else
          null;

      selector =
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
          failInventory
            portPath
            "port must declare exactly one selector via link, logicalInterface, or uplink/external";

      adapterName =
        if selector.kind == "link" then
          let
            requiredAdapterName =
              requireString "${portPath}.adapterName" (portAttrs.adapterName or null);
          in
          if validAdapterName requiredAdapterName then
            requiredAdapterName
          else
            failInventory
              "${portPath}.adapterName"
              "must match ^[a-z][a-z0-9-]*$ (example: br-isp-a)"
        else if isNonEmptyString (portAttrs.adapterName or null) then
          failInventory "${portPath}.adapterName" "is only supported for ports that select a p2p link via .link"
        else
          null;

      hostUplink =
        if selector.kind == "uplink" && attach != null && (attach.kind or null) == "bridge" then
          resolveHostUplinkFromBridge targetHostName portPath attach.bridge
        else if selector.kind == "uplink" then
          let
            hostDef =
              if hasAttr targetHostName hostIndex then
                hostIndex.${targetHostName}
              else
                failInventory "inventory.deployment.hosts.${targetHostName}" "missing host definition for realized target";
            uplinkName = selector.key;
          in
          if hasAttr uplinkName hostDef.uplinks then
            hostDef.uplinks.${uplinkName}
          else
            null
        else if attach != null && (attach.kind or null) == "bridge" then
          resolveHostUplinkFromBridge targetHostName portPath attach.bridge
        else
          null;
    in
    {
      name = portName;
      value =
        {
          selector = selector;
          runtimeIfName = runtimeIfName;
        }
        // (
          if attach != null then
            { attach = attach; }
          else
            { }
        )
        // (
          if interfaceAddr4 != null then
            { interfaceAddr4 = interfaceAddr4; }
          else
            { }
        )
        // (
          if interfaceAddr6 != null then
            { interfaceAddr6 = interfaceAddr6; }
          else
            { }
        )
        // (
          if interfaceRoutes != null then
            { interfaceRoutes = interfaceRoutes; }
          else
            { }
        )
        // (
          if hostUplink != null then
            { hostUplink = hostUplink; }
          else
            { }
        )
        // (
          if adapterName != null then
            { adapterName = adapterName; }
          else
            { }
        );
    };

  buildSelectorIndex = targetPath: portDefs: kind:
    ensureUniqueEntries
      "${targetPath}.ports"
      (
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

  buildTargetDef = targetName:
    let
      targetPath = "inventory.realization.nodes.${targetName}";
      target = requireAttrs targetPath nodesRoot.${targetName};

      targetHostName =
        requireString "${targetPath}.host" (target.host or null);

      _hostExists =
        if hasAttr targetHostName hostIndex then
          true
        else
          failInventory "${targetPath}.host" "references unknown deployment host '${targetHostName}'";

      platform =
        requireString "${targetPath}.platform" (target.platform or null);

      logicalNode =
        requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);

      logical = {
        enterprise =
          requireString "${targetPath}.logicalNode.enterprise" (logicalNode.enterprise or null);
        site =
          requireString "${targetPath}.logicalNode.site" (logicalNode.site or null);
        name =
          requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
      };

      ports =
        if builtins.isAttrs (target.ports or null) then
          requireAttrs "${targetPath}.ports" target.ports
        else
          { };

      portDefs =
        builtins.listToAttrs (
          builtins.map
            (portName:
              normalizePortBinding targetPath targetHostName portName ports.${portName})
            (sortedNames ports)
        );

      containers =
        if builtins.isAttrs (target.containers or null) then
          requireAttrs "${targetPath}.containers" target.containers
        else
          { };

      containerBindings =
        builtins.listToAttrs (
          builtins.map
            (containerName:
              normalizeContainerBinding targetPath containerName containers.${containerName})
            (sortedNames containers)
        );
    in
    builtins.seq
      _hostExists
      {
        name = targetName;
        value = {
          node = target;
          nodePath = targetPath;
          host = targetHostName;
          platform = platform;
          logical = logical;
          portBindings = {
            portDefs = portDefs;
            byLink = buildSelectorIndex targetPath portDefs "link";
            byLogicalInterface = buildSelectorIndex targetPath portDefs "logicalInterface";
            byUplink = buildSelectorIndex targetPath portDefs "uplink";
          };
          containerBindings = containerBindings;
        };
      };

  targetDefs =
    builtins.listToAttrs (
      builtins.map
        buildTargetDef
        (sortedNames nodesRoot)
    );

  _validateUniqueLinkAdapterNamesPerHost =
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

  byLogical =
    ensureUniqueEntries
      "inventory.realization.nodes.*.logicalNode"
      (
        builtins.map
          (targetName:
            let
              logical = targetDefs.${targetName}.logical;
            in
            {
              name = "${logical.enterprise}|${logical.site}|${logical.name}";
              value = targetName;
            })
          (sortedNames targetDefs)
      );
in
builtins.seq _validateUniqueLinkAdapterNamesPerHost {
  inherit targetDefs byLogical;
}
