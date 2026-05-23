{ lib, helpers, common, realizationIndex, enterpriseName, siteName, sitePath, nodes, routingMode, bgpSiteAsn, uplinkRouting, overlayProvisioning, attachments, routedPrefixesByTenant, buildExplicitInterfaceEntry, buildSyntheticUplinkInterfaceEntry, resolveRuntimeContainers, resolveRuntimeServices, bgpNetworksForNode, bgpNeighborsForNode, filterRoutesForBgp, routerRoleSet, ... }:

let
  inherit (helpers)
    hasAttr
    isNonEmptyString
    logicalKey
    requireAttrs
    requireString
    sortedNames
    ;
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
            ifName
            portBindings
            targetHostName
            targetId
            realizedTarget
            ;
          iface = nodeInterfaces.${ifName};
        }
      ) (sortedNames nodeInterfaces);
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
      loopback = requireAttrs "${nodePath}.loopback" (nodeAttrs.loopback or null);
      runtimeOriginEgressContract = runtimeOriginEgress.contractFor {
        inherit nodeRole uplinkAttrs loopback;
      };
      runtimeInterfacesBase = addOverlayUnderlayEndpointRoutes nodeRole (
        builtins.listToAttrs (explicitEntries ++ syntheticEntries)
      );
      runtimeInterfaces = runtimeOriginEgress.applyToInterfaces runtimeOriginEgressContract runtimeInterfacesBase;
      effectiveRuntimeInterfaces =
        if isBgpRouter then
          lib.mapAttrs (
            _: iface: iface // { routes = filterRoutesForBgp (iface.routes or { }); }
          ) runtimeInterfaces
        else
          runtimeInterfaces;
      placement =
        if realizedTarget then
          {
            kind = "inventory-realization";
            target = targetId;
            host = targetHostName;
            platform = targetPlatform;
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
      runtimeServices = buildServices {
        inherit
          nodePath
          nodeName
          nodeAttrs
          realizedTarget
          targetDef
          loopback
          ;
      };
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
          runtimeServices
          ;
      };
    in
    {
      name = targetId;
      value = value;
    };

in
buildRuntimeTarget
