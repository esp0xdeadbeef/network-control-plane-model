{ lib }:

let
  isNonEmptyString = value:
    builtins.isString value && value != "";

  forceAll = values:
    builtins.deepSeq values true;

  contextString = context:
    let
      segments =
        (if context ? enterprise && isNonEmptyString context.enterprise then [ "enterprise.${context.enterprise}" ] else [])
        ++ (if context ? site && isNonEmptyString context.site then [ "site.${context.site}" ] else [])
        ++ (if context ? node && isNonEmptyString context.node then [ "node.${context.node}" ] else [])
        ++ (if context ? interface && isNonEmptyString context.interface then [ "interface.${context.interface}" ] else []);
    in
    if segments == [] then
      "input"
    else
      builtins.concatStringsSep "." segments;

  fail = context: message:
    throw "${contextString context}: ${message}";

  relationObjects = context: contract:
    let
      relations =
        if contract ? allowedRelations then
          contract.allowedRelations
        else
          contract.relations or null;
    in
    if relations == null then
      []
    else if !builtins.isList relations then
      fail context "communicationContract.allowedRelations must be a list"
    else
      builtins.filter builtins.isAttrs relations;

  endpointMembers = endpoint:
    if builtins.isString endpoint then
      [ endpoint ]
    else if builtins.isList endpoint then
      builtins.concatLists (builtins.map endpointMembers endpoint)
    else if !builtins.isAttrs endpoint then
      []
    else
      let
        kind = endpoint.kind or null;
        members = endpoint.members or null;
        name = endpoint.name or null;
      in
      if builtins.elem kind [ "tenant" "tenant-set" "external" "service" ] then
        if builtins.isList members then
          builtins.filter isNonEmptyString members
        else if isNonEmptyString name then
          [ name ]
        else
          []
      else
        [];

  referencedContractTags = context: contract:
    let
      relations = relationObjects context contract;
    in
    builtins.sort builtins.lessThan (
      builtins.attrNames (
        builtins.listToAttrs (
          builtins.concatLists (
            builtins.map
              (relation:
                builtins.map
                  (name: { inherit name; value = true; })
                  (
                    endpointMembers (relation.from or null)
                    ++ (
                      if relation.to or null == "any" then
                        []
                      else
                        endpointMembers (relation.to or null)
                    )
                  ))
              relations
          )
        )
      )
    );

  validateTransitEndpoint = context: adjacencyIndex: endpointIndex: endpoint:
    let
      prefix = "site.transit.adjacencies[${toString adjacencyIndex}].endpoints[${toString endpointIndex}]";
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

  validateAdjacency = context: adjacencyIndex: adjacency:
    let
      prefix = "site.transit.adjacencies[${toString adjacencyIndex}]";
    in
    if !builtins.isAttrs adjacency then
      fail context "${prefix} must be an attribute set"
    else if !(adjacency ? endpoints) then
      fail context "${prefix} missing endpoints"
    else if !builtins.isList adjacency.endpoints then
      fail context "${prefix}.endpoints must be a list"
    else if builtins.length adjacency.endpoints != 2 then
      fail context "${prefix}.endpoints must contain exactly 2 endpoints"
    else
      forceAll (
        builtins.genList
          (endpointIndex:
            validateTransitEndpoint
              context
              adjacencyIndex
              endpointIndex
              (builtins.elemAt adjacency.endpoints endpointIndex))
          (builtins.length adjacency.endpoints)
      );

  validateOrderingEntry = context: orderIndex: entry:
    let
      prefix = "site.transit.ordering[${toString orderIndex}]";
    in
    if !builtins.isList entry then
      fail context "${prefix} must be a list"
    else if builtins.length entry != 2 then
      fail context "${prefix} must contain exactly 2 unit names"
    else if !(builtins.all isNonEmptyString entry) then
      fail context "${prefix} must contain only non-empty unit names"
    else
      true;

  validateTransit = context: transit:
    if !builtins.isAttrs transit then
      fail context "missing explicit site.transit with adjacencies and ordering"
    else if !(transit ? adjacencies) then
      fail context "site.transit.adjacencies is required"
    else if !builtins.isList transit.adjacencies then
      fail context "site.transit.adjacencies must be a list"
    else if !(transit ? ordering) then
      fail context "site.transit.ordering is required"
    else if !builtins.isList transit.ordering then
      fail context "site.transit.ordering must be a list"
    else
      builtins.seq
        (forceAll (
          builtins.genList
            (adjacencyIndex:
              validateAdjacency context adjacencyIndex (builtins.elemAt transit.adjacencies adjacencyIndex))
            (builtins.length transit.adjacencies)
        ))
        (forceAll (
          builtins.genList
            (orderIndex:
              validateOrderingEntry context orderIndex (builtins.elemAt transit.ordering orderIndex))
            (builtins.length transit.ordering)
        ));

  validateOverlays = context: site:
    if !(site ? transport) then
      true
    else if !builtins.isAttrs site.transport then
      fail context "site.transport must be an attribute set"
    else
      let
        overlays = site.transport.overlays or {};
      in
      if builtins.isAttrs overlays || builtins.isList overlays then
        true
      else
        fail context "site.transport.overlays must be an attribute set or list";

  validateInterface = context: nodeName: ifName: iface:
    let
      ifaceContext = context // { node = nodeName; interface = ifName; };
      kind = iface.kind or null;
    in
    if !builtins.isAttrs iface then
      fail ifaceContext "interface must be an attribute set"
    else if !isNonEmptyString kind then
      fail ifaceContext "interface kind is required"
    else if kind == "tenant" && !isNonEmptyString (iface.tenant or null) then
      fail ifaceContext "tenant interface requires explicit tenant"
    else if kind == "overlay" && !isNonEmptyString (iface.overlay or null) then
      fail ifaceContext "overlay interface requires explicit overlay"
    else if kind == "wan" && !isNonEmptyString (iface.upstream or null) then
      fail ifaceContext "wan interface requires explicit upstream"
    else
      true;

  validateNode = context: nodeName: node:
    let
      nodeContext = context // { node = nodeName; };
      interfaces = node.interfaces or null;
      interfaceNames =
        if builtins.isAttrs interfaces then
          lib.attrNamesSorted interfaces
        else
          [];
      tenantInterfaces =
        builtins.filter
          (ifName:
            let iface = interfaces.${ifName}; in
            builtins.isAttrs iface
            && (iface.kind or null) == "tenant"
            && isNonEmptyString (iface.tenant or null))
          interfaceNames;
    in
    if !builtins.isAttrs node then
      fail nodeContext "node must be an attribute set"
    else if !builtins.isAttrs interfaces then
      fail nodeContext "node.interfaces must be an attribute set"
    else
      builtins.seq
        (forceAll (
          builtins.map
            (ifName: validateInterface context nodeName ifName interfaces.${ifName})
            interfaceNames
        ))
        (
          if (node.role or null) == "access" && tenantInterfaces == [] then
            fail nodeContext "access node requires at least one tenant interface with explicit tenant"
          else
            true
        );

  validateNodes = context: site:
    let
      nodes = site.nodes or {};
      nodeNames = lib.attrNamesSorted nodes;
    in
    if !(site ? nodes) then
      true
    else if !builtins.isAttrs nodes then
      fail context "site.nodes must be an attribute set"
    else
      forceAll (
        builtins.map
          (nodeName: validateNode context nodeName nodes.${nodeName})
          nodeNames
      );

  validatePolicy = context: site:
    let
      contract = site.communicationContract or null;
    in
    if contract == null then
      true
    else if !builtins.isAttrs contract then
      fail context "communicationContract must be an attribute set"
    else
      let
        interfaceTags =
          if builtins.isAttrs (contract.interfaceTags or null) then
            contract.interfaceTags
          else if builtins.isAttrs (site.policy or null) && builtins.isAttrs ((site.policy or {}).interfaceTags or null) then
            site.policy.interfaceTags
          else
            null;
        knownTags =
          if builtins.isAttrs interfaceTags then
            builtins.filter isNonEmptyString (builtins.attrValues interfaceTags)
          else
            [];
        refs = referencedContractTags context contract;
      in
      if !builtins.isAttrs interfaceTags then
        fail context "communicationContract requires explicit communicationContract.interfaceTags"
      else
        forceAll (
          builtins.map
            (tag:
              if builtins.elem tag knownTags then
                true
              else
                fail context "communicationContract references tag '${tag}' with no explicit interfaceTags mapping")
            refs
        );

  validateBGP = context: site:
    let
      bgp = site.bgp or {};
      mode = bgp.mode or null;
      nodes = site.nodes or {};
      sessions = bgp.sessions or null;
    in
    if mode != "bgp" then
      true
    else if !builtins.isList sessions || sessions == [] then
      fail context "bgp mode requires explicit site.bgp.sessions"
    else
      forceAll (
        builtins.genList
          (sessionIndex:
            let
              session = builtins.elemAt sessions sessionIndex;
              prefix = "site.bgp.sessions[${toString sessionIndex}]";
              a = session.a or null;
              b = session.b or null;
              rr = session.rr or null;
            in
            if !builtins.isAttrs session then
              fail context "${prefix} must be an attribute set"
            else if !isNonEmptyString a then
              fail context "${prefix}.a is required"
            else if !isNonEmptyString b then
              fail context "${prefix}.b is required"
            else if !(nodes ? "${a}") then
              fail context "${prefix}.a references unknown node '${a}'"
            else if !(nodes ? "${b}") then
              fail context "${prefix}.b references unknown node '${b}'"
            else if rr != null && (!isNonEmptyString rr || !(nodes ? "${rr}")) then
              fail context "${prefix}.rr references unknown node '${toString rr}'"
            else
              true)
          (builtins.length sessions)
      );

  validateSiteInputs = enterpriseName: siteName: site:
    let
      context = {
        enterprise = enterpriseName;
        site = siteName;
      };
    in
    if !builtins.isAttrs site then
      fail context "site must be an attribute set"
    else
      builtins.seq (validateTransit context (site.transit or null))
        (builtins.seq (validateOverlays context site)
          (builtins.seq (validateNodes context site)
            (builtins.seq (validatePolicy context site)
              (validateBGP context site))));

  validateEnterpriseInputs = enterprise:
    let
      enterpriseNames =
        if builtins.isAttrs enterprise then
          lib.attrNamesSorted enterprise
        else
          [];
    in
    if !builtins.isAttrs enterprise then
      throw "missing required forwardingModel.enterprise attribute set"
    else
      forceAll (
        builtins.map
          (enterpriseName:
            let
              enterpriseValue = enterprise.${enterpriseName};
              siteRoot = enterpriseValue.site or null;
              siteNames =
                if builtins.isAttrs siteRoot then
                  lib.attrNamesSorted siteRoot
                else
                  [];
            in
            if !builtins.isAttrs enterpriseValue then
              throw "missing required enterprise.${enterpriseName} attribute set"
            else if !builtins.isAttrs siteRoot then
              throw "missing required enterprise.${enterpriseName}.site attribute set"
            else
              forceAll (
                builtins.map
                  (siteName: validateSiteInputs enterpriseName siteName siteRoot.${siteName})
                  siteNames
              ))
          enterpriseNames
      );

  validateCPMSite = enterpriseName: siteName: site:
    let
      context = {
        enterprise = enterpriseName;
        site = siteName;
      };
    in
    if !builtins.isAttrs site then
      fail context "control_plane_model site must be an attribute set"
    else
      builtins.seq (validateTransit context (site.transit or null))
        (if builtins.isAttrs (site.overlay or {})
          || builtins.isList (site.overlay or [])
        then
          true
        else
          fail context "control_plane_model overlay must be an attribute set or list");

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
              siteRoot = cpmData.${enterpriseName};
              siteNames =
                if builtins.isAttrs siteRoot then
                  lib.attrNamesSorted siteRoot
                else
                  [];
            in
            if !builtins.isAttrs siteRoot then
              throw "control_plane_model.data.${enterpriseName} must be an attribute set"
            else
              forceAll (
                builtins.map
                  (siteName: validateCPMSite enterpriseName siteName siteRoot.${siteName})
                  siteNames
              ))
          enterpriseNames
      );
in
{
  hasExplicitTransit = transit:
    builtins.isAttrs transit
    && builtins.isList (transit.adjacencies or null)
    && builtins.isList (transit.ordering or null);

  inherit
    validateBGP
    validateCPMData
    validateEnterpriseInputs
    validateSiteInputs;
}
