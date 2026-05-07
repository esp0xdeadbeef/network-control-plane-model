{ helpers }:

{ sitePath, siteAttrs, runtimeTargets }:

let
  inherit (helpers)
    isNonEmptyString
    requireAttrs
    requireString
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

  siteTransport = attrsOrEmpty (siteAttrs.transport or null);
  communicationContract = attrsOrEmpty (siteAttrs.communicationContract or null);
  siteRelations =
    if builtins.isList (communicationContract.relations or null) then
      communicationContract.relations
    else
      listOrEmpty (communicationContract.allowedRelations or null);

  overlayNames =
    uniqueStrings (
      sortedNames (attrsOrEmpty (siteAttrs.overlays or null))
      ++ sortedNames (attrsOrEmpty (siteAttrs.overlayReachability or null))
      ++ builtins.map
        (overlay: overlay.name or null)
        (listOrEmpty (siteTransport.overlays or null))
    );

  runtimeInterfaceRecords = targetPath: target:
    let
      effective =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization"
          (target.effectiveRuntimeRealization or null);
      interfaces =
        requireAttrs
          "${targetPath}.effectiveRuntimeRealization.interfaces"
          (effective.interfaces or null);
    in
    builtins.map
      (ifName:
        let
          iface =
            requireAttrs
              "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}"
              interfaces.${ifName};
        in
        iface
        // {
          sourceInterfaceName = ifName;
          runtimeIfName =
            requireString
              "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}.runtimeIfName"
              (iface.runtimeIfName or null);
          sourceKind =
            requireString
              "${targetPath}.effectiveRuntimeRealization.interfaces.${ifName}.sourceKind"
              (iface.sourceKind or null);
        })
      (sortedNames interfaces);

  hasHostIPv4 = iface:
    builtins.isAttrs ((attrsOrEmpty (iface.hostUplink or null)).ipv4 or null);

  hasHostIPv6 = iface:
    builtins.isAttrs ((attrsOrEmpty (iface.hostUplink or null)).ipv6 or null);

  ruleBuilders = import ./firewall-intent/rules.nix { };
  inherit (ruleBuilders)
    buildAccessRules
    buildDownstreamSelectorRules
    buildExitRules
    buildMeshRules
    buildUpstreamSelectorRules
    ;

  denyRelationRules =
    builtins.map
      (relation:
        let
          relationAttrs = attrsOrEmpty relation;
          relationId =
            if isNonEmptyString (relationAttrs.id or null) then
              relationAttrs.id
            else if isNonEmptyString (relationAttrs.name or null) then
              relationAttrs.name
            else
              null;
        in
        {
          action = "deny";
          relationId = relationId;
          priority = relationAttrs.priority or null;
          trafficType = relationAttrs.trafficType or "any";
          from = attrsOrEmpty (relationAttrs.from or null);
          to = attrsOrEmpty (relationAttrs.to or null);
        })
      (builtins.filter (relation: (attrsOrEmpty relation).action or null == "deny") siteRelations);

  buildCoreNatEntry = targetPath: target:
    let
      egressIntent = attrsOrEmpty (target.egressIntent or null);
      exitEnabled = (egressIntent.exit or false) == true;
      interfaceRecords = runtimeInterfaceRecords targetPath target;

      selectedUplinks =
        uniqueStrings (
          listOrEmpty (egressIntent.uplinks or null)
          ++ listOrEmpty (egressIntent.wanInterfaces or null)
        );

      transitInterfaces =
        builtins.filter
          (iface: iface.sourceKind == "p2p")
          interfaceRecords;

      wanInterfaces =
        builtins.filter
          (iface:
            iface.sourceKind == "wan"
            && !(builtins.elem (iface.upstream or "") overlayNames)
            && (
              selectedUplinks == [ ]
              || builtins.elem (iface.upstream or "") selectedUplinks
              || builtins.elem iface.sourceInterfaceName selectedUplinks
            ))
          interfaceRecords;

      natEnabled = exitEnabled && builtins.any hasHostIPv4 wanInterfaces;
    in
    {
      enabled = natEnabled;
      families = {
        ipv4 = natEnabled;
        ipv6 = false;
      };
      uplinks = selectedUplinks;
      wanInterfaces =
        builtins.map
          (iface: iface.runtimeIfName)
          wanInterfaces;
      transitInterfaces =
        builtins.map
          (iface: iface.runtimeIfName)
          transitInterfaces;
      masqueradeInterfaces =
        if natEnabled then
          builtins.map
            (iface: iface.runtimeIfName)
            wanInterfaces
        else
          [ ];
      tcpMssClampInterfaces =
        builtins.map
          (iface: iface.runtimeIfName)
          wanInterfaces;
      uplinkFamilies = {
        ipv4 =
          builtins.map
            (iface: iface.runtimeIfName)
            (builtins.filter hasHostIPv4 wanInterfaces);
        ipv6 =
          builtins.map
            (iface: iface.runtimeIfName)
            (builtins.filter hasHostIPv6 wanInterfaces);
      };
    };

  buildForwardingEntry = targetPath: target:
    let
      role = target.role or null;
      egressIntent = attrsOrEmpty (target.egressIntent or null);
      interfaceRecords = runtimeInterfaceRecords targetPath target;

      localInterfaces =
        builtins.filter
          (iface: iface.sourceKind == "tenant")
          interfaceRecords;

      transitInterfaces =
        builtins.filter
          (iface: iface.sourceKind == "p2p")
          interfaceRecords;

      uplinkInterfaces =
        builtins.filter
          (iface:
            iface.sourceKind == "wan"
            && (
              !builtins.isList (egressIntent.uplinks or null)
              || egressIntent.uplinks == [ ]
              || builtins.elem (iface.upstream or "") (listOrEmpty (egressIntent.uplinks or null))
              || builtins.elem iface.sourceInterfaceName (listOrEmpty (egressIntent.wanInterfaces or null))
            ))
          interfaceRecords;

      exitRules =
        buildExitRules transitInterfaces uplinkInterfaces;

      transitMeshRules =
        buildMeshRules transitInterfaces;
    in
    if role == "access" then
      {
        mode = "explicit-access-forwarding";
        localInterfaces =
          builtins.map
            (iface: iface.runtimeIfName)
            localInterfaces;
        transitInterfaces =
          builtins.map
            (iface: iface.runtimeIfName)
            transitInterfaces;
        rules = buildAccessRules localInterfaces transitInterfaces;
      }
    else if role == "downstream-selector" || role == "upstream-selector" then
      {
        mode = "explicit-selector-forwarding";
        transitInterfaces =
          builtins.map
            (iface: iface.runtimeIfName)
            transitInterfaces;
        rules =
          if role == "downstream-selector" then
            buildDownstreamSelectorRules transitInterfaces
          else
            buildUpstreamSelectorRules transitInterfaces;
      }
    else if role == "policy" then
      {
        mode = "explicit-transit-mesh-forwarding";
        transitInterfaces =
          builtins.map
            (iface: iface.runtimeIfName)
            transitInterfaces;
        rules = denyRelationRules ++ transitMeshRules;
      }
    else if role == "core" then
      {
        mode = "explicit-core-forwarding";
        transitInterfaces =
          builtins.map
            (iface: iface.runtimeIfName)
            transitInterfaces;
        uplinkInterfaces =
          builtins.map
            (iface: iface.runtimeIfName)
            uplinkInterfaces;
        rules = transitMeshRules ++ exitRules;
      }
    else
      null;

  natEntries =
    builtins.filter
      (entry: entry != null)
      (builtins.map
        (targetName:
          let
            targetPath = "${sitePath}.runtimeTargets.${targetName}";
            target = requireAttrs targetPath runtimeTargets.${targetName};
          in
          if (target.role or null) == "core" then
            {
              name = targetName;
              value = buildCoreNatEntry targetPath target;
            }
          else
            null)
        (sortedNames runtimeTargets));

  forwardingEntries =
    builtins.filter
      (entry: entry != null)
      (builtins.map
        (targetName:
          let
            targetPath = "${sitePath}.runtimeTargets.${targetName}";
            target = requireAttrs targetPath runtimeTargets.${targetName};
            forwardingEntry = buildForwardingEntry targetPath target;
          in
          if forwardingEntry == null then
            null
          else
            {
              name = targetName;
              value = forwardingEntry;
            })
        (sortedNames runtimeTargets));
in
{
  natByTarget = builtins.listToAttrs natEntries;
  forwardingByTarget = builtins.listToAttrs forwardingEntries;
}
