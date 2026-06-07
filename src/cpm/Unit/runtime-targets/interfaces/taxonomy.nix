{ helpers
, common
,
}:

let
  inherit (helpers) hasAttr isNonEmptyString;
  inherit (common) attrsOrEmpty failInventory;

  virtualRequired =
    { ifacePath, taxonomy }:
    let
      adapterClass = taxonomy.adapterClass or null;
      owningRole = taxonomy.owningRole or null;
      hostFacing = taxonomy.hostFacing or null;
      exclusionReason = taxonomy.exclusionReason or null;
    in
    if (taxonomy.virtualAdapter or false) != true then
      taxonomy
    else if !isNonEmptyString adapterClass then
      failInventory "${ifacePath}.adapterClass" "FS-267-HDS-010-SDS-010-SMS-010: virtual adapter taxonomy requires adapterClass"
    else if !isNonEmptyString owningRole then
      failInventory "${ifacePath}.owningRole" "FS-267-HDS-010-SDS-010-SMS-010: virtual adapter taxonomy requires owningRole"
    else if hostFacing != false then
      failInventory "${ifacePath}.hostFacing" "FS-267-HDS-010-SDS-010-SMS-010: virtual adapter taxonomy requires hostFacing=false"
    else if !isNonEmptyString exclusionReason then
      failInventory "${ifacePath}.exclusionReason" "FS-267-HDS-010-SDS-010-SMS-010: virtual adapter taxonomy requires exclusionReason"
    else
      taxonomy;

  baseTaxonomy =
    { adapterClass
    , nodeRole
    , virtualAdapter ? false
    , hostFacing ? true
    , extra ? { }
    ,
    }:
    {
      inherit adapterClass virtualAdapter hostFacing;
      owningRole = nodeRole;
    } // extra;

  pppoeServiceForInterface = ifName: backingRefName: targetDef:
    let
      services = attrsOrEmpty ((attrsOrEmpty (targetDef.node or null)).services or null);
      pppoe = attrsOrEmpty (services.pppoe or null);
      serviceRole =
        if builtins.isAttrs (pppoe.client or null) then
          "client"
        else if builtins.isAttrs (pppoe.server or null) then
          "server"
        else
          null;
      service = if serviceRole == null then { } else attrsOrEmpty pppoe.${serviceRole};
      serviceInterface = service.interface or null;
    in
    if serviceRole != null && isNonEmptyString serviceInterface && (serviceInterface == ifName || serviceInterface == backingRefName) then
      {
        role = serviceRole;
        inherit service;
      }
    else
      null;

  overlayTaxonomy =
    { nodeRole, backingRef, overlayProvisioning }:
    let
      overlayName = backingRef.name or null;
      overlay =
        if isNonEmptyString overlayName && hasAttr overlayName overlayProvisioning then
          attrsOrEmpty overlayProvisioning.${overlayName}
        else
          { };
      provider = overlay.provider or null;
      adapterClass = if isNonEmptyString provider then "vpn" else "overlay";
    in
    baseTaxonomy {
      inherit adapterClass nodeRole;
      virtualAdapter = true;
      hostFacing = false;
      extra =
        {
          exclusionReason = "overlay-tunnel-adapter";
          tunnelPurpose = "overlay-reachability";
        }
        // (if isNonEmptyString overlayName then { overlay = overlayName; } else { })
        // (if isNonEmptyString provider then { inherit provider; } else { });
    };

  selectorFabricTaxonomy =
    { nodeRole, backingRef, fabricLinkBinding }:
    baseTaxonomy {
      adapterClass = "selector-fabric-link";
      inherit nodeRole;
      virtualAdapter = true;
      hostFacing = false;
      extra = {
        exclusionReason = "selector-fabric-link";
        p2pPurpose = "selector-fabric";
        realization = "fabric-link";
        link = fabricLinkBinding.link or (backingRef.name or null);
      };
    };

  providerSessionTaxonomy =
    { nodeRole, pppoeSession }:
    let
      service = attrsOrEmpty (pppoeSession.service or null);
    in
    baseTaxonomy {
      adapterClass = "provider-session";
      inherit nodeRole;
      virtualAdapter = true;
      hostFacing = false;
      extra =
        {
          exclusionReason = "provider-session-virtual-adapter";
          service = "pppoe";
          sessionPurpose = "provider-access";
          serviceRole = pppoeSession.role;
        }
        // (if isNonEmptyString (service.runtimeInterface or null) then { runtimeAdapter = service.runtimeInterface; } else { })
        // (if isNonEmptyString (service.implementation or null) then { implementation = service.implementation; } else { });
    };

  taxonomyFor =
    { ifacePath
    , ifName
    , sourceKind
    , backingRef
    , nodeRole
    , targetDef
    , portBinding
    , fabricLinkBinding
    , overlayProvisioning
    ,
    }:
    let
      backingRefName = backingRef.name or null;
      pppoeSession =
        if targetDef != null then pppoeServiceForInterface ifName backingRefName targetDef else null;
      taxonomy =
        if sourceKind == "overlay" then
          overlayTaxonomy { inherit nodeRole backingRef overlayProvisioning; }
        else if fabricLinkBinding != null then
          selectorFabricTaxonomy { inherit nodeRole backingRef fabricLinkBinding; }
        else if pppoeSession != null then
          providerSessionTaxonomy { inherit nodeRole pppoeSession; }
        else if sourceKind == "p2p" then
          baseTaxonomy {
            adapterClass = "p2p-realization";
            inherit nodeRole;
          }
        else if sourceKind == "tenant" then
          baseTaxonomy {
            adapterClass = "tenant-role-surface";
            inherit nodeRole;
          }
        else if sourceKind == "wan" then
          baseTaxonomy {
            adapterClass = "wan-uplink";
            inherit nodeRole;
          }
        else
          baseTaxonomy {
            adapterClass = "runtime-interface";
            inherit nodeRole;
          };
    in
    virtualRequired { inherit ifacePath taxonomy; };
in
{
  inherit taxonomyFor;
}
