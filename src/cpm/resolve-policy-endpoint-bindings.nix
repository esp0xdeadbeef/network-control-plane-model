{ helpers }:

{ sitePath, siteAttrs, attachments, domains, runtimeTargets }:

let
  inherit (helpers)
    ensureUniqueEntries
    hasAttr
    isNonEmptyString
    requireAttrs
    requireList
    requireString
    requireStringList
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

  failForwarding = path: message:
    throw "forwarding-model update required: ${path}: ${message}";

  uniqueStrings = values:
    sortedNames (
      builtins.listToAttrs (
        builtins.map
          (value: {
            name = value;
            value = true;
          })
          (builtins.filter isNonEmptyString values)
      )
    );

  makeStringSet = values:
    builtins.listToAttrs (
      builtins.map
        (value: {
          name = value;
          value = true;
        })
        (builtins.filter isNonEmptyString values)
    );

  appendListValue = acc: key: value:
    acc
    // {
      ${key} =
        (if hasAttr key acc then
          acc.${key}
        else
          [ ])
        ++ [ value ];
    };

  communicationContract =
    attrsOrEmpty (siteAttrs.communicationContract or null);

  policy =
    attrsOrEmpty (siteAttrs.policy or null);

  policyInterfaceTags =
    if builtins.isAttrs (policy.interfaceTags or null) then
      policy.interfaceTags
    else
      { };

  relations =
    if builtins.isList (siteAttrs.relations or null) then
      siteAttrs.relations
    else
      listOrEmpty (communicationContract.allowedRelations or null);

  serviceDefinitions =
    ensureUniqueEntries
      "${sitePath}.communicationContract.services"
      (
        let
          services = listOrEmpty (communicationContract.services or null);
        in
        builtins.genList
          (idx:
            let
              servicePath = "${sitePath}.communicationContract.services[${toString idx}]";
              service = requireAttrs servicePath (builtins.elemAt services idx);
              serviceName = requireString "${servicePath}.name" (service.name or null);
            in
            {
              name = serviceName;
              value = service;
            })
          (builtins.length services)
      );

  siteUplinkNames =
    requireStringList "${sitePath}.uplinkNames" (siteAttrs.uplinkNames or null);

  declaredExternalNames =
    builtins.map
      (external:
        let
          externalAttrs = requireAttrs "${sitePath}.domains.externals[*]" external;
        in
        requireString "${sitePath}.domains.externals[*].name" (externalAttrs.name or null))
      domains.externals;

  attachmentsByTenant =
    builtins.foldl'
      (acc: attachment:
        let
          attachmentAttrs = requireAttrs "${sitePath}.attachments[*]" attachment;
          kind = requireString "${sitePath}.attachments[*].kind" (attachmentAttrs.kind or null);
          name = requireString "${sitePath}.attachments[*].name" (attachmentAttrs.name or null);
          unit = requireString "${sitePath}.attachments[*].unit" (attachmentAttrs.unit or null);
          attachmentId = "attachment::${unit}::${kind}::${name}";
        in
        if kind != "tenant" then
          acc
        else
          appendListValue acc name {
            inherit attachmentId kind name unit;
          })
      { }
      attachments;

  domainsByTenant =
    builtins.foldl'
      (acc: tenant:
        let
          tenantAttrs = requireAttrs "${sitePath}.domains.tenants[*]" tenant;
          tenantName = requireString "${sitePath}.domains.tenants[*].name" (tenantAttrs.name or null);
        in
        appendListValue acc tenantName tenantAttrs)
      { }
      domains.tenants;

  runtimeTenantBindingsByTenant =
    builtins.foldl'
      (acc: targetName:
        let
          targetPath = "${sitePath}.runtimeTargets.${targetName}";
          target = requireAttrs targetPath runtimeTargets.${targetName};
          logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
          nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
          effective =
            requireAttrs
              "${targetPath}.effectiveRuntimeRealization"
              (target.effectiveRuntimeRealization or null);
          interfaces =
            requireAttrs
              "${targetPath}.effectiveRuntimeRealization.interfaces"
              (effective.interfaces or null);
        in
        builtins.foldl'
          (inner: ifName:
            let
              iface =
                requireAttrs
                  "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}"
                  interfaces.${ifName};
              backingRef = attrsOrEmpty (iface.backingRef or null);
              tenantName = backingRef.name or null;
            in
            if (backingRef.kind or null) != "attachment" || !isNonEmptyString tenantName then
              inner
            else
              appendListValue inner tenantName {
                runtimeTarget = targetName;
                logicalNode = nodeName;
                sourceInterface = ifName;
                runtimeInterface =
                  requireString
                    "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}.runtimeIfName"
                    (iface.runtimeIfName or null);
                attachmentId = backingRef.id or null;
              })
          acc
          (sortedNames interfaces))
      { }
      (sortedNames runtimeTargets);

  runtimeExternalBindingsByName =
    builtins.foldl'
      (acc: targetName:
        let
          targetPath = "${sitePath}.runtimeTargets.${targetName}";
          target = requireAttrs targetPath runtimeTargets.${targetName};
          logicalNode = requireAttrs "${targetPath}.logicalNode" (target.logicalNode or null);
          nodeName = requireString "${targetPath}.logicalNode.name" (logicalNode.name or null);
          egressIntent = attrsOrEmpty (target.egressIntent or null);
          effective =
            requireAttrs
              "${targetPath}.effectiveRuntimeRealization"
              (target.effectiveRuntimeRealization or null);
          interfaces =
            requireAttrs
              "${targetPath}.effectiveRuntimeRealization.interfaces"
              (effective.interfaces or null);
        in
        builtins.foldl'
          (inner: ifName:
            let
              iface =
                requireAttrs
                  "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}"
                  interfaces.${ifName};
              backingRef = attrsOrEmpty (iface.backingRef or null);
              sourceKind = iface.sourceKind or null;
            in
            if sourceKind == "wan" then
              let
                externalName = iface.upstream or null;
              in
              if !isNonEmptyString externalName then
                inner
              else
                appendListValue inner externalName {
                  runtimeTarget = targetName;
                  logicalNode = nodeName;
                  sourceInterface = ifName;
                  runtimeInterface =
                    requireString
                      "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}.runtimeIfName"
                      (iface.runtimeIfName or null);
                  sourceKind = "wan";
                  externalName = externalName;
                  uplink = externalName;
                  exit = (egressIntent.exit or false) == true;
                }
            else if sourceKind == "overlay" then
              let
                externalName = backingRef.name or null;
              in
              if !isNonEmptyString externalName then
                inner
              else
                appendListValue inner externalName {
                  runtimeTarget = targetName;
                  logicalNode = nodeName;
                  sourceInterface = ifName;
                  runtimeInterface =
                    requireString
                      "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}.runtimeIfName"
                      (iface.runtimeIfName or null);
                  sourceKind = "overlay";
                  externalName = externalName;
                  overlay = externalName;
                  exit = false;
                }
            else
              inner)
          acc
          (sortedNames interfaces))
      { }
      (sortedNames runtimeTargets);

  collectEndpointNames = expectedKind: endpointRaw:
    let
      endpoint = attrsOrEmpty endpointRaw;
      kind = endpoint.kind or null;
    in
    if kind != expectedKind then
      [ ]
    else if expectedKind == "tenant" then
      builtins.filter isNonEmptyString [ endpoint.name or null ]
    else if expectedKind == "tenant-set" then
      builtins.filter isNonEmptyString (listOrEmpty (endpoint.members or null))
    else if expectedKind == "external" then
      if isNonEmptyString (endpoint.name or null) then
        [ endpoint.name ]
      else
        builtins.filter isNonEmptyString (listOrEmpty (endpoint.uplinks or null))
    else if expectedKind == "service" then
      builtins.filter isNonEmptyString [ endpoint.name or null ]
    else
      [ ];

  relationTenantNames =
    builtins.concatLists (
      builtins.genList
        (idx:
          let
            relation = attrsOrEmpty (builtins.elemAt relations idx);
          in
          collectEndpointNames "tenant" (relation.from or null)
          ++ collectEndpointNames "tenant-set" (relation.from or null)
          ++ collectEndpointNames "tenant" (relation.to or null)
          ++ collectEndpointNames "tenant-set" (relation.to or null))
        (builtins.length relations)
    );

  relationExternalNames =
    builtins.concatLists (
      builtins.genList
        (idx:
          let
            relation = attrsOrEmpty (builtins.elemAt relations idx);
          in
          collectEndpointNames "external" (relation.from or null)
          ++ collectEndpointNames "external" (relation.to or null))
        (builtins.length relations)
    );

  relationServiceNames =
    builtins.concatLists (
      builtins.genList
        (idx:
          let
            relation = attrsOrEmpty (builtins.elemAt relations idx);
          in
          collectEndpointNames "service" (relation.from or null)
          ++ collectEndpointNames "service" (relation.to or null))
        (builtins.length relations)
    );

  tenantNames =
    uniqueStrings (
      (sortedNames attachmentsByTenant)
      ++ (sortedNames domainsByTenant)
      ++ relationTenantNames
    );

  externalNames =
    uniqueStrings (
      siteUplinkNames
      ++ declaredExternalNames
      ++ relationExternalNames
      ++ (sortedNames runtimeExternalBindingsByName)
    );

  serviceNames =
    uniqueStrings (
      (sortedNames serviceDefinitions)
      ++ relationServiceNames
    );

  relationTenantSet = makeStringSet relationTenantNames;
  relationExternalSet = makeStringSet relationExternalNames;

  tenantBindings =
    builtins.listToAttrs (
      builtins.map
        (tenantName:
          let
            attachmentList =
              if hasAttr tenantName attachmentsByTenant then
                attachmentsByTenant.${tenantName}
              else
                [ ];

            domainList =
              if hasAttr tenantName domainsByTenant then
                domainsByTenant.${tenantName}
              else
                [ ];

            runtimeBindingList =
              if hasAttr tenantName runtimeTenantBindingsByTenant then
                runtimeTenantBindingsByTenant.${tenantName}
              else
                [ ];

            _requiredBinding =
              if hasAttr tenantName relationTenantSet && runtimeBindingList == [ ] then
                failForwarding
                  "${sitePath}.policy.interfaceTags"
                  "canonical policy endpoint binding for tenant '${tenantName}' requires an explicit runtime tenant interface binding"
              else
                true;
          in
          builtins.seq
            _requiredBinding
            {
              name = tenantName;
              value = {
                attachments = attachmentList;
                domains = domainList;
                runtimeBindings = runtimeBindingList;
              };
            })
        tenantNames
    );

  externalBindings =
    builtins.listToAttrs (
      builtins.map
        (externalName:
          let
            runtimeBindingList =
              if hasAttr externalName runtimeExternalBindingsByName then
                runtimeExternalBindingsByName.${externalName}
              else
                [ ];

            hasRuntimeWANBinding =
              builtins.any
                (binding: (binding.sourceKind or null) == "wan")
                runtimeBindingList;

            hasRuntimeOverlayBinding =
              builtins.any
                (binding: (binding.sourceKind or null) == "overlay")
                runtimeBindingList;

            isDeclaredUplink =
              builtins.elem externalName siteUplinkNames;

            _requiredBinding =
              if hasAttr externalName relationExternalSet && runtimeBindingList == [ ] then
                if isDeclaredUplink then
                  failForwarding
                    "${sitePath}.uplinkNames"
                    "canonical policy endpoint binding for uplink '${externalName}' requires an explicit realized WAN binding"
                else
                  failForwarding
                    "${sitePath}.nodes"
                    "canonical policy endpoint binding for external '${externalName}' requires an explicit realized overlay or WAN binding"
              else
                true;
          in
          builtins.seq
            _requiredBinding
            {
              name = externalName;
              value = {
                uplinks =
                  if isDeclaredUplink || hasRuntimeWANBinding then
                    [ externalName ]
                  else
                    [ ];
                overlays =
                  if hasRuntimeOverlayBinding then
                    [ externalName ]
                  else
                    [ ];
                runtimeBindings = runtimeBindingList;
              };
            })
        externalNames
    );

  serviceBindings =
    builtins.listToAttrs (
      builtins.map
        (serviceName:
          let
            service =
              if hasAttr serviceName serviceDefinitions then
                serviceDefinitions.${serviceName}
              else
                {
                  name = serviceName;
                };
          in
          {
            name = serviceName;
            value = {
              providers = listOrEmpty (service.providers or null);
              trafficType = service.trafficType or null;
            };
          })
        serviceNames
    );
in
{
  interfaceTags = policyInterfaceTags;
  tenants = tenantBindings;
  externals = externalBindings;
  services = serviceBindings;
  relations = relations;
}
