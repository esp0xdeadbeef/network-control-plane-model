{ lib }:

let
  common = import ./common.nix { inherit lib; };
  inherit (common)
    fail
    forceAll
    hasAttr
    hasDuplicates
    isNonEmptyString
    requireAttrs
    requireList
    requireString
    requireStringList
    ;

  validateTransitEndpoint = context: adjacencyIndex: endpointIndex: endpoint:
    let
      prefix = "transit.adjacencies[${toString adjacencyIndex}].endpoints[${toString endpointIndex}]";
    in
    if !builtins.isAttrs endpoint then
      fail context "${prefix} must be an attribute set"
    else if !isNonEmptyString (endpoint.unit or null) then
      fail context "${prefix}.unit is required"
    else if !(endpoint ? local) then
      fail context "${prefix}.local is required"
    else if !builtins.isAttrs endpoint.local then
      fail context "${prefix}.local must be an attribute set"
    else if !(
      isNonEmptyString (endpoint.local.ipv4 or null)
      || isNonEmptyString (endpoint.local.ipv6 or null)
    ) then
      fail context "${prefix}.local must contain ipv4 or ipv6"
    else
      true;

  validateAdjacency = context: links: adjacencyIndex: adjacency:
    let
      prefix = "transit.adjacencies[${toString adjacencyIndex}]";
      adjacencyAttrs =
        if builtins.isAttrs adjacency then
          adjacency
        else
          fail context "${prefix} must be an attribute set";

      adjacencyId = adjacencyAttrs.id or null;
      kind = adjacencyAttrs.kind or null;
      linkName = adjacencyAttrs.link or null;
      endpoints =
        if adjacencyAttrs ? endpoints then
          adjacencyAttrs.endpoints
        else
          fail context "${prefix}.endpoints is required";
    in
    if !isNonEmptyString adjacencyId then
      fail context "${prefix}.id is required"
    else if !isNonEmptyString kind then
      fail context "${prefix}.kind is required"
    else if !builtins.isList endpoints then
      fail context "${prefix}.endpoints must be a list"
    else if builtins.length endpoints != 2 then
      fail context "${prefix}.endpoints must contain exactly 2 endpoints"
    else if kind == "p2p" && !isNonEmptyString linkName then
      fail context "${prefix}.link is required for p2p adjacency"
    else if kind == "p2p" && !(hasAttr linkName links) then
      fail context "${prefix}.link references unknown link '${linkName}'"
    else if kind == "p2p" then
      let
        linkId = links.${linkName}.id or null;
      in
      if !isNonEmptyString linkId then
        fail context "links.${linkName}.id is required"
      else if linkId != adjacencyId then
        fail context "transit adjacency id '${adjacencyId}' does not match links.${linkName}.id '${linkId}'"
      else
        forceAll (
          builtins.genList
            (endpointIndex:
              validateTransitEndpoint context adjacencyIndex endpointIndex (builtins.elemAt endpoints endpointIndex))
            (builtins.length endpoints)
        )
    else
      forceAll (
        builtins.genList
          (endpointIndex:
            validateTransitEndpoint context adjacencyIndex endpointIndex (builtins.elemAt endpoints endpointIndex))
          (builtins.length endpoints)
      );

  validateTransit = context: links: transit:
    let
      transitAttrs = requireAttrs context "transit" transit;
      adjacencies = requireList context "transit.adjacencies" (transitAttrs.adjacencies or null);
      orderingRaw = transitAttrs.ordering or null;
      ordering =
        if !builtins.isList orderingRaw then
          fail context "transit.ordering must be a list of stable adjacency IDs"
        else if !builtins.all isNonEmptyString orderingRaw then
          fail context "transit.ordering must contain only stable adjacency IDs"
        else
          orderingRaw;

      adjacencyIds =
        builtins.genList
          (adjacencyIndex:
            let
              adjacency = builtins.elemAt adjacencies adjacencyIndex;
            in
            if !builtins.isAttrs adjacency then
              fail context "transit.adjacencies[${toString adjacencyIndex}] must be an attribute set"
            else if !isNonEmptyString (adjacency.id or null) then
              fail context "transit.adjacencies[${toString adjacencyIndex}].id is required"
            else
              adjacency.id)
          (builtins.length adjacencies);

      adjacencyIdSet =
        builtins.listToAttrs (
          builtins.map
            (id: {
              name = id;
              value = true;
            })
            adjacencyIds
        );

      p2pIds =
        builtins.filter
          (id: id != null)
          (
            builtins.genList
              (adjacencyIndex:
                let
                  adjacency = builtins.elemAt adjacencies adjacencyIndex;
                in
                if builtins.isAttrs adjacency && (adjacency.kind or null) == "p2p" then
                  adjacency.id or null
                else
                  null)
              (builtins.length adjacencies)
          );
    in
    builtins.seq
      (forceAll (
        builtins.map
          (linkName:
            let
              link = links.${linkName};
            in
            if !builtins.isAttrs link then
              fail context "links.${linkName} must be an attribute set"
            else if !isNonEmptyString (link.id or null) then
              fail context "links.${linkName}.id is required"
            else
              true)
          (lib.attrNamesSorted links)
      ))
      (builtins.seq
        (if hasDuplicates adjacencyIds then
          fail context "transit.adjacencies contains duplicate ids"
        else
          true)
        (builtins.seq
          (if hasDuplicates ordering then
            fail context "transit.ordering contains duplicate adjacency IDs"
          else
            true)
          (builtins.seq
            (forceAll (
              builtins.genList
                (adjacencyIndex:
                  validateAdjacency context links adjacencyIndex (builtins.elemAt adjacencies adjacencyIndex))
                (builtins.length adjacencies)
            ))
            (builtins.seq
              (forceAll (
                builtins.genList
                  (orderIndex:
                    let
                      entry = builtins.elemAt ordering orderIndex;
                    in
                    if hasAttr entry adjacencyIdSet then
                      true
                    else
                      fail context "transit.ordering[${toString orderIndex}] references unknown adjacency ID '${entry}'")
                  (builtins.length ordering)
              ))
              (forceAll (
                builtins.map
                  (adjacencyId:
                    if builtins.elem adjacencyId ordering then
                      true
                    else
                      fail context "p2p adjacency '${adjacencyId}' is missing from transit.ordering")
                  p2pIds
              ))))));

  validateNode = context: nodeName: node:
    let
      nodeContext = context // { node = nodeName; };
      nodeAttrs = requireAttrs nodeContext "nodes.${nodeName}" node;
      interfaces = requireAttrs nodeContext "node.interfaces" (nodeAttrs.interfaces or null);
      loopback = requireAttrs nodeContext "node.loopback" (nodeAttrs.loopback or null);
      interfaceNames = lib.attrNamesSorted interfaces;
    in
    builtins.seq
      (if !isNonEmptyString (loopback.ipv4 or null) || !isNonEmptyString (loopback.ipv6 or null) then
        fail nodeContext "node loopback is required"
      else
        true)
      (forceAll (
        builtins.map
          (ifName:
            let
              ifaceContext = nodeContext // { interface = ifName; };
              iface = requireAttrs ifaceContext "node.interfaces.${ifName}" interfaces.${ifName};
              kind = iface.kind or null;
            in
            if !isNonEmptyString kind then
              fail ifaceContext "interface kind is required"
            else
              true)
          interfaceNames
      ));

  validateSiteForwardingModel = enterpriseName: siteName: site:
    let
      context = {
        enterprise = enterpriseName;
        site = siteName;
      };

      siteAttrs = requireAttrs context "site" site;

      _siteId = requireString context "siteId" (siteAttrs.siteId or null);
      _siteName = requireString context "siteName" (siteAttrs.siteName or null);

      attachments = requireList context "attachments" (siteAttrs.attachments or null);
      _validatedAttachments =
        forceAll (
          builtins.genList
            (attachmentIndex:
              let
                attachment =
                  requireAttrs context "attachments[${toString attachmentIndex}]" (builtins.elemAt attachments attachmentIndex);
              in
              builtins.seq
                (requireString context "attachments[${toString attachmentIndex}].kind" (attachment.kind or null))
                (builtins.seq
                  (requireString context "attachments[${toString attachmentIndex}].name" (attachment.name or null))
                  (requireString context "attachments[${toString attachmentIndex}].unit" (attachment.unit or null))))
            (builtins.length attachments)
        );

      links = requireAttrs context "links" (siteAttrs.links or null);
      nodes = requireAttrs context "nodes" (siteAttrs.nodes or null);

      _policyNodeName = requireString context "policyNodeName" (siteAttrs.policyNodeName or null);
      _upstreamSelectorNodeName = requireString context "upstreamSelectorNodeName" (siteAttrs.upstreamSelectorNodeName or null);
      coreNodeNames = requireStringList context "coreNodeNames" (siteAttrs.coreNodeNames or null);
      uplinkCoreNames = requireStringList context "uplinkCoreNames" (siteAttrs.uplinkCoreNames or null);
      _uplinkNames = requireStringList context "uplinkNames" (siteAttrs.uplinkNames or null);

      domains = requireAttrs context "domains" (siteAttrs.domains or null);
      _tenants = requireList context "domains.tenants" (domains.tenants or null);
      _externals = requireList context "domains.externals" (domains.externals or null);

      _tenantPrefixOwners = requireAttrs context "tenantPrefixOwners" (siteAttrs.tenantPrefixOwners or null);

      nodeNames = lib.attrNamesSorted nodes;
      nodeNameSet =
        builtins.listToAttrs (
          builtins.map
            (name: {
              inherit name;
              value = true;
            })
            nodeNames
        );

      _roleReferences =
        builtins.seq
          (if hasAttr _policyNodeName nodeNameSet then
            true
          else
            fail context "policyNodeName references unknown node '${_policyNodeName}'")
          (builtins.seq
            (if hasAttr _upstreamSelectorNodeName nodeNameSet then
              true
            else
              fail context "upstreamSelectorNodeName references unknown node '${_upstreamSelectorNodeName}'")
            (builtins.seq
              (forceAll (
                builtins.map
                  (nodeName:
                    if hasAttr nodeName nodeNameSet then
                      true
                    else
                      fail context "coreNodeNames references unknown node '${nodeName}'")
                  coreNodeNames
              ))
              (forceAll (
                builtins.map
                  (nodeName:
                    if hasAttr nodeName nodeNameSet then
                      true
                    else
                      fail context "uplinkCoreNames references unknown node '${nodeName}'")
                  uplinkCoreNames
              ))));
    in
    builtins.seq _validatedAttachments (
      builtins.seq _roleReferences (
        builtins.seq
          (forceAll (
            builtins.map
              (nodeName: validateNode context nodeName nodes.${nodeName})
              nodeNames
          ))
          (validateTransit context links (siteAttrs.transit or null))
      ));

  validateForwardingModelInput = input:
    let
      context = { };
      inputAttrs =
        if builtins.isAttrs input then
          input
        else
          fail context "forwarding model input must be an attribute set";

      meta = inputAttrs.meta or null;
      marker =
        if builtins.isAttrs meta && builtins.isAttrs (meta.networkForwardingModel or null) then
          meta.networkForwardingModel
        else
          fail context "forwarding model input requires meta.networkForwardingModel";

      schemaVersion = marker.schemaVersion or null;
      enterprise = requireAttrs context "enterprise" (inputAttrs.enterprise or null);
      enterpriseNames = lib.attrNamesSorted enterprise;
    in
    if schemaVersion != 9 then
      fail context "unsupported forwarding model schema version '${toString schemaVersion}' (expected 9)"
    else
      forceAll (
        builtins.map
          (enterpriseName:
            let
              enterpriseValue = requireAttrs { enterprise = enterpriseName; } "enterprise.${enterpriseName}" enterprise.${enterpriseName};
              siteRoot = requireAttrs { enterprise = enterpriseName; } "enterprise.${enterpriseName}.site" (enterpriseValue.site or null);
              siteNames = lib.attrNamesSorted siteRoot;
            in
            forceAll (
              builtins.map
                (siteName: validateSiteForwardingModel enterpriseName siteName siteRoot.${siteName})
                siteNames
            ))
          enterpriseNames
      );

  validateRuntimeTarget = context: targetName: target:
    let
      targetContext = context // { target = targetName; };
      targetAttrs = requireAttrs targetContext "runtimeTargets.${targetName}" target;
      placement = requireAttrs targetContext "runtimeTargets.${targetName}.placement" (targetAttrs.placement or null);
      effective = requireAttrs targetContext "runtimeTargets.${targetName}.effectiveRuntimeRealization" (targetAttrs.effectiveRuntimeRealization or null);
      loopback = requireAttrs targetContext "runtimeTargets.${targetName}.effectiveRuntimeRealization.loopback" (effective.loopback or null);
      interfaces = requireAttrs targetContext "runtimeTargets.${targetName}.effectiveRuntimeRealization.interfaces" (effective.interfaces or null);
      interfaceNames = lib.attrNamesSorted interfaces;

      renderedNames =
        builtins.map
          (ifName:
            let
              ifaceContext = targetContext // { interface = ifName; };
              iface = requireAttrs ifaceContext "effectiveRuntimeRealization.interfaces.${ifName}" interfaces.${ifName};
              backingRef = requireAttrs ifaceContext "effectiveRuntimeRealization.interfaces.${ifName}.backingRef" (iface.backingRef or null);
              kind = backingRef.kind or null;
            in
            builtins.seq
              (requireString ifaceContext "effectiveRuntimeRealization.interfaces.${ifName}.runtimeIfName" (iface.runtimeIfName or null))
              (builtins.seq
                (requireString ifaceContext "effectiveRuntimeRealization.interfaces.${ifName}.renderedIfName" (iface.renderedIfName or null))
                (builtins.seq
                  (if kind == "link" || kind == "attachment" || kind == "overlay" then
                    true
                  else
                    fail ifaceContext "ambiguous backing reference")
                  (builtins.seq
                    (if builtins.isAttrs (iface.routes or null) then
                      true
                    else
                      fail ifaceContext "routes are required for renderer-ready interfaces")
                    (iface.renderedIfName or null)))))
          interfaceNames;
    in
    builtins.seq
      (requireString targetContext "runtimeTargets.${targetName}.placement.kind" (placement.kind or null))
      (builtins.seq
        (if !isNonEmptyString (loopback.addr4 or null) || !isNonEmptyString (loopback.addr6 or null) then
          fail targetContext "loopback must contain addr4 and addr6"
        else
          true)
        (if hasDuplicates renderedNames then
          fail targetContext "duplicate rendered interface names are not allowed"
        else
          true));

  validateCPMSite = enterpriseName: siteName: site:
    let
      context = {
        enterprise = enterpriseName;
        site = siteName;
      };

      siteAttrs = requireAttrs context "control_plane_model.data.${enterpriseName}.${siteName}" site;
      transit = requireAttrs context "transit" (siteAttrs.transit or null);
      adjacencies = requireList context "transit.adjacencies" (transit.adjacencies or null);
      ordering = requireStringList context "transit.ordering" (transit.ordering or null);
      runtimeTargets = requireAttrs context "runtimeTargets" (siteAttrs.runtimeTargets or null);

      adjacencyIds =
        builtins.genList
          (adjacencyIndex:
            let
              adjacency = builtins.elemAt adjacencies adjacencyIndex;
            in
            if !builtins.isAttrs adjacency then
              fail context "transit.adjacencies[${toString adjacencyIndex}] must be an attribute set"
            else if !isNonEmptyString (adjacency.id or null) then
              fail context "transit.adjacencies[${toString adjacencyIndex}].id is required"
            else
              adjacency.id)
          (builtins.length adjacencies);
    in
    builtins.seq
      (if hasDuplicates adjacencyIds then
        fail context "transit.adjacencies contains duplicate ids"
      else
        true)
      (builtins.seq
        (if hasDuplicates ordering then
          fail context "transit.ordering contains duplicate adjacency IDs"
        else
          true)
        (forceAll (
          builtins.map
            (targetName: validateRuntimeTarget context targetName runtimeTargets.${targetName})
            (lib.attrNamesSorted runtimeTargets)
        )));

  validateCPMData = cpmData:
    let
      enterpriseNames =
        if builtins.isAttrs cpmData then
          lib.attrNamesSorted cpmData
        else
          [];
    in
    if !builtins.isAttrs cpmData then
      throw "control_plane_model.data must be an attribute set"
    else
      forceAll (
        builtins.map
          (enterpriseName:
            let
              sites = requireAttrs { enterprise = enterpriseName; } "control_plane_model.data.${enterpriseName}" cpmData.${enterpriseName};
              siteNames = lib.attrNamesSorted sites;
            in
            forceAll (
              builtins.map
                (siteName: validateCPMSite enterpriseName siteName sites.${siteName})
                siteNames
            ))
          enterpriseNames
      );
in
{
  inherit
    validateCPMData
    validateForwardingModelInput;
}
