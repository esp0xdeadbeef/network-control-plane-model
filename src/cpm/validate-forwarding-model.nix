{ helpers }:

forwardingModel:

let
  inherit (helpers)
    forceAll
    hasAttr
    isNonEmptyString
    requireAttrs
    requireList
    requireString
    requireStringList
    sortedNames;

  validateTransit = sitePath: siteLinks: transit:
    let
      transitPath = "${sitePath}.transit";
      transitAttrs = requireAttrs transitPath transit;
      adjacencies = requireList "${transitPath}.adjacencies" (transitAttrs.adjacencies or null);
      orderingRaw = transitAttrs.ordering or null;

      ordering =
        if !builtins.isList orderingRaw then
          throw "transit.ordering must contain only stable adjacency IDs"
        else if !builtins.all isNonEmptyString orderingRaw then
          throw "transit.ordering must contain only stable adjacency IDs"
        else
          orderingRaw;

      adjacencyIds =
        builtins.genList
          (idx:
            let
              adjacencyPath = "${transitPath}.adjacencies[${toString idx}]";
              adjacency = requireAttrs adjacencyPath (builtins.elemAt adjacencies idx);
              adjacencyId = requireString "${adjacencyPath}.id" (adjacency.id or null);
              adjacencyKind = requireString "${adjacencyPath}.kind" (adjacency.kind or null);
              endpoints = requireList "${adjacencyPath}.endpoints" (adjacency.endpoints or null);

              _endpointCheck =
                if builtins.length endpoints > 0 then
                  true
                else
                  throw "input contract failure: ${adjacencyPath}.endpoints must not be empty";

              _linkCheck =
                if adjacencyKind == "p2p" then
                  let
                    linkName = requireString "${adjacencyPath}.link" (adjacency.link or null);
                  in
                  if !hasAttr linkName siteLinks then
                    throw "input contract failure: ${adjacencyPath}.link references unknown link '${linkName}'"
                  else
                    let
                      linkId = requireString "${sitePath}.links.${linkName}.id" (siteLinks.${linkName}.id or null);
                    in
                    if linkId != adjacencyId then
                      throw "input contract failure: ${adjacencyPath}.id '${adjacencyId}' does not match links.${linkName}.id '${linkId}'"
                    else
                      true
                else
                  true;
            in
            builtins.seq _endpointCheck (builtins.seq _linkCheck adjacencyId))
          (builtins.length adjacencies);

      _orderingMembership =
        builtins.map
          (adjacencyId:
            if builtins.elem adjacencyId adjacencyIds then
              true
            else
              throw "input contract failure: ${transitPath}.ordering references unknown adjacency ID '${adjacencyId}'")
          ordering;
    in
    builtins.seq (forceAll adjacencyIds) (forceAll _orderingMembership);

  validateNode = sitePath: nodeName: node:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      nodeAttrs = requireAttrs nodePath node;
      loopback = nodeAttrs.loopback or null;
      interfaces = nodeAttrs.interfaces or null;
    in
    if !builtins.isAttrs interfaces then
      throw "input contract failure: ${nodePath}.interfaces must be an attribute set"
    else if !builtins.isAttrs loopback then
      throw "node loopback is required"
    else if !isNonEmptyString (loopback.ipv4 or null) || !isNonEmptyString (loopback.ipv6 or null) then
      throw "node loopback is required"
    else
      true;

  validateSite = enterpriseName: siteName: site:
    let
      sitePath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}";
      siteAttrs = requireAttrs sitePath site;

      _legacyAttachment =
        if siteAttrs ? attachment then
          throw "legacy singular attachment is not supported; use attachments"
        else
          true;

      _siteId = requireString "${sitePath}.siteId" (siteAttrs.siteId or null);
      _siteName = requireString "${sitePath}.siteName" (siteAttrs.siteName or null);
      _attachments = requireList "${sitePath}.attachments" (siteAttrs.attachments or null);
      _policyNodeName = requireString "${sitePath}.policyNodeName" (siteAttrs.policyNodeName or null);
      _upstreamSelectorNodeName =
        requireString "${sitePath}.upstreamSelectorNodeName" (siteAttrs.upstreamSelectorNodeName or null);
      _coreNodeNames = requireStringList "${sitePath}.coreNodeNames" (siteAttrs.coreNodeNames or null);
      _uplinkCoreNames = requireStringList "${sitePath}.uplinkCoreNames" (siteAttrs.uplinkCoreNames or null);
      _uplinkNames = requireStringList "${sitePath}.uplinkNames" (siteAttrs.uplinkNames or null);

      domains = requireAttrs "${sitePath}.domains" (siteAttrs.domains or null);
      _tenants = requireList "${sitePath}.domains.tenants" (domains.tenants or null);
      _externals = requireList "${sitePath}.domains.externals" (domains.externals or null);
      _tenantPrefixOwners = requireAttrs "${sitePath}.tenantPrefixOwners" (siteAttrs.tenantPrefixOwners or null);

      siteLinks = requireAttrs "${sitePath}.links" (siteAttrs.links or null);
      nodes = requireAttrs "${sitePath}.nodes" (siteAttrs.nodes or null);

      _validatedNodes =
        builtins.map
          (nodeName': validateNode sitePath nodeName' nodes.${nodeName'})
          (sortedNames nodes);

      _validatedTransit = validateTransit sitePath siteLinks (siteAttrs.transit or null);
    in
    builtins.seq
      _legacyAttachment
      (builtins.seq
        _siteId
        (builtins.seq
          _siteName
          (builtins.seq
            _attachments
            (builtins.seq
              _policyNodeName
              (builtins.seq
                _upstreamSelectorNodeName
                (builtins.seq
                  _coreNodeNames
                  (builtins.seq
                    _uplinkCoreNames
                    (builtins.seq
                      _uplinkNames
                      (builtins.seq
                        _tenants
                        (builtins.seq
                          _externals
                          (builtins.seq
                            _tenantPrefixOwners
                            (builtins.seq (forceAll _validatedNodes) _validatedTransit))))))))))));

  inputAttrs =
    if builtins.isAttrs forwardingModel then
      forwardingModel
    else
      throw "forwarding model input must be an attribute set";

  meta = forwardingModel.meta or null;

  marker =
    if builtins.isAttrs meta && builtins.isAttrs ((meta).networkForwardingModel or null) then
      meta.networkForwardingModel
    else
      throw "forwarding model input requires meta.networkForwardingModel";

  schemaVersion = marker.schemaVersion or null;
  enterprise = requireAttrs "forwardingModel.enterprise" (inputAttrs.enterprise or null);
in
if schemaVersion != 6 then
  throw "unsupported forwarding model schema version '${toString schemaVersion}' (expected 6)"
else
  forceAll (
    builtins.map
      (enterpriseName:
        let
          enterpriseValue =
            requireAttrs
              "forwardingModel.enterprise.${enterpriseName}"
              enterprise.${enterpriseName};
          sites =
            requireAttrs
              "forwardingModel.enterprise.${enterpriseName}.site"
              (enterpriseValue.site or null);
        in
        forceAll (
          builtins.map
            (siteName: validateSite enterpriseName siteName sites.${siteName})
            (sortedNames sites)
        ))
      (sortedNames enterprise)
  )
