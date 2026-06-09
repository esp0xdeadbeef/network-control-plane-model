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
    , direction ? null
    ,
    }:
    {
      inherit adapterClass virtualAdapter hostFacing direction;
      owningRole = nodeRole;
    } // extra;

  hygieneBoundaryContract =
    { adapterClass
    , nodeRole
    , sourceKind
    , logicalInterface
    , boundary
    , identityExtra ? { }
    , authorityExtra ? { }
    , decisionExtra ? { }
    ,
    }:
    let
      boundaryIdentity = {
        kind = "virtual-adapter-hygiene-boundary";
        inherit adapterClass sourceKind logicalInterface boundary;
        owningRole = nodeRole;
      } // identityExtra;
      sourceScopeAuthority = {
        authority = "control-plane-model";
        mode = "structured-source-scope";
        sourceRequired = true;
        failClosedWhenAbsent = true;
        upstreamFacts = [
          "communicationContract.relations.id"
          "trafficPaths.nodePath"
          "runtimeTargets.*.effectiveRuntimeRealization.interfaces.*.routes"
          "routes.*.intent.kind"
          "routes.*.policyOnly"
        ];
        cpmFacts = [
          "forwardingIntent.rules.sourcePrefixes"
          "forwardingIntent.rules.sourceScope"
          "forwardingIntent.rules.candidateEgress"
          "forwardingIntent.rules.policyPointTraversal"
        ];
      } // authorityExtra;
      hygieneDecision = {
        decision = "preserve-virtual-boundary";
        enforcement = "fail-closed";
        unscopedSourceAccepted = false;
        interfaceTupleOnlyAuthority = false;
        diagnostic = "FS-305-HDS-010-SDS-010-SMS-010: virtual adapter traffic must retain structured source authority before renderer handoff";
      } // decisionExtra;
      spoofing = {
        rejection = "fail-closed";
        spoofedSourceAccepted = false;
        interfaceTupleOnlyBypass = false;
        diagnostic = "FS-305-HDS-010-SDS-010-SMS-010: spoofed or interface-only virtual-adapter source authority is rejected";
      };
      provenance = {
        route = {
          gate = "route-intent-and-policy-only-classification";
          sourceFacts = [
            "routes.*.intent.kind"
            "routes.*.intent.source"
            "routes.*.policyOnly"
            "routes.*.lane"
          ];
        };
        firewall = {
          gate = "relation-handoff";
          sourceFacts = [
            "communicationContract.relations.id"
            "forwardingIntent.rules.action"
            "forwardingIntent.rules.trafficType"
            "forwardingIntent.rules.sourceScope"
            "forwardingIntent.rules.destinationScope"
            "forwardingIntent.rules.policyPointTraversal"
          ];
        };
        nat = {
          gate = "route-safety";
          sourceFacts = [
            "runtimeTargets.*.natIntent.routeSafety.coreOriginUplinkDefault"
            "runtimeTargets.*.natIntent.translationRecords"
          ];
        };
        providerEgress = {
          gate = "provider-egress-source";
          sourceFacts = [
            "egressIntent.uplinks"
            "provider-access.service"
            "overlay.provider"
            "inventory.realization.fabricLinks"
          ];
        };
      };
    in
    {
      inherit boundaryIdentity sourceScopeAuthority hygieneDecision spoofing;
      hygieneBoundary = {
        inherit boundaryIdentity sourceScopeAuthority hygieneDecision spoofing provenance;
      };
    };

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
      overlayIdentity =
        (if isNonEmptyString overlayName then { overlay = overlayName; } else { })
        // (if isNonEmptyString provider then { inherit provider; } else { });
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
        // overlayIdentity
        // hygieneBoundaryContract {
          inherit adapterClass nodeRole;
          sourceKind = "overlay";
          logicalInterface = backingRef.name or "overlay";
          boundary = "overlay-vpn-adapter";
          identityExtra = overlayIdentity;
          authorityExtra = {
            sourceClass = "overlay-runtime-adapter";
            sourceFacts = [
              "overlay.provider"
              "overlay.runtimeNodes.*.service.interface"
              "overlay.nodes.*.addr4"
              "overlay.nodes.*.addr6"
            ];
          };
          decisionExtra = {
            trafficClasses = [ "overlay-control" "overlay-service" ];
          };
        };
    };

  selectorFabricTaxonomy =
    { nodeRole, backingRef, fabricLinkBinding }:
    baseTaxonomy {
      adapterClass = "selector-fabric-link";
      inherit nodeRole;
      virtualAdapter = true;
      hostFacing = false;
      extra =
        {
          exclusionReason = "selector-fabric-link";
          p2pPurpose = "selector-fabric";
          realization = "fabric-link";
          link = fabricLinkBinding.link or (backingRef.name or null);
        }
        // hygieneBoundaryContract {
          adapterClass = "selector-fabric-link";
          inherit nodeRole;
          sourceKind = "p2p";
          logicalInterface = backingRef.name or "selector-fabric-link";
          boundary = "selector-fabric-link";
          identityExtra = {
            link = fabricLinkBinding.link or (backingRef.name or null);
            p2pIsolationKey = fabricLinkBinding.link or (backingRef.id or null);
          };
          authorityExtra = {
            sourceClass = "selector-fabric-link";
            sourceFacts = [
              "inventory.realization.fabricLinks.*.link"
              "backingRef.lane"
              "communicationContract.relations.id"
              "trafficPaths.nodePath"
            ];
          };
          decisionExtra = {
            trafficClasses = [ "selector-forwarding" "policy-forwarding" ];
          };
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
        // (if isNonEmptyString (service.implementation or null) then { implementation = service.implementation; } else { })
        // hygieneBoundaryContract {
          adapterClass = "provider-session";
          inherit nodeRole;
          sourceKind = "p2p";
          logicalInterface = service.interface or "provider-session";
          boundary = "provider-session";
          identityExtra =
            {
              service = "pppoe";
              sessionPurpose = "provider-access";
              serviceRole = pppoeSession.role;
            }
            // (if isNonEmptyString (service.runtimeInterface or null) then { runtimeAdapter = service.runtimeInterface; } else { });
          authorityExtra = {
            sourceClass = "provider-session";
            sourceFacts = [
              "providerAccess"
              "services.pppoe"
              "egressIntent.uplinks"
              "natIntent.routeSafety"
            ];
          };
          decisionExtra = {
            trafficClasses = [ "provider-egress" "provider-session" "dns" ];
          };
        };
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
      direction =
        if sourceKind == "tenant" then
          if nodeRole != null && builtins.substring 0 4 nodeRole == "core" then "egress" else "ingress"
        else if sourceKind == "p2p" then
          if nodeRole != null && builtins.substring 0 4 nodeRole == "core" then "ingress" else "egress"
        else if sourceKind == "wan" then "egress"
        else null;
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
            inherit nodeRole direction;
          }
        else if sourceKind == "tenant" then
          baseTaxonomy {
            adapterClass = "tenant-role-surface";
            inherit nodeRole direction;
          }
        else if sourceKind == "wan" then
          baseTaxonomy {
            adapterClass = "wan-uplink";
            inherit nodeRole direction;
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
