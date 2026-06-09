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
                  ipv4 =
                    [
                      {
                        dst = "${customerAddress}/32";
                        proto = "pppoe-session";
                        intent = {
                          kind = "connected-reachability";
                          source = "pppoe-server-session";
                        };
                      }
                    ]
                    ++ lib.optional ((peerClient.defaultRoute or false) == true) {
                      dst = "0.0.0.0/0";
                      proto = "pppoe-session";
                      intent = {
                        kind = "default-reachability";
                        source = "pppoe-server-session";
                      };
                    };
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
              } // {
                boundaryIdentity = {
                virtualAdapter = true;
                hostFacing = false;
                  kind = "virtual-adapter-hygiene-boundary";
                  adapterClass = "pppoe-tunnel-adapter";
                  sourceKind = "pppoe-session";
                  logicalInterface = runtimeInterface;
                  boundary = "pppoe-session";
                  owningRole = nodeRole;
                };
                sourceScopeAuthority = {
                  authority = "control-plane-model";
                  mode = "structured-source-scope";
                  sourceRequired = true;
                  failClosedWhenAbsent = true;
                  sourceClass = "pppoe-session-adapter";
                };
                hygieneDecision = {
                  enforcement = "fail-closed";
                  interfaceTupleOnlyAuthority = false;
                };
                spoofing = {
                  rejection = "fail-closed";
                  interfaceTupleOnlyBypass = false;
                };
                hygieneBoundary = {
                  provenance = {
                    route.gate = "route-intent-and-policy-only-classification";
                    firewall.gate = "relation-handoff";
                    nat.gate = "route-safety";
                    providerEgress.gate = "provider-egress-source";
                  };
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
              } // {
                boundaryIdentity = {
                virtualAdapter = true;
                hostFacing = false;
                  kind = "virtual-adapter-hygiene-boundary";
                  adapterClass = "pppoe-tunnel-adapter";
                  sourceKind = "pppoe-session";
                  logicalInterface = runtimeInterface;
                  boundary = "pppoe-session";
                  owningRole = nodeRole;
                };
                sourceScopeAuthority = {
                  authority = "control-plane-model";
                  mode = "structured-source-scope";
                  sourceRequired = true;
                  failClosedWhenAbsent = true;
                  sourceClass = "pppoe-session-adapter";
                };
                hygieneDecision = {
                  enforcement = "fail-closed";
                  interfaceTupleOnlyAuthority = false;
                };
                spoofing = {
                  rejection = "fail-closed";
                  interfaceTupleOnlyBypass = false;
                };
                hygieneBoundary = {
                  provenance = {
                    route.gate = "route-intent-and-policy-only-classification";
                    firewall.gate = "relation-handoff";
                    nat.gate = "route-safety";
                    providerEgress.gate = "provider-egress-source";
                  };
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
      effectiveRuntimeInterfaces =
        if pppoeSessionInterfaceEntry == null then
          routeFilteredRuntimeInterfaces
        else
          routeFilteredRuntimeInterfaces // { ${pppoeSessionInterfaceEntry.name} = pppoeSessionInterfaceEntry.value; };
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
          effectiveRuntimeInterfaces
          nodeRole
          runtimeContainers
          runtimeOriginEgressContract
          runtimeStatePolicy
          ;
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
