{
  helpers
}:

forwardingModel:

let
  inherit (helpers)
    forceAll
    hasAttr
    isNonEmptyString
    renderValue
    sortedNames
    ;

  attrsOrEmpty = value:
    if builtins.isAttrs value then
      value
    else
      { };

  listOrEmpty = value:
    if builtins.isList value then
      value
    else
      [ ];

  isStringList = value:
    builtins.isList value && builtins.all isNonEmptyString value;

  hasDuplicates = values:
    let
      sorted = builtins.sort builtins.lessThan values;
      count = builtins.length sorted;
    in
    if count <= 1 then
      false
    else
      builtins.any
        (idx: builtins.elemAt sorted idx == builtins.elemAt sorted (idx + 1))
        (builtins.genList (idx: idx) (count - 1));

  makeWarning = key: message: context: {
    inherit key message context;
  };

  warningIf = condition: warning:
    if condition then
      [ warning ]
    else
      [ ];

  aggregateWarnings = warnings:
    let
      folded =
        builtins.foldl'
          (acc: warning:
            let
              key = warning.key;
              contextKey = renderValue warning.context;
              existing =
                if hasAttr key acc.byKey then
                  acc.byKey.${key}
                else
                  null;
            in
            if existing == null then
              {
                order = acc.order ++ [ key ];
                byKey =
                  acc.byKey
                  // {
                    ${key} = {
                      key = key;
                      message = warning.message;
                      occurrences = 1;
                      contextsByRender = {
                        ${contextKey} = warning.context;
                      };
                    };
                  };
              }
            else
              {
                order = acc.order;
                byKey =
                  acc.byKey
                  // {
                    ${key} =
                      existing
                      // {
                        occurrences = existing.occurrences + 1;
                        contextsByRender =
                          if hasAttr contextKey existing.contextsByRender then
                            existing.contextsByRender
                          else
                            existing.contextsByRender
                            // {
                              ${contextKey} = warning.context;
                            };
                      };
                  };
              })
          {
            order = [ ];
            byKey = { };
          }
          warnings;
    in
    builtins.map
      (key:
        let
          warning = folded.byKey.${key};
        in
        {
          key = key;
          message = warning.message;
          occurrences = warning.occurrences;
          contexts =
            builtins.map
              (contextKey: warning.contextsByRender.${contextKey})
              (sortedNames warning.contextsByRender);
        })
      folded.order;

  emitWarnings = warnings: value:
    builtins.seq
      (forceAll (
        builtins.map
          (warning:
            let
              contextPayload =
                if warning.occurrences <= 1 then
                  builtins.elemAt warning.contexts 0
                else
                  {
                    occurrenceCount = warning.occurrences;
                    contexts = warning.contexts;
                  };
            in
            builtins.trace
              "migration warning: ${warning.message}\n--- offending input context ---\n${renderValue contextPayload}"
              true)
          warnings
      ))
      value;

  makeStringSet = values:
    builtins.listToAttrs (
      builtins.map
        (value: {
          name = value;
          value = true;
        })
        values
    );

  inferInterfaceKind = iface:
    if isNonEmptyString (iface.kind or null) then
      iface.kind
    else if isNonEmptyString (iface.tenant or null) then
      "tenant"
    else if isNonEmptyString (iface.overlay or null) then
      "overlay"
    else if isNonEmptyString (iface.upstream or null) then
      "wan"
    else if isNonEmptyString (iface.link or null) then
      "p2p"
    else
      "unknown";

  attachmentLookupForSite = attachments:
    makeStringSet (
      builtins.filter
        isNonEmptyString
        (
          builtins.map
            (attachment:
              let
                attachmentAttrs = attrsOrEmpty attachment;
                kind =
                  if isNonEmptyString (attachmentAttrs.kind or null) then
                    attachmentAttrs.kind
                  else
                    null;
                name =
                  if isNonEmptyString (attachmentAttrs.name or null) then
                    attachmentAttrs.name
                  else
                    null;
                unit =
                  if isNonEmptyString (attachmentAttrs.unit or null) then
                    attachmentAttrs.unit
                  else
                    null;
              in
              if kind != null && name != null && unit != null then
                "${unit}|${kind}|${name}"
              else
                null)
            attachments
        )
    );

  collectRelationEndpointTags = relationPath: relation: endpointName:
    let
      endpointPath = "${relationPath}.${endpointName}";
      endpointRaw = relation.${endpointName} or null;
      endpoint = attrsOrEmpty endpointRaw;
      kind = endpoint.kind or null;
    in
    if endpointRaw == "any" then
      [ ]
    else if !builtins.isAttrs endpointRaw then
      [ ]
    else if kind == "tenant" || kind == "service" then
      (warningIf
        (!isNonEmptyString (endpoint.name or null))
        (makeWarning
          "invariant/no-inference/contract-endpoint-name-required"
          "${endpointPath} requires an explicit name"
          {
            relationPath = relationPath;
            endpointName = endpointName;
            endpoint = endpoint;
          }))
      ++
      (if isNonEmptyString (endpoint.name or null) then
        [ endpoint.name ]
      else
        [ ])
    else if kind == "external" then
      let
        externalName =
          if isNonEmptyString (endpoint.name or null) then
            endpoint.name
          else
            null;
        uplinks =
          if isStringList (endpoint.uplinks or null) then
            endpoint.uplinks
          else
            [ ];
      in
      if externalName != null then
        [ externalName ]
      else
        uplinks
    else if kind == "tenant-set" then
      if isStringList (endpoint.members or null) then
        endpoint.members
      else
        [ ]
    else
      [ ];

  collectInterfaceWarnings = sitePath: attachmentLookup: siteLinks: nodeName: node:
    let
      nodeAttrs = attrsOrEmpty node;
      loopback = attrsOrEmpty (nodeAttrs.loopback or null);
      interfaces = attrsOrEmpty (nodeAttrs.interfaces or null);
      interfaceNames = sortedNames interfaces;

      hasExplicitTenantInterface =
        builtins.any
          (ifName:
            let
              iface = attrsOrEmpty interfaces.${ifName};
            in
            (inferInterfaceKind iface) == "tenant"
            && isNonEmptyString (iface.tenant or null))
          interfaceNames;
    in
    (warningIf
      (!builtins.isAttrs (nodeAttrs.interfaces or null))
      (makeWarning
        "invariant/forwarding-model-authority/node-interfaces-required"
        "node interfaces must be explicit canonical authority; compatibility fallback is temporary"
        {
          site = sitePath;
          node = nodeName;
          nodeDefinition = nodeAttrs;
        }))
    ++
    (warningIf
      (!builtins.isAttrs (nodeAttrs.loopback or null)
        || !isNonEmptyString (loopback.ipv4 or null)
        || !isNonEmptyString (loopback.ipv6 or null))
      (makeWarning
        "invariant/no-inference/node-loopback-required"
        "node loopback must be explicit; default loopback fallback behavior is temporary"
        {
          site = sitePath;
          node = nodeName;
          loopback = nodeAttrs.loopback or null;
          nodeDefinition = nodeAttrs;
        }))
    ++
    (builtins.concatLists (
      builtins.map
        (ifName:
          let
            iface = attrsOrEmpty interfaces.${ifName};
            ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
            kind = inferInterfaceKind iface;
            interfaceValue = iface.interface or null;
            linkValue = iface.link or null;
            tenantValue = iface.tenant or null;
            routes = attrsOrEmpty (iface.routes or null);
            attachmentKey =
              if isNonEmptyString tenantValue then
                "${nodeName}|tenant|${tenantValue}"
              else
                null;
          in
          (warningIf
            (!isNonEmptyString (iface.kind or null))
            (makeWarning
              "invariant/no-inference/interface-kind-required"
              "interface kind must be explicit; migration fallback behavior is temporary"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                interfaceDefinition = iface;
              }))
          ++
          (warningIf
            (!isNonEmptyString interfaceValue)
            (makeWarning
              "invariant/no-inference/interface-name-required"
              "${ifacePath}.interface must be explicit; name-based fallback is temporary"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                interfaceDefinition = iface;
              }))
          ++
          (warningIf
            (!builtins.isAttrs (iface.routes or null)
              || !builtins.isList (routes.ipv4 or null)
              || !builtins.isList (routes.ipv6 or null))
            (makeWarning
              "invariant/no-inference/interface-routes-required"
              "interface routes must be explicit; empty-route fallback behavior is temporary"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                interfaceDefinition = iface;
              }))
          ++
          (warningIf
            (kind == "tenant" && !isNonEmptyString tenantValue)
            (makeWarning
              "invariant/no-inference/tenant-interface-tenant-required"
              "tenant interface requires explicit tenant; migration fallback behavior is temporary"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                interfaceDefinition = iface;
              }))
          ++
          (warningIf
            (kind == "tenant" && attachmentKey != null && !hasAttr attachmentKey attachmentLookup)
            (makeWarning
              "invariant/no-inference/tenant-attachment-required"
              "tenant interface requires explicit site.attachments authority; migration fallback behavior is temporary"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                tenant = tenantValue;
                interfaceDefinition = iface;
              }))
          ++
          (warningIf
            (kind == "wan" && !isNonEmptyString (iface.upstream or null))
            (makeWarning
              "invariant/no-inference/wan-upstream-required"
              "wan interface requires explicit upstream; migration fallback behavior is temporary"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                interfaceDefinition = iface;
              }))
          ++
          (warningIf
            (kind == "wan" && !isNonEmptyString linkValue)
            (makeWarning
              "invariant/no-inference/wan-link-required"
              "wan interface requires explicit link; migration fallback behavior is temporary"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                interfaceDefinition = iface;
              }))
          ++
          (warningIf
            (kind == "overlay" && !isNonEmptyString (iface.overlay or null))
            (makeWarning
              "invariant/no-inference/overlay-name-required"
              "overlay interface requires explicit overlay identity; migration fallback behavior is temporary"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                interfaceDefinition = iface;
              }))
          ++
          (warningIf
            (isNonEmptyString linkValue && kind != "tenant" && kind != "overlay" && !hasAttr linkValue siteLinks)
            (makeWarning
              "invariant/no-inference/interface-link-reference-required"
              "link-backed interfaces must reference an explicit site.links entry; topology fallback is temporary"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                link = linkValue;
                knownLinks = sortedNames siteLinks;
                interfaceDefinition = iface;
              }))
          ++
          (warningIf
            (builtins.isAttrs iface && kind == "tenant" && isNonEmptyString linkValue)
            (makeWarning
              "migration/no-inference/tenant-interface-legacy-link"
              "tenant interfaces still accept the legacy link field during migration; attachment-backed meaning must remain explicit and this compatibility path will retire"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                interfacePath = ifacePath;
                interfaceDefinition = iface;
              }))
          ++
          (warningIf
            (builtins.isAttrs iface && kind == "overlay" && isNonEmptyString linkValue)
            (makeWarning
              "migration/no-inference/overlay-interface-legacy-link"
              "overlay interfaces still accept the legacy link field during migration; overlay identity must remain explicit and this compatibility path will retire"
              {
                site = sitePath;
                node = nodeName;
                interfaceKey = ifName;
                interfacePath = ifacePath;
                interfaceDefinition = iface;
              })))
        interfaceNames
    ))
    ++
    (warningIf
      ((nodeAttrs.role or null) == "access" && !hasExplicitTenantInterface)
      (makeWarning
        "invariant/no-inference/access-node-tenant-identity-required"
        "access nodes require at least one tenant interface with explicit tenant; role-based repair is temporary"
        {
          site = sitePath;
          node = nodeName;
          nodeDefinition = nodeAttrs;
        }));

  collectContractWarnings = sitePath: siteAttrs:
    let
      communicationContract = attrsOrEmpty (siteAttrs.communicationContract or null);
      allowedRelations = listOrEmpty (communicationContract.allowedRelations or null);
      policy = attrsOrEmpty (siteAttrs.policy or null);

      hasPolicyInterfaceTags = builtins.isAttrs (policy.interfaceTags or null);
      hasContractInterfaceTags = builtins.isAttrs (communicationContract.interfaceTags or null);

      interfaceTags =
        if hasContractInterfaceTags then
          communicationContract.interfaceTags
        else if hasPolicyInterfaceTags then
          policy.interfaceTags
        else
          { };

      explicitTagSet =
        makeStringSet (
          builtins.filter
            isNonEmptyString
            (builtins.attrValues interfaceTags)
        );

      referencedTags =
        builtins.concatLists (
          builtins.genList
            (idx:
              let
                relation = attrsOrEmpty (builtins.elemAt allowedRelations idx);
                relationPath = "${sitePath}.communicationContract.allowedRelations[${toString idx}]";
              in
              collectRelationEndpointTags relationPath relation "from"
              ++ collectRelationEndpointTags relationPath relation "to")
            (builtins.length allowedRelations)
        );

      unmappedTags =
        builtins.filter
          (tag: !hasAttr tag explicitTagSet)
          referencedTags;
    in
    (warningIf
      (hasPolicyInterfaceTags && hasContractInterfaceTags)
      (makeWarning
        "invariant/forwarding-model-authority/multiple-interface-tags-sources"
        "exactly one canonical interfaceTags source is allowed; communicationContract.interfaceTags must replace policy.interfaceTags"
        {
          site = sitePath;
          policyInterfaceTags = policy.interfaceTags;
          communicationContractInterfaceTags = communicationContract.interfaceTags;
        }))
    ++
    (warningIf
      (hasPolicyInterfaceTags && !hasContractInterfaceTags)
      (makeWarning
        "invariant/forwarding-model-authority/policy-interface-tags-legacy-source"
        "policy.interfaceTags is a legacy compatibility source; communicationContract.interfaceTags must be the canonical authority"
        {
          site = sitePath;
          policy = policy;
        }))
    ++
    (warningIf
      (allowedRelations != [ ] && !hasContractInterfaceTags)
      (makeWarning
        "invariant/no-inference/communication-contract-interface-tags-required"
        "communicationContract.interfaceTags is required for explicit endpoint binding authority; fallback recovery is temporary"
        {
          site = sitePath;
          communicationContract = communicationContract;
        }))
    ++
    (warningIf
      (unmappedTags != [ ])
      (makeWarning
        "invariant/no-inference/communication-contract-unmapped-tags"
        "communicationContract references tags with no explicit interfaceTags mapping; binding recovery is temporary"
        {
          site = sitePath;
          interfaceTags = interfaceTags;
          referencedTags = referencedTags;
          unmappedTags = unmappedTags;
        }));

  collectBGPWarnings = sitePath: siteAttrs:
    let
      bgp = attrsOrEmpty (siteAttrs.bgp or null);
    in
    warningIf
      ((bgp.mode or null) == "bgp" && !builtins.isList (bgp.sessions or null))
      (makeWarning
        "invariant/no-inference/bgp-sessions-required"
        "bgp mode requires explicit site.bgp.sessions; topology-based session recovery is temporary"
        {
          site = sitePath;
          bgp = bgp;
        });

  collectTransitWarnings = sitePath: siteAttrs:
    let
      siteLinks = attrsOrEmpty (siteAttrs.links or null);
      transitRaw = siteAttrs.transit or null;
      transit = attrsOrEmpty transitRaw;
      adjacenciesRaw = transit.adjacencies or null;
      orderingRaw = transit.ordering or null;
      adjacencies = listOrEmpty adjacenciesRaw;

      isPairOrderingEntry = entry:
        builtins.isList entry
        && builtins.length entry == 2
        && builtins.all isNonEmptyString entry;

      pairBasedOrdering =
        builtins.isList orderingRaw
        && builtins.all isPairOrderingEntry orderingRaw;

      linkIds =
        builtins.filter
          isNonEmptyString
          (
            builtins.map
              (linkName:
                let
                  link = attrsOrEmpty siteLinks.${linkName};
                in
                link.id or null)
              (sortedNames siteLinks)
          );

      adjacencyIds =
        builtins.filter
          (value: value != null)
          (
            builtins.genList
              (idx:
                let
                  adjacency = attrsOrEmpty (builtins.elemAt adjacencies idx);
                in
                if isNonEmptyString (adjacency.id or null) then
                  adjacency.id
                else
                  null)
              (builtins.length adjacencies)
          );

      p2pAdjacencyIds =
        builtins.filter
          (value: value != null)
          (
            builtins.genList
              (idx:
                let
                  adjacency = attrsOrEmpty (builtins.elemAt adjacencies idx);
                in
                if (adjacency.kind or null) == "p2p" && isNonEmptyString (adjacency.id or null) then
                  adjacency.id
                else
                  null)
              (builtins.length adjacencies)
          );

      orderingIds =
        if isStringList orderingRaw then
          orderingRaw
        else
          [ ];

      unknownOrderingIds =
        builtins.filter
          (id: !(builtins.elem id adjacencyIds))
          orderingIds;

      missingOrderedP2PIds =
        builtins.filter
          (id: !(builtins.elem id orderingIds))
          p2pAdjacencyIds;

      linkWarnings =
        builtins.concatLists (
          builtins.map
            (linkName:
              let
                link = attrsOrEmpty siteLinks.${linkName};
              in
              (warningIf
                (!isNonEmptyString (link.id or null))
                (makeWarning
                  "invariant/stable-link-identity/link-id-required"
                  "links.*.id is the canonical stable identity; missing ids are running on migration fallback"
                  {
                    site = sitePath;
                    linkName = linkName;
                    link = link;
                  }))
              ++
              (warningIf
                (!isNonEmptyString (link.kind or null))
                (makeWarning
                  "invariant/no-inference/link-kind-required"
                  "site.links entries must declare explicit kind; topology-based recovery is temporary"
                  {
                    site = sitePath;
                    linkName = linkName;
                    link = link;
                  })))
            (sortedNames siteLinks)
        );

      adjacencyWarnings =
        builtins.concatLists (
          builtins.genList
            (idx:
              let
                adjacency = attrsOrEmpty (builtins.elemAt adjacencies idx);
                adjacencyPath = "${sitePath}.transit.adjacencies[${toString idx}]";
                linkName =
                  if isNonEmptyString (adjacency.link or null) then
                    adjacency.link
                  else
                    null;
                link =
                  if linkName != null && hasAttr linkName siteLinks then
                    attrsOrEmpty siteLinks.${linkName}
                  else
                    { };
                endpoints = adjacency.endpoints or null;
              in
              (warningIf
                (!isNonEmptyString (adjacency.id or null))
                (makeWarning
                  "invariant/stable-link-identity/adjacency-id-required"
                  "transit.adjacencies[].id is the canonical stable identity; missing ids are running on migration fallback"
                  {
                    site = sitePath;
                    adjacencyIndex = idx;
                    adjacency = adjacency;
                  }))
              ++
              (warningIf
                (!isNonEmptyString (adjacency.kind or null))
                (makeWarning
                  "invariant/forwarding-model-authority/transit-adjacency-kind-required"
                  "transit adjacency kind must be explicit; legacy transit shapes are running on migration fallback"
                  {
                    site = sitePath;
                    adjacencyIndex = idx;
                    adjacency = adjacency;
                  }))
              ++
              (warningIf
                (!builtins.isList endpoints)
                (makeWarning
                  "invariant/forwarding-model-authority/transit-endpoints-required"
                  "transit adjacency endpoints must be explicit; legacy transit shapes are running on migration fallback"
                  {
                    site = sitePath;
                    adjacencyIndex = idx;
                    adjacency = adjacency;
                  }))
              ++
              (warningIf
                (builtins.isList endpoints && builtins.length endpoints != 2)
                (makeWarning
                  "invariant/no-inference/transit-endpoint-count-required"
                  "transit adjacency endpoints must contain exactly 2 explicit endpoints; topology recovery is temporary"
                  {
                    site = sitePath;
                    adjacencyIndex = idx;
                    adjacency = adjacency;
                  }))
              ++
              (warningIf
                ((adjacency.kind or null) == "p2p" && !isNonEmptyString linkName)
                (makeWarning
                  "invariant/stable-link-identity/p2p-adjacency-link-required"
                  "p2p transit adjacencies must reference an explicit site.links entry; compatibility recovery is temporary"
                  {
                    site = sitePath;
                    adjacencyIndex = idx;
                    adjacency = adjacency;
                  }))
              ++
              (warningIf
                (linkName != null && !hasAttr linkName siteLinks)
                (makeWarning
                  "invariant/stable-link-identity/transit-link-reference-required"
                  "transit adjacency links must reference explicit site.links entries; compatibility recovery is temporary"
                  {
                    site = sitePath;
                    adjacencyIndex = idx;
                    adjacency = adjacency;
                    linkName = linkName;
                    knownLinks = sortedNames siteLinks;
                  }))
              ++
              (if builtins.isList endpoints then
                builtins.concatLists (
                  builtins.genList
                    (endpointIndex:
                      let
                        endpoint = attrsOrEmpty (builtins.elemAt endpoints endpointIndex);
                        local = attrsOrEmpty (endpoint.local or null);
                      in
                      (warningIf
                        (!isNonEmptyString (endpoint.unit or null))
                        (makeWarning
                          "invariant/no-inference/transit-endpoint-unit-required"
                          "transit endpoints require explicit unit identity; compatibility recovery is temporary"
                          {
                            site = sitePath;
                            adjacencyIndex = idx;
                            endpointIndex = endpointIndex;
                            endpoint = endpoint;
                          }))
                      ++
                      (warningIf
                        (!(endpoint ? local)
                          || !builtins.isAttrs (endpoint.local or null)
                          || !(
                            isNonEmptyString (local.ipv4 or null)
                            || isNonEmptyString (local.ipv6 or null)
                          ))
                        (makeWarning
                          "invariant/no-inference/transit-endpoint-local-required"
                          "transit endpoints require explicit local ipv4 or ipv6 identity; compatibility recovery is temporary"
                          {
                            site = sitePath;
                            adjacencyIndex = idx;
                            endpointIndex = endpointIndex;
                            endpoint = endpoint;
                          })))
                    (builtins.length endpoints)
                )
              else
                [ ])
              ++
              (warningIf
                (
                  isNonEmptyString (adjacency.id or null)
                  && isNonEmptyString linkName
                  && hasAttr linkName siteLinks
                  && isNonEmptyString (link.id or null)
                  && adjacency.id != link.id
                )
                (makeWarning
                  "invariant/stable-link-identity/link-id-mismatch"
                  "transit adjacency ids must match links.*.id exactly; inconsistent identities are running on migration fallback"
                  {
                    site = sitePath;
                    adjacencyIndex = idx;
                    adjacency = adjacency;
                    linkName = linkName;
                    link = link;
                  })))
            (builtins.length adjacencies)
        );
    in
    (warningIf
      (!builtins.isAttrs transitRaw)
      (makeWarning
        "invariant/forwarding-model-authority/transit-required"
        "site.transit must be an explicit canonical authority; compatibility recovery is temporary"
        {
          site = sitePath;
          transit = transitRaw;
        }))
    ++
    (warningIf
      (!builtins.isList adjacenciesRaw)
      (makeWarning
        "invariant/forwarding-model-authority/transit-adjacencies-required"
        "site.transit.adjacencies must be explicit; compatibility recovery is temporary"
        {
          site = sitePath;
          transit = transit;
        }))
    ++
    (warningIf
      (!builtins.isList orderingRaw)
      (makeWarning
        "invariant/stable-link-identity/transit-ordering-required"
        "site.transit.ordering must be explicit and must reference stable link ids only; compatibility recovery is temporary"
        {
          site = sitePath;
          transit = transit;
        }))
    ++
    (warningIf
      pairBasedOrdering
      (makeWarning
        "invariant/stable-link-identity/pair-based-transit-ordering"
        "pair-based transit ordering is solver-era input; transit.ordering must reference stable adjacency ids only"
        {
          site = sitePath;
          ordering = orderingRaw;
        }))
    ++
    (warningIf
      (builtins.isList orderingRaw && !isStringList orderingRaw && !pairBasedOrdering)
      (makeWarning
        "invariant/stable-link-identity/transit-ordering-stable-ids-only"
        "transit.ordering must contain only stable adjacency ids; non-canonical ordering is running on migration fallback"
        {
          site = sitePath;
          ordering = orderingRaw;
        }))
    ++
    (warningIf
      (hasDuplicates linkIds)
      (makeWarning
        "invariant/stable-link-identity/duplicate-link-ids"
        "links.*.id must be unique; duplicate stable link identities are running on migration fallback"
        {
          site = sitePath;
          linkIds = linkIds;
        }))
    ++
    (warningIf
      (hasDuplicates adjacencyIds)
      (makeWarning
        "invariant/stable-link-identity/duplicate-adjacency-ids"
        "transit adjacency ids must be unique; duplicate stable identities are running on migration fallback"
        {
          site = sitePath;
          adjacencyIds = adjacencyIds;
        }))
    ++
    (warningIf
      (hasDuplicates orderingIds)
      (makeWarning
        "invariant/stable-link-identity/duplicate-ordering-ids"
        "transit.ordering must not contain duplicate stable adjacency ids; duplicates are running on migration fallback"
        {
          site = sitePath;
          ordering = orderingIds;
        }))
    ++
    (warningIf
      (unknownOrderingIds != [ ])
      (makeWarning
        "invariant/stable-link-identity/unknown-ordering-ids"
        "transit.ordering must reference known stable adjacency ids only; unknown ids are running on migration fallback"
        {
          site = sitePath;
          ordering = orderingIds;
          knownAdjacencyIds = adjacencyIds;
          unknownOrderingIds = unknownOrderingIds;
        }))
    ++
    (warningIf
      (missingOrderedP2PIds != [ ])
      (makeWarning
        "invariant/stable-link-identity/p2p-ordering-coverage"
        "transit.ordering must include every p2p stable adjacency id exactly once; incomplete ordering is running on migration fallback"
        {
          site = sitePath;
          ordering = orderingIds;
          missingOrderedP2PIds = missingOrderedP2PIds;
        }))
    ++ linkWarnings ++ adjacencyWarnings;

  collectSiteWarnings = enterpriseName: siteName: site:
    let
      sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
      siteAttrs = attrsOrEmpty site;
      nodes = attrsOrEmpty (siteAttrs.nodes or null);
      nodeNames = sortedNames nodes;
      attachments = listOrEmpty (siteAttrs.attachments or null);
      attachmentLookup = attachmentLookupForSite attachments;
      links = attrsOrEmpty (siteAttrs.links or null);

      roleNames =
        builtins.filter
          isNonEmptyString
          (
            builtins.map
              (nodeName:
                let
                  node = attrsOrEmpty nodes.${nodeName};
                in
                node.role or null)
              nodeNames
          );

      interfaceWarnings =
        builtins.concatLists (
          builtins.map
            (nodeName: collectInterfaceWarnings sitePath attachmentLookup links nodeName nodes.${nodeName})
            nodeNames
        );
    in
    (warningIf
      (siteAttrs ? attachment)
      (makeWarning
        "invariant/forwarding-model-authority/legacy-singular-attachment"
        "legacy singular attachment is not canonical forwarding-model authority; use site.attachments"
        {
          site = sitePath;
          attachment = siteAttrs.attachment;
        }))
    ++
    (warningIf
      (!isNonEmptyString (siteAttrs.siteId or null))
      (makeWarning
        "invariant/forwarding-model-authority/site-id-required"
        "site.siteId must be explicit canonical authority; compatibility fallback is temporary"
        {
          site = sitePath;
          siteDefinition = siteAttrs;
        }))
    ++
    (warningIf
      (!isNonEmptyString (siteAttrs.siteName or null))
      (makeWarning
        "invariant/forwarding-model-authority/site-name-required"
        "site.siteName must be explicit canonical authority; compatibility fallback is temporary"
        {
          site = sitePath;
          siteDefinition = siteAttrs;
        }))
    ++
    (warningIf
      (!builtins.isList (siteAttrs.attachments or null))
      (makeWarning
        "invariant/forwarding-model-authority/attachments-required"
        "site.attachments must be explicit canonical authority; compatibility fallback is temporary"
        {
          site = sitePath;
          attachments = siteAttrs.attachments or null;
        }))
    ++
    (warningIf
      (!isNonEmptyString (siteAttrs.policyNodeName or null))
      (makeWarning
        "invariant/forwarding-model-authority/policy-node-name-required"
        "site.policyNodeName must be explicit canonical authority; role-based recovery is temporary"
        {
          site = sitePath;
          siteDefinition = siteAttrs;
        }))
    ++
    (warningIf
      (!isNonEmptyString (siteAttrs.upstreamSelectorNodeName or null))
      (makeWarning
        "invariant/forwarding-model-authority/upstream-selector-node-name-required"
        "site.upstreamSelectorNodeName must be explicit canonical authority; role-based recovery is temporary"
        {
          site = sitePath;
          siteDefinition = siteAttrs;
        }))
    ++
    (warningIf
      (!isStringList (siteAttrs.coreNodeNames or null))
      (makeWarning
        "invariant/forwarding-model-authority/core-node-names-required"
        "site.coreNodeNames must be explicit canonical authority; role-based recovery is temporary"
        {
          site = sitePath;
          coreNodeNames = siteAttrs.coreNodeNames or null;
        }))
    ++
    (warningIf
      (!isStringList (siteAttrs.uplinkCoreNames or null))
      (makeWarning
        "invariant/forwarding-model-authority/uplink-core-names-required"
        "site.uplinkCoreNames must be explicit canonical authority; role-based recovery is temporary"
        {
          site = sitePath;
          uplinkCoreNames = siteAttrs.uplinkCoreNames or null;
        }))
    ++
    (warningIf
      (!isStringList (siteAttrs.uplinkNames or null))
      (makeWarning
        "invariant/forwarding-model-authority/uplink-names-required"
        "site.uplinkNames must be explicit canonical authority; renderer-era uplink recovery is temporary"
        {
          site = sitePath;
          uplinkNames = siteAttrs.uplinkNames or null;
        }))
    ++
    (warningIf
      (!builtins.isAttrs (siteAttrs.domains or null))
      (makeWarning
        "invariant/forwarding-model-authority/domains-required"
        "site.domains must be explicit canonical authority; compatibility fallback is temporary"
        {
          site = sitePath;
          domains = siteAttrs.domains or null;
        }))
    ++
    (warningIf
      (!builtins.isList ((attrsOrEmpty (siteAttrs.domains or null)).tenants or null))
      (makeWarning
        "invariant/forwarding-model-authority/tenant-domains-required"
        "site.domains.tenants must be explicit canonical authority; compatibility fallback is temporary"
        {
          site = sitePath;
          domains = attrsOrEmpty (siteAttrs.domains or null);
        }))
    ++
    (warningIf
      (!builtins.isList ((attrsOrEmpty (siteAttrs.domains or null)).externals or null))
      (makeWarning
        "invariant/forwarding-model-authority/external-domains-required"
        "site.domains.externals must be explicit canonical authority; compatibility fallback is temporary"
        {
          site = sitePath;
          domains = attrsOrEmpty (siteAttrs.domains or null);
        }))
    ++
    (warningIf
      (!builtins.isAttrs (siteAttrs.tenantPrefixOwners or null))
      (makeWarning
        "invariant/forwarding-model-authority/tenant-prefix-owners-required"
        "site.tenantPrefixOwners must be explicit canonical authority; compatibility fallback is temporary"
        {
          site = sitePath;
          tenantPrefixOwners = siteAttrs.tenantPrefixOwners or null;
        }))
    ++
    (warningIf
      (!builtins.isAttrs (siteAttrs.links or null))
      (makeWarning
        "invariant/forwarding-model-authority/links-required"
        "site.links must be explicit canonical authority; compatibility fallback is temporary"
        {
          site = sitePath;
          links = siteAttrs.links or null;
        }))
    ++
    (warningIf
      (!builtins.isAttrs (siteAttrs.nodes or null))
      (makeWarning
        "invariant/forwarding-model-authority/nodes-required"
        "site.nodes must be explicit canonical authority; compatibility fallback is temporary"
        {
          site = sitePath;
          nodes = siteAttrs.nodes or null;
        }))
    ++
    (warningIf
      (siteAttrs ? transport)
      (makeWarning
        "migration/forwarding-model-authority/site-transport"
        "site.transport is a compatibility input and is not treated as canonical forwarding-model authority by CPM; explicit canonical authority must remain under site.links, site.transit, site.attachments, site.domains, tenantPrefixOwners, loopbacks, and node interfaces"
        {
          site = sitePath;
          transport = siteAttrs.transport;
        }))
    ++
    (warningIf
      (siteAttrs ? policy)
      (makeWarning
        "migration/forwarding-model-authority/site-policy"
        "site.policy is a migration-era compatibility input and is not canonical forwarding-model authority for CPM topology/runtime semantics"
        {
          site = sitePath;
          policy = siteAttrs.policy;
        }))
    ++
    (warningIf
      (roleNames != [ ])
      (makeWarning
        "migration/no-inference/role-based-semantics"
        "runtime forwarding semantics are not yet fully explicit for all node roles; downstream consumers must not rely on role-based repair or defaults long-term"
        {
          site = sitePath;
          roles = roleNames;
        }))
    ++ interfaceWarnings
    ++ collectTransitWarnings sitePath siteAttrs
    ++ collectContractWarnings sitePath siteAttrs
    ++ collectBGPWarnings sitePath siteAttrs;

  collectEnterpriseWarnings = inputAttrs:
    let
      enterpriseRaw = inputAttrs.enterprise or null;
      enterprise = attrsOrEmpty enterpriseRaw;
      enterpriseNames = sortedNames enterprise;
    in
    (warningIf
      (!builtins.isAttrs enterpriseRaw)
      (makeWarning
        "invariant/forwarding-model-authority/enterprise-required"
        "forwardingModel.enterprise must be an explicit canonical authority"
        {
          forwardingModel = inputAttrs;
        }))
    ++
    (
      builtins.concatLists (
        builtins.map
          (enterpriseName:
            let
              enterpriseValue = attrsOrEmpty enterprise.${enterpriseName};
              sitesRaw = enterpriseValue.site or null;
              sites = attrsOrEmpty sitesRaw;
            in
            (warningIf
              (!builtins.isAttrs sitesRaw)
              (makeWarning
                "invariant/forwarding-model-authority/site-root-required"
                "enterprise.<name>.site must be an explicit canonical authority"
                {
                  enterprise = enterpriseName;
                  enterpriseDefinition = enterpriseValue;
                }))
            ++
            (builtins.concatLists (
              builtins.map
                (siteName: collectSiteWarnings enterpriseName siteName sites.${siteName})
                (sortedNames sites)
            )))
          enterpriseNames
      )
    );

  collectInputWarnings = inputAttrs:
    let
      meta = attrsOrEmpty (inputAttrs.meta or null);
      marker = meta.networkForwardingModel or null;
      schemaVersion =
        if builtins.isAttrs marker then
          marker.schemaVersion or null
        else
          null;
    in
    (warningIf
      (!builtins.isAttrs forwardingModel)
      (makeWarning
        "invariant/forwarding-model-authority/root-attrset-required"
        "forwarding model input must be an attribute set"
        {
          input = forwardingModel;
        }))
    ++
    (warningIf
      (!builtins.isAttrs marker)
      (makeWarning
        "invariant/forwarding-model-authority/meta-network-forwarding-model-required"
        "meta.networkForwardingModel is the only canonical forwarding-model marker; compatibility fallback is temporary"
        {
          meta = meta;
        }))
    ++
    (warningIf
      (schemaVersion != null && schemaVersion != 6)
      (makeWarning
        "invariant/forwarding-model-authority/schema-version-v6-required"
        "meta.networkForwardingModel.schemaVersion must be 6; solver-era or legacy schema inputs are running on migration fallback"
        {
          marker = marker;
        }))
    ++
    (warningIf
      (meta ? solver)
      (makeWarning
        "migration/forwarding-model-authority/meta-solver"
        "meta.solver is solver-era input and is ignored; meta.networkForwardingModel v6 must be the only forwarding-model authority"
        {
          meta = meta;
        }))
    ++
    (warningIf
      (inputAttrs ? control_plane_model)
      (makeWarning
        "migration/forwarding-model-authority/embedded-control-plane-model"
        "embedded control_plane_model input is ignored; meta.networkForwardingModel v6 is the only forwarding-model authority"
        {
          control_plane_model = inputAttrs.control_plane_model;
        }))
    ++
    (warningIf
      (inputAttrs ? endpointInventory)
      (makeWarning
        "migration/forwarding-model-authority/embedded-endpoint-inventory"
        "embedded endpointInventory input is ignored by forwarding-model validation; runtime realization authority must come from the inventory input only"
        {
          endpointInventory = inputAttrs.endpointInventory;
        }))
    ++ collectEnterpriseWarnings inputAttrs;

  inputAttrs = attrsOrEmpty forwardingModel;
  warnings = aggregateWarnings (collectInputWarnings inputAttrs);
in
emitWarnings warnings true
