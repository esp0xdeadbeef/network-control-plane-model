{ lib
, helpers
, common
, uniqueStrings
, policyEndpointBindings
, providerEndpointForServiceProvider
, providerTenantsForServiceProvider
, preferredDnsUplinksByRelationForService
, preferredDnsUplinksForService
, sitePath
,
}:

let
  inherit (helpers) isNonEmptyString requireString requireStringList sortedNames;
  inherit (common) failForwarding;

  listOrEmpty = value: if builtins.isList value then value else [ ];
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };

  failExposureScope = relation: field: message:
    let
      relationId =
        if isNonEmptyString (relation.id or null) then
          relation.id
        else
          "<unidentified>";
    in
    failForwarding
      "${sitePath}.communicationContract.relations.${relationId}.${field}"
      "service exposure scope binding requires ${message}";

  normalizeRequesterScope =
    relation:
    let
      source = attrsOrEmpty (relation.from or null);
      sourceKind = source.kind or null;
    in
    if !isNonEmptyString sourceKind then
      failExposureScope relation "from.kind" "an explicit requester scope kind"
    else if sourceKind == "tenant" then
      {
        kind = "tenant";
        names = [ (requireString "${sitePath}.communicationContract.relations[*].from.name" (source.name or null)) ];
        selector = "name";
        public = false;
      }
    else if sourceKind == "tenant-set" then
      let
        names = requireStringList "${sitePath}.communicationContract.relations[*].from.members" (source.members or null);
      in
      if names == [ ] then
        failExposureScope relation "from.members" "a non-empty requester tenant-set scope"
      else
        {
          kind = "tenant-set";
          inherit names;
          selector = "members";
          public = false;
        }
    else if sourceKind == "external" then
      let
        hasName = isNonEmptyString (source.name or null);
        hasUplinks = (listOrEmpty (source.uplinks or null)) != [ ];
      in
      if hasName && hasUplinks then
        failExposureScope relation "from" "external requester scope to use exactly one of name or uplinks"
      else if hasName then
        {
          kind = "external";
          names = [ source.name ];
          selector = "name";
          public = endpointIsPublicExternal source;
        }
      else if builtins.isList (source.uplinks or null) then
        let
          names = requireStringList "${sitePath}.communicationContract.relations[*].from.uplinks" source.uplinks;
        in
        if names == [ ] then
          failExposureScope relation "from.uplinks" "a non-empty external requester scope"
        else
          {
            kind = "external";
            inherit names;
            selector = "uplinks";
            public = endpointIsPublicExternal source;
          }
      else
        failExposureScope relation "from" "requester scope to name an external or uplink"
    else if sourceKind == "service" then
      {
        kind = "service";
        names = [ (requireString "${sitePath}.communicationContract.relations[*].from.name" (source.name or null)) ];
        selector = "name";
        public = false;
      }
    else
      failExposureScope relation "from.kind" "a supported requester scope kind";

  endpointIsPublicExternal =
    endpoint:
    let
      attrs = attrsOrEmpty endpoint;
      name = attrs.name or null;
      binding = if builtins.isString name then attrsOrEmpty (policyEndpointBindings.externals.${name} or null) else { };
    in
    (attrs.kind or null) == "external"
    && ((listOrEmpty (attrs.uplinks or null)) != [ ] || (listOrEmpty (binding.uplinks or null)) != [ ]);

  exposureClassForRelation =
    providerTenants: relation: requesterScope:
    let
      sourceKind = requesterScope.kind;
      sourceTenants = requesterScope.names;
      allSourcesOwnProvider =
        sourceTenants != [ ]
        && providerTenants != [ ]
        && builtins.all (tenant: builtins.elem tenant providerTenants) sourceTenants;
    in
    if sourceKind == "external" && requesterScope.public then
      "public-ingress"
    else if sourceKind == "external" then
      "cross-site"
    else if sourceKind == "tenant" && allSourcesOwnProvider then
      "tenant-private"
    else if sourceKind == "tenant-set" && allSourcesOwnProvider then
      "shared-local"
    else if sourceKind == "tenant" || sourceKind == "tenant-set" then
      "cross-scope"
    else
      "controlled";

  priorityForExposureClass =
    class:
    if class == "public-ingress" then 60
    else if class == "cross-site" then 50
    else if class == "cross-scope" then 40
    else if class == "shared-local" then 30
    else if class == "tenant-private" then 20
    else if class == "controlled" then 10
    else 0;

  maxExposureClass =
    classes:
    builtins.foldl'
      (selected: class: if priorityForExposureClass class > priorityForExposureClass selected then class else selected)
      "unexposed"
      classes;

  exposureForService =
    serviceName: providerTenants:
    let
      owningScope = {
        kind = "service";
        name = serviceName;
      };
      serviceRelations =
        builtins.filter
          (relation:
            let
              to = attrsOrEmpty (relation.to or null);
            in
            (relation.action or "allow") == "allow"
            && (to.kind or null) == "service"
            && (to.name or null) == serviceName)
          (listOrEmpty (policyEndpointBindings.relations or null));

      records =
        builtins.map
          (relation:
            let
              requesterScope = normalizeRequesterScope relation;
              exposureClass = exposureClassForRelation providerTenants relation requesterScope;
            in
            {
              inherit exposureClass;
              relationId = relation.id or null;
              ownerScope = owningScope;
              inherit requesterScope;
              sourceKind = requesterScope.kind;
              sourceNames = requesterScope.names;
              trafficType = relation.trafficType or null;
            })
          serviceRelations;
    in
    {
      class = maxExposureClass (builtins.map (record: record.exposureClass) records);
      inherit owningScope;
      classificationSource = "communicationContract.relations";
      notInferredFrom = [
        "address-ownership"
        "service-existence"
        "route-availability"
        "host-placement"
      ];
      inherit records;
    };
in
builtins.map
  (
    serviceName:
    let
      resolvedService = policyEndpointBindings.services.${serviceName};
      providerNames =
        if builtins.isList (resolvedService.providers or null) then
          requireStringList "${sitePath}.services.${serviceName}.providers" resolvedService.providers
        else
          [ ];
      providerTenants = uniqueStrings (
        lib.concatMap providerTenantsForServiceProvider providerNames
      );
      exposure = exposureForService serviceName providerTenants;

      # SMS-040 N1: Missing exposure class for any service
      _missingExposure =
        if exposure.class == "unexposed" then
          failForwarding
            "${sitePath}.services.${serviceName}"
            "diagnostic.missing-exposure-class: service ${serviceName} has no exposure class (no communicationContract relations with action=allow targeting this service)"
        else
          true;

      # SMS-020 N2: Host-inferred scope rejection
      hostPlacementExposure = resolvedService.hostPlacementExposure or null;
      _hostInferred =
        if hostPlacementExposure != null then
          failForwarding
            "${sitePath}.services.${serviceName}.hostPlacementExposure"
            "exposure-scope-inherited-from-host: service exposure scope must be bound from communicationContract, not inherited from host placement"
        else
          true;
    in
    builtins.seq _missingExposure (
      builtins.seq _hostInferred (
        resolvedService
          // {
      name = serviceName;
      exposureClass = exposure.class;
      inherit exposure;
      providerEndpoints = builtins.filter (endpoint: endpoint != null) (
        builtins.map providerEndpointForServiceProvider providerNames
      );
      inherit providerTenants;
      preferredUplinks = preferredDnsUplinksForService serviceName;
      preferredUplinksByRelation = preferredDnsUplinksByRelationForService serviceName;
    }
      )
      )
  )
  (sortedNames policyEndpointBindings.services)
