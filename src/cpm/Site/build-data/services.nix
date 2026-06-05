{ lib
, helpers
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
  inherit (helpers) requireStringList sortedNames;

  listOrEmpty = value: if builtins.isList value then value else [ ];
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };

  sourceNamesForEndpoint =
    endpoint:
    let
      attrs = attrsOrEmpty endpoint;
      kind = attrs.kind or null;
    in
    if kind == "tenant" && builtins.isString (attrs.name or null) then
      [ attrs.name ]
    else if kind == "tenant-set" then
      listOrEmpty (attrs.members or null)
    else if kind == "external" then
      if builtins.isString (attrs.name or null) then [ attrs.name ] else listOrEmpty (attrs.uplinks or null)
    else if kind == "service" && builtins.isString (attrs.name or null) then
      [ attrs.name ]
    else
      [ ];

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
    providerTenants: relation:
    let
      source = attrsOrEmpty (relation.from or null);
      sourceKind = source.kind or null;
      sourceTenants = sourceNamesForEndpoint source;
      allSourcesOwnProvider =
        sourceTenants != [ ]
        && providerTenants != [ ]
        && builtins.all (tenant: builtins.elem tenant providerTenants) sourceTenants;
    in
    if endpointIsPublicExternal source then
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
              source = attrsOrEmpty (relation.from or null);
              exposureClass = exposureClassForRelation providerTenants relation;
            in
            {
              inherit exposureClass;
              relationId = relation.id or null;
              sourceKind = source.kind or null;
              sourceNames = sourceNamesForEndpoint source;
              trafficType = relation.trafficType or null;
            })
          serviceRelations;
    in
    {
      class = maxExposureClass (builtins.map (record: record.exposureClass) records);
      owningScope = {
        kind = "service";
        name = serviceName;
      };
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
    in
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
  (sortedNames policyEndpointBindings.services)
