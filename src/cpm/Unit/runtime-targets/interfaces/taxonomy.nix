{
  helpers,
  common,
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
    {
      adapterClass,
      nodeRole,
      virtualAdapter ? false,
      hostFacing ? true,
      extra ? { },
      direction ? null,
    }:
    {
      inherit
        adapterClass
        virtualAdapter
        hostFacing
        direction
        ;
      owningRole = nodeRole;
    }
    // extra;

  hygieneBoundaryContract =
    {
      adapterClass,
      nodeRole,
      sourceKind,
      logicalInterface,
      boundary,
      identityExtra ? { },
      authorityExtra ? { },
      decisionExtra ? { },
    }:
    let
      boundaryIdentity = {
        kind = "virtual-adapter-hygiene-boundary";
        inherit
          adapterClass
          sourceKind
          logicalInterface
          boundary
          ;
        owningRole = nodeRole;
      }
      // identityExtra;
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
      }
      // authorityExtra;
      hygieneDecision = {
        decision = "preserve-virtual-boundary";
        enforcement = "fail-closed";
        unscopedSourceAccepted = false;
        interfaceTupleOnlyAuthority = false;
        diagnostic = "FS-305-HDS-010-SDS-010-SMS-010: virtual adapter traffic must retain structured source authority before renderer handoff";
      }
      // decisionExtra;
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
      inherit
        boundaryIdentity
        sourceScopeAuthority
        hygieneDecision
        spoofing
        ;
      hygieneBoundary = {
        inherit
          boundaryIdentity
          sourceScopeAuthority
          hygieneDecision
          spoofing
          provenance
          ;
      };
    };

  pppoeServiceForInterface =
    ifName: backingRefName: targetDef:
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
    if
      serviceRole != null
      && isNonEmptyString serviceInterface
      && (serviceInterface == ifName || serviceInterface == backingRefName)
    then
      {
        role = serviceRole;
        inherit service;
      }
    else
      null;

  overlayTaxonomy =
    {
      nodeRole,
      backingRef,
      overlayProvisioning,
    }:
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
      extra = {
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
          trafficClasses = [
            "overlay-control"
            "overlay-service"
          ];
        };
      };
    };

  selectorFabricTaxonomy =
    {
      nodeRole,
      backingRef,
      fabricLinkBinding,
    }:
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
          trafficClasses = [
            "selector-forwarding"
            "policy-forwarding"
          ];
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
      extra = {
        exclusionReason = "provider-session-virtual-adapter";
        service = "pppoe";
        sessionPurpose = "provider-access";
        serviceRole = pppoeSession.role;
      }
      // (
        if isNonEmptyString (service.runtimeInterface or null) then
          { runtimeAdapter = service.runtimeInterface; }
        else
          { }
      )
      // (
        if isNonEmptyString (service.implementation or null) then
          { implementation = service.implementation; }
        else
          { }
      )
      // hygieneBoundaryContract {
        adapterClass = "provider-session";
        inherit nodeRole;
        sourceKind = "p2p";
        logicalInterface = service.interface or "provider-session";
        boundary = "provider-session";
        identityExtra = {
          service = "pppoe";
          sessionPurpose = "provider-access";
          serviceRole = pppoeSession.role;
        }
        // (
          if isNonEmptyString (service.runtimeInterface or null) then
            { runtimeAdapter = service.runtimeInterface; }
          else
            { }
        );
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
          trafficClasses = [
            "provider-egress"
            "provider-session"
            "dns"
          ];
        };
      };
    };

  taxonomyFor =
    {
      ifacePath,
      ifName,
      sourceKind,
      backingRef,
      nodeRole,
      targetDef,
      portBinding,
      fabricLinkBinding,
      overlayProvisioning,
    }:
    let
      backingRefName = backingRef.name or null;
      lane = if builtins.isAttrs (backingRef.lane or null) then backingRef.lane else { };
      laneKind = lane.kind or null;
      backingUplinks =
        (
          if builtins.isList (backingRef.uplinks or null) then
            builtins.filter builtins.isString backingRef.uplinks
          else
            [ ]
        )
        ++ (
          if builtins.isList (lane.uplinks or null) then
            builtins.filter builtins.isString lane.uplinks
          else
            [ ]
        )
        ++ (
          let
            uplink = lane.uplink or null;
          in
          if isNonEmptyString uplink then [ uplink ] else [ ]
        );
      pppoeSession =
        if targetDef != null then pppoeServiceForInterface ifName backingRefName targetDef else null;
      direction =
        if sourceKind == "tenant" then
          if nodeRole != null && builtins.substring 0 4 nodeRole == "core" then "egress" else "ingress"
        else if sourceKind == "p2p" then
          if nodeRole != null && builtins.substring 0 4 nodeRole == "core" then "ingress" else "egress"
        else if sourceKind == "wan" then
          "egress"
        else
          null;
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
            hostFacing =
              if
                nodeRole != null
                && builtins.substring 0 4 nodeRole == "core"
                && backingRefName != null
                && ((backingRef.lane or { }).access or null) != null
              then
                false
              else if
                nodeRole != null
                && builtins.substring 0 6 nodeRole == "access"
                && backingRefName != null
                && (
                  let
                    allUplinks =
                      (backingRef.uplinks or [ ])
                      ++ ((backingRef.lane or { }).uplinks or [ ])
                      ++ (
                        let
                          u = (backingRef.lane or { }).uplink or null;
                        in
                        if u == null then [ ] else [ u ]
                      );
                  in
                  builtins.any (name: builtins.hasAttr name overlayProvisioning) allUplinks
                )
              then
                false
              else
                true;
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
        else if sourceKind == "pppoe-session" then
          baseTaxonomy {
            adapterClass = "provider-session";
            inherit nodeRole;
            virtualAdapter = true;
            hostFacing = false;
            direction = "egress";
            extra = {
              exclusionReason = "provider-session-virtual-adapter";
              service = "pppoe";
              sessionPurpose = "provider-access";
            };
          }
        else if sourceKind == "pppoe-handoff" then
          baseTaxonomy {
            adapterClass = "pppoe-service-handoff";
            inherit nodeRole;
            hostFacing = true;
            extra = {
              service = "pppoe";
              handoffPurpose = "pppoe-service-interface";
            };
          }
        else
          baseTaxonomy {
            adapterClass = "runtime-interface";
            inherit nodeRole;
          };
      explicitRole = {
        explicitWan = sourceKind == "wan" && (taxonomy.adapterClass or null) == "wan-uplink";
        explicitTransit =
          (sourceKind == "p2p" && (taxonomy.adapterClass or null) == "p2p-realization")
          || (sourceKind == "pppoe-session" && (taxonomy.adapterClass or null) == "provider-session");
        explicitLocalAdapter =
          sourceKind == "tenant" && (taxonomy.adapterClass or null) == "tenant-role-surface";
        explicitUplink = false;
      };
      interfaceClass = {
        edgeFacing = sourceKind == "p2p" && laneKind == "access-edge";
        fabricFacing = sourceKind == "p2p" && laneKind == "access";
        exitFacing = sourceKind == "p2p" && laneKind == "access-uplink";
        coreFacing =
          sourceKind == "p2p"
          && (
            laneKind == "uplink"
            || (
              nodeRole == "upstream-selector"
              && backingUplinks != [ ]
              && laneKind != "access-edge"
              && laneKind != "access"
              && laneKind != "access-uplink"
            )
          );
        overlay = sourceKind == "overlay";
        coreTransit = false;
        serviceFacing = sourceKind == "pppoe-handoff";
        providerSession = sourceKind == "pppoe-session";
      };
      # DHCP authority declaration per FS-380-HDS-010-SDS-010-SMS-110.
      # CPM must declare whether DHCP is permitted on each interface.
      # Defaults to false — DHCP must be opt-in from model intent.
      # Renderers consume these fields instead of hardcoding DHCPServer=true.
      dhcpAuthority = {
        server = {
          enabled = false;
          pool = null;
          authoritySource = null;
        };
        client = {
          enabled = false;
          interface = null;
        };
      };

      # DNS resolver configuration per interface — FS-540-HDS-010-SDS-010-SMS-020.
      # Interface taxonomy is not DNS policy authority. The named DNS binding
      # control module replaces this fail-closed value only for requester
      # interfaces selected by an explicit DNS relation and binding.
      dnsResolver = {
        resolver4 = null;
        resolver6 = null;
        resolverSource = "none";
        authoritySource = null;
      };
    in
    virtualRequired { inherit ifacePath taxonomy; }
    // {
      explicit = explicitRole;
      inherit interfaceClass dhcpAuthority dnsResolver;
    };
in
{
  inherit taxonomyFor;
}
