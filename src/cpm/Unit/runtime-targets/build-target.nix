{ lib, helpers, common, realizationIndex, enterpriseName, siteName, sitePath, nodes, routingMode, bgpSiteAsn, uplinkRouting, overlayProvisioning, siteOverlays, attachments, routedPrefixesByTenant, buildExplicitInterfaceEntry, buildSyntheticUplinkInterfaceEntry, buildInventoryOverlayRuntimeAdapterEntry, resolveRuntimeContainers, resolveRuntimeServices, bgpNetworksForNode, bgpNeighborsForNode, filterRoutesForBgp, routerRoleSet, ... }:

let
  inherit (helpers)
    hasAttr
    isNonEmptyString
    logicalKey
    requireAttrs
    requireString
    sortedNames
    ;
  inherit (common) attrsOrEmpty failInventory;
  buildContext = import ./build-context.nix {
    inherit
      lib
      helpers
      common
      sitePath
      uplinkRouting
      overlayProvisioning
      attachments
      routedPrefixesByTenant
      ;
  };
  inherit (buildContext)
    defaultPortBindings
    hasExplicitWANForUplink
    ebgpNeighborsForTarget
    addOverlayUnderlayEndpointRoutes
    overlayNames
    runtimeOriginEgress
    ;

  buildServices = import ./build-services.nix {
    inherit resolveRuntimeServices;
  };

  buildValue = import ./build-value.nix {
    inherit
      requireString
      bgpSiteAsn
      bgpNeighborsForNode
      ebgpNeighborsForTarget
      bgpNetworksForNode
      ;
  };
  binderSourceAudit = import ../../binder-source-audit.nix { inherit helpers; };
  firstOrNull = values: if values == [ ] then null else builtins.head values;
  stripPrefixLength = value:
    if !(isNonEmptyString value) then "" else builtins.head (lib.splitString "/" value);
  pppoeServiceForTarget = targetName:
    attrsOrEmpty ((attrsOrEmpty (realizationIndex.targetDefs.${targetName}.node.services or null)).pppoe or null);
  pppoePeerTargetsFor = role: interface:
    builtins.filter
      (
        targetName:
        let
          service = pppoeServiceForTarget targetName;
          peer = attrsOrEmpty (service.${role} or null);
        in
        peer != { } && (peer.interface or null) == interface
      )
      (sortedNames realizationIndex.targetDefs);
  buildRuntimeTarget =
    nodeName:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      nodeAttrs = requireAttrs nodePath nodes.${nodeName};
      nodeRoleRaw = nodeAttrs.role or null;
      nodeRole = if builtins.isString nodeRoleRaw then nodeRoleRaw else "";
      isBgpRouter = routingMode == "bgp" && isNonEmptyString nodeRole && hasAttr nodeRole routerRoleSet;
      logical = {
        enterprise = enterpriseName;
        site = siteName;
        name = nodeName;
      };
      logicalId = logicalKey logical;
      realizedTarget = hasAttr logicalId realizationIndex.byLogical;
      targetId = if realizedTarget then realizationIndex.byLogical.${logicalId} else nodeName;
      targetDef = if realizedTarget then realizationIndex.targetDefs.${targetId} else null;
      targetHostName =
        if realizedTarget then
          requireString "${targetDef.nodePath}.host" (targetDef.node.host or null)
        else
          null;
      targetPlatform =
        if realizedTarget then
          requireString "${targetDef.nodePath}.platform" (targetDef.node.platform or null)
        else
          null;
      portBindings = if realizedTarget then targetDef.portBindings else defaultPortBindings;
      nodeInterfaces = requireAttrs "${nodePath}.interfaces" (nodeAttrs.interfaces or null);
      explicitEntries = builtins.map (
        ifName:
        buildExplicitInterfaceEntry {
          inherit
            nodeName
            nodeRole
            ifName
            portBindings
            targetDef
            targetHostName
            targetId
            realizedTarget
            ;
          iface = nodeInterfaces.${ifName};
        }
      ) (sortedNames nodeInterfaces);
      explicitOverlayNames =
        builtins.filter
          (overlayName: overlayName != null)
          (builtins.map
            (ifName:
              let
                iface = attrsOrEmpty nodeInterfaces.${ifName};
              in
              if (iface.kind or null) == "overlay" then iface.overlay or null else null)
            (sortedNames nodeInterfaces));
      uplinkAttrs = if builtins.isAttrs (nodeAttrs.uplinks or null) then nodeAttrs.uplinks else { };
      syntheticEntries =
        builtins.map
          (
            uplinkName:
            buildSyntheticUplinkInterfaceEntry {
              inherit
                nodeName
                uplinkName
                portBindings
                targetHostName
                targetId
                realizedTarget
                ;
              uplinkValue = uplinkAttrs.${uplinkName};
            }
          )
          (
            builtins.filter (
              uplinkName:
              !(builtins.elem uplinkName overlayNames) && !hasExplicitWANForUplink nodeInterfaces uplinkName
            ) (sortedNames uplinkAttrs)
          );
      inventoryOverlayEntries =
        builtins.map
          (overlayName:
            let
              entryName = "overlay-${overlayName}";
              _noCollision =
                if builtins.hasAttr entryName nodeInterfaces || builtins.hasAttr entryName uplinkAttrs then
                  failInventory
                    "inventory.controlPlane.sites.${enterpriseName}.${siteName}.overlays.${overlayName}.runtimeNodes.${nodeName}"
                    "FS-267-HDS-010-SDS-010-SMS-010: inventory overlay runtime adapter '${entryName}' collides with an existing forwarding-model interface or uplink"
                else
                  true;
            in
            builtins.seq _noCollision (
              buildInventoryOverlayRuntimeAdapterEntry {
                inherit nodeName nodeRole targetId overlayName;
                overlayCfg = siteOverlays.${overlayName};
              }
            ))
          (
            builtins.filter
              (overlayName:
                let
                  runtimeNodes = attrsOrEmpty ((attrsOrEmpty siteOverlays.${overlayName}).runtimeNodes or null);
                in
                !(builtins.elem overlayName explicitOverlayNames)
                && builtins.isAttrs (runtimeNodes.${nodeName} or null))
              (sortedNames siteOverlays)
          );
      loopback = requireAttrs "${nodePath}.loopback" (nodeAttrs.loopback or null);
      runtimeInterfacesBase = addOverlayUnderlayEndpointRoutes nodeRole (
        builtins.listToAttrs (explicitEntries ++ syntheticEntries ++ inventoryOverlayEntries)
      );
      runtimeOriginEgressContract = runtimeOriginEgress.contractFor {
        inherit nodeRole uplinkAttrs loopback;
        interfaces = runtimeInterfacesBase;
      };
      runtimeInterfaces = runtimeOriginEgress.applyToInterfaces runtimeOriginEgressContract runtimeInterfacesBase;
      routeFilteredRuntimeInterfaces =
        if isBgpRouter then
          lib.mapAttrs (
            _: iface: iface // { routes = filterRoutesForBgp (iface.routes or { }); }
          ) runtimeInterfaces
        else
          runtimeInterfaces;
      pppoeService = if realizedTarget then pppoeServiceForTarget targetId else { };
      pppoeServer = attrsOrEmpty (pppoeService.server or null);
      pppoeClient = attrsOrEmpty (pppoeService.client or null);
      pppoeSessionInterfaceEntry =
        if pppoeServer != { } then
          let
            peerTargetName = firstOrNull (pppoePeerTargetsFor "client" pppoeServer.interface);
            peerClient =
              if peerTargetName == null then { } else attrsOrEmpty ((pppoeServiceForTarget peerTargetName).client or null);
            runtimeInterface = peerClient.runtimeInterface or null;
            providerAddress = stripPrefixLength (pppoeServer.providerAddress or "");
            customerAddress = stripPrefixLength (pppoeServer.customerAddress or "");
          in
          if !(isNonEmptyString runtimeInterface) then
            null
          else
            {
              name = runtimeInterface;
              value = {
                runtimeTarget = targetId;
                logicalNode = nodeName;
                sourceInterface = runtimeInterface;
                sourceKind = "pppoe-session";
                runtimeIfName = runtimeInterface;
                renderedIfName = runtimeInterface;
                addr4 = "${providerAddress}/32";
                routes = {
                  ipv4 = [
                    {
                      dst = "${customerAddress}/32";
                      proto = "pppoe-session";
                      intent = {
                        kind = "connected-reachability";
                        source = "pppoe-server-session";
                      };
                    }
                  ];
                  ipv6 = [ ];
                };
                backingRef = {
                  kind = "pppoe-session";
                  id = "pppoe-session::${targetId}::${runtimeInterface}";
                  name = pppoeServer.interface;
                  peerRuntimeTarget = peerTargetName;
                };
                ipv4 = {
                  address = "${providerAddress}/32";
                  peer = "${customerAddress}/32";
                };
                pppoe = {
                  role = "server";
                  serviceInterface = pppoeServer.interface;
                  peerRuntimeTarget = peerTargetName;
                };
              } // binderSourceAudit.make {
                path = "${targetDef.nodePath}.services.pppoe.server";
                field = "effectiveRuntimeRealization.interfaces.${runtimeInterface}";
                binderSourceClass = "public-inventory";
                binderSourcePath = "${targetDef.nodePath}.services.pppoe.server";
                upstreamBehaviorRef = "${targetDef.nodePath}.services.pppoe.server";
              };
            }
        else if pppoeClient != { } then
          let
            peerTargetName = firstOrNull (pppoePeerTargetsFor "server" pppoeClient.interface);
            peerServer =
              if peerTargetName == null then { } else attrsOrEmpty ((pppoeServiceForTarget peerTargetName).server or null);
            runtimeInterface = pppoeClient.runtimeInterface or null;
            providerAddress = stripPrefixLength (peerServer.providerAddress or "");
            customerAddress = stripPrefixLength (peerServer.customerAddress or "");
          in
          if !(isNonEmptyString runtimeInterface) || peerServer == { } then
            null
          else
            {
              name = runtimeInterface;
              value = {
                runtimeTarget = targetId;
                logicalNode = nodeName;
                sourceInterface = runtimeInterface;
                sourceKind = "pppoe-session";
                runtimeIfName = runtimeInterface;
                renderedIfName = runtimeInterface;
                addr4 = "${customerAddress}/32";
                routes = {
                  ipv4 =
                    [
                      {
                        dst = "${providerAddress}/32";
                        proto = "pppoe-session";
                        intent = {
                          kind = "connected-reachability";
                          source = "pppoe-client-session";
                        };
                      }
                    ]
                    ++ lib.optional ((pppoeClient.defaultRoute or false) == true) {
                      dst = "0.0.0.0/0";
                      proto = "pppoe-session";
                      intent = {
                        kind = "default-reachability";
                        source = "pppoe-client-session";
                      };
                    };
                  ipv6 = [ ];
                };
                backingRef = {
                  kind = "pppoe-session";
                  id = "pppoe-session::${targetId}::${runtimeInterface}";
                  name = pppoeClient.interface;
                  peerRuntimeTarget = peerTargetName;
                };
                ipv4 = {
                  address = "${customerAddress}/32";
                  peer = "${providerAddress}/32";
                };
                pppoe = {
                  role = "client";
                  serviceInterface = pppoeClient.interface;
                  peerRuntimeTarget = peerTargetName;
                };
              } // binderSourceAudit.make {
                path = "${targetDef.nodePath}.services.pppoe.client";
                field = "effectiveRuntimeRealization.interfaces.${runtimeInterface}";
                binderSourceClass = "public-inventory";
                binderSourcePath = "${targetDef.nodePath}.services.pppoe.client";
                upstreamBehaviorRef = "${targetDef.nodePath}.services.pppoe.client";
              };
            }
        else
          null;
      effectiveRuntimeInterfacesUnfiltered =
        if pppoeSessionInterfaceEntry == null then
          routeFilteredRuntimeInterfaces
        else
          routeFilteredRuntimeInterfaces // { ${pppoeSessionInterfaceEntry.name} = pppoeSessionInterfaceEntry.value; };
      removeDefaultRoutesOnPppoeCoreP2ps =
        ifaces:
        let
          pppoeLinkNames = builtins.listToAttrs (
            builtins.filter (e: e != null) (
              builtins.map (targetName:
                let
                  svc = pppoeServiceForTarget targetName;
                  linkName = (svc.client or {}).interface or (svc.server or {}).interface or null;
                in
                if isNonEmptyString linkName then { name = linkName; value = true; } else null
              ) (sortedNames realizationIndex.targetDefs)
            )
          );
          isPppoeLink = iface:
            (iface.sourceKind or "") == "p2p"
            && builtins.hasAttr (iface.backingRef.name or "") pppoeLinkNames;
          stripDefaultRoutes = iface:
            let
              routes = iface.routes or {};
              ipv4 = builtins.filter
                (r: ((r.intent or {}).kind or "") != "default-reachability")
                (routes.ipv4 or []);
              ipv6 = builtins.filter
                (r: ((r.intent or {}).kind or "") != "default-reachability")
                (routes.ipv6 or []);
            in
            iface // { routes = routes // { inherit ipv4 ipv6; }; };
        in
        builtins.mapAttrs (_: iface:
          if isPppoeLink iface then stripDefaultRoutes iface else iface
        ) ifaces;
      addDefaultViaDownstreamSelector =
        ifaces:
        let
          hasPppoeService =
            (pppoeServiceForTarget targetId) != {};
          downstreamSelectorNodeName = sitePath + ".nodes." + "downstream-selector";
          isDownstreamSelectorP2p = iface:
            (iface.sourceKind or "") == "p2p"
            && (let
                  lane = iface.backingRef.lane or {};
                  kind = lane.kind or null;
                in kind == "access-edge" || kind == "access")
            && nodeRole != "downstream-selector";
          peerAddr = iface:
            let
              addr = iface.addr4 or "";
              parts = lib.splitString "/" addr;
              addrStr = if builtins.length parts >= 1 then builtins.elemAt parts 0 else "";
              addrOctets = lib.splitString "." addrStr;
            in
            if builtins.length addrOctets != 4 then null
            else
              let
                lastOctet = builtins.elemAt addrOctets 3;
                lastInt = lib.toInt (if lastOctet == "" then "0" else lastOctet);
                peerInt = if lib.mod lastInt 2 == 0 then lastInt + 1 else lastInt - 1;
                peerOctets = builtins.genList (i:
                  if i == 3 then toString peerInt
                  else builtins.elemAt addrOctets i
                ) 4;
              in builtins.concatStringsSep "." peerOctets;
          peerAddr6 = iface:
            null;  # IPv6 peer calculation deferred; IPv4 default route is sufficient for HAT egress
          addDefaultRoute = iface:
            let
              routes = iface.routes or {};
              ipv4 = (routes.ipv4 or []) ++
                lib.optional (peerAddr iface != null) {
                  dst = "0.0.0.0/0";
                  proto = "default";
                  intent.kind = "default-reachability";
                  via4 = peerAddr iface;
                };
              ipv6 = (routes.ipv6 or []) ++
                lib.optional (peerAddr6 iface != null) {
                  dst = "::/0";
                  proto = "default";
                  intent.kind = "default-reachability";
                  via6 = peerAddr6 iface;
                };
            in
            iface // { routes = routes // { inherit ipv4 ipv6; }; };
        in
        if !hasPppoeService then ifaces
        else
          builtins.mapAttrs (_: iface:
            if isDownstreamSelectorP2p iface then addDefaultRoute iface else iface
          ) ifaces;
      effectiveRuntimeInterfaces =
        addDefaultViaDownstreamSelector (removeDefaultRoutesOnPppoeCoreP2ps effectiveRuntimeInterfacesUnfiltered);
      placement =
        if realizedTarget then
          {
            kind = "inventory-realization";
            target = targetId;
            host = targetHostName;
            platform = targetPlatform;
          } // binderSourceAudit.make {
            path = "${nodePath}.placement";
            field = "placement";
            binderSourceClass = "public-inventory";
            binderSourcePath = targetDef.nodePath;
            upstreamBehaviorRef = nodePath;
          }
        else
          {
            kind = "logical-node";
            target = nodeName;
          };
      runtimeContainers = resolveRuntimeContainers {
        inherit
          nodePath
          nodeName
          realizedTarget
          targetId
          targetDef
          nodeAttrs
          ;
      };
      runtimeServicesResult = buildServices {
        inherit
          nodePath
          nodeName
          nodeAttrs
          realizedTarget
          targetDef
          loopback
          runtimeOriginEgressContract
          ;
      };
      runtimeStatePolicy =
        if realizedTarget && builtins.isAttrs (targetDef.node.statePolicy or null) then
          targetDef.node.statePolicy
        else if realizedTarget && builtins.isAttrs (targetDef.node.state or null) then
          targetDef.node.state
        else
          { };
      value = buildValue {
        inherit
          nodePath
          nodeName
          nodeAttrs
          logical
          isBgpRouter
          placement
          loopback
          nodeRole
          runtimeContainers
          runtimeOriginEgressContract
          runtimeStatePolicy
          ;
        effectiveRuntimeInterfaces =
          let
            ifaceList = builtins.attrValues effectiveRuntimeInterfaces;
            hostP2p = builtins.filter
              (i: (i.hostFacing or false) == true && (i.sourceKind or "") == "p2p")
              ifaceList;
            hasTenant = builtins.any
              (i: (i.sourceKind or "") == "tenant")
              ifaceList;
            nodeRoleStr = nodeRole;
            isCore = builtins.substring 0 4 nodeRoleStr == "core";
            needsCoreEgress = isCore && !hasTenant && builtins.length hostP2p == 1;
            p2pVal = if needsCoreEgress then builtins.head hostP2p else null;
          in
          # Do NOT create a duplicate core-uplink-egress interface that clones
          # the p2p link's addr4. FS-255 SMS-010 requires p2p links be kept OUT
          # of the host-facing interface count. The single p2p interface already
          # serves as the egress path; adding a clone with the same /31 address
          # creates a routing conflict (systemd-networkd sees two interfaces
          # with identical IPs and leaves one stuck in "configuring").
          if needsCoreEgress then
            let
              p2pName = p2pVal.runtimeIfName or p2pVal.renderedIfName or p2pVal.logicalName or "unknown";
            in
            effectiveRuntimeInterfaces // {
              "${p2pName}" = (effectiveRuntimeInterfaces."${p2pName}" or p2pVal) // {
                adapterClass = "core-role-egress";
                direction = "egress";
                hostFacing = true;
                virtualAdapter = false;
              };
            }
          else effectiveRuntimeInterfaces;
        hasRuntimeServices = runtimeServicesResult.present;
        runtimeServices = runtimeServicesResult.value;
      };
    in
    {
      name = targetId;
      value = value;
    };
in
buildRuntimeTarget
