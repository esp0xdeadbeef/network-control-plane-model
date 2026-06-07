{ helpers
, common
, sitePath
, enterpriseName
, siteName
,
}:

let
  inherit (helpers) isNonEmptyString requireAttrs requireString;
  binderSourceAudit = import ../../../binder-source-audit.nix { inherit helpers; };
in
{ nodeName, nodeRole, targetId, overlayName, overlayCfg }:
let
  runtimeNodePath = "inventory.controlPlane.sites.${enterpriseName}.${siteName}.overlays.${overlayName}.runtimeNodes.${nodeName}";
  runtimeNode = requireAttrs runtimeNodePath overlayCfg.runtimeNodes.${nodeName};
  service = requireAttrs "${runtimeNodePath}.service" (runtimeNode.service or null);
  runtimeIfName = requireString "${runtimeNodePath}.service.interface" (service.interface or null);
  provider = overlayCfg.provider or null;
  adapterClass = if isNonEmptyString provider then "vpn" else "overlay";
  entryName = "overlay-${overlayName}";
  nodeOverlay = common.attrsOrEmpty ((common.attrsOrEmpty (overlayCfg.nodes or null)).${nodeName} or null);
  value =
    {
      runtimeTarget = targetId;
      logicalNode = nodeName;
      sourceInterface = entryName;
      sourceKind = "overlay";
      runtimeIfName = runtimeIfName;
      renderedIfName = runtimeIfName;
      addr4 = nodeOverlay.addr4 or null;
      addr6 = nodeOverlay.addr6 or null;
      routes = {
        ipv4 = [ ];
        ipv6 = [ ];
      };
      backingRef = {
        kind = "overlay";
        id = "overlay::${enterpriseName}.${siteName}::${overlayName}";
        name = overlayName;
      };
      adapterClass = adapterClass;
      owningRole = nodeRole;
      virtualAdapter = true;
      hostFacing = false;
      exclusionReason = "overlay-tunnel-adapter";
      tunnelPurpose = "overlay-reachability";
      overlay = overlayName;
    }
    // (if isNonEmptyString provider then { inherit provider; } else { })
    // (if isNonEmptyString (service.name or null) then { runtimeService = service.name; } else { })
    // (if builtins.isList (runtimeNode.groups or null) then { groups = runtimeNode.groups; } else { })
    // binderSourceAudit.make {
      path = runtimeNodePath;
      field = "effectiveRuntimeRealization.interfaces.${entryName}";
      binderSourceClass = "public-inventory";
      binderSourcePath = runtimeNodePath;
      upstreamBehaviorRef = "${sitePath}.nodes.${nodeName}";
    };
in
{
  name = entryName;
  inherit value;
}
