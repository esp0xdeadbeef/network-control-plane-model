{
  lib,
  helpers,
  dnsPolicy,
  sitePath,
  allowedRelations,
  serviceDefinitions,
}:

let
  inherit (helpers) hasAttr requireStringList sortedNames;
  inherit (dnsPolicy)
    consumerInterfaceCidrsForTenant
    effectiveTrafficTypeForRelation
    providerAddressesForDnsService
    relationEndpointMatchesTenant
    tenantNamesForRelationEndpoint
    tenantPrefixesForName
    ;
  uniqueStrings = list: builtins.attrNames (builtins.listToAttrs (map (value: { name = value; value = true; }) list));

  allowedDnsRelation =
    relation:
    let
      relationAttrs = if builtins.isAttrs relation then relation else { };
      serviceName = if builtins.isAttrs (relationAttrs.to or null) && builtins.isString (relationAttrs.to.name or null) then relationAttrs.to.name else null;
      serviceDef = if serviceName != null && hasAttr serviceName serviceDefinitions then serviceDefinitions.${serviceName} else { };
    in
    (relationAttrs.action or "allow") == "allow"
    && builtins.isAttrs (relationAttrs.to or null)
    && (relationAttrs.to.kind or null) == "service"
    && serviceName != null
    && hasAttr serviceName serviceDefinitions
    && effectiveTrafficTypeForRelation relationAttrs serviceDef == "dns";

  dnsRelations = builtins.filter allowedDnsRelation allowedRelations;

  providersForService =
    serviceName:
    let
      serviceDef = serviceDefinitions.${serviceName};
    in
    if builtins.isList (serviceDef.providers or null) then
      requireStringList "${sitePath}.communicationContract.services.${serviceName}.providers" serviceDef.providers
    else
      [ ];

  dnsServiceRouteSpecs = import ./service-route-specs.nix {
    inherit
      lib
      helpers
      dnsPolicy
      sitePath
      allowedRelations
      serviceDefinitions
      dnsRelations
      providersForService
      ;
  };

  allowedClasses = import ./allowed-classes.nix {
    inherit lib allowedRelations dnsPolicy providersForService serviceDefinitions;
  };

  relationPriority = relation:
    if builtins.isInt (relation.priority or null) then relation.priority else 1000;

  externalNamesFor =
    endpoint:
    if !builtins.isAttrs endpoint || (endpoint.kind or null) != "external" then
      [ ]
    else
      uniqueStrings (
        lib.optional (builtins.isString (endpoint.name or null) && endpoint.name != "") endpoint.name
        ++ (
          if builtins.isList (endpoint.uplinks or null) then
            builtins.filter builtins.isString endpoint.uplinks
          else
            [ ]
        )
      );

  externalEndpointsOverlap = left: right:
    let
      leftNames = externalNamesFor left;
      rightNames = externalNamesFor right;
    in
    leftNames == [ ] || rightNames == [ ] || lib.any (name: builtins.elem name rightNames) leftNames;

  dnsExternalRelation =
    action: relation:
    let
      relationAttrs = if builtins.isAttrs relation then relation else { };
    in
    (relationAttrs.action or "allow") == action
    && (relationAttrs.trafficType or null) == "dns"
    && builtins.isAttrs (relationAttrs.to or null)
    && (relationAttrs.to.kind or null) == "external";

  allowedDnsExternalRelations = builtins.filter (dnsExternalRelation "allow") allowedRelations;
  deniedDnsExternalRelations = builtins.filter (dnsExternalRelation "deny") allowedRelations;

  hostedDnsServicesForListeners =
    listenAddrs:
    let
      listenSet = uniqueStrings listenAddrs;
    in
    builtins.filter
      (serviceName:
        let
          serviceDef = serviceDefinitions.${serviceName};
          providerAddresses = lib.concatMap providerAddressesForDnsService (providersForService serviceName);
        in
        (serviceDef.trafficType or null) == "dns" && lib.any (addr: builtins.elem addr listenSet) providerAddresses)
      (sortedNames serviceDefinitions);
in
{
  inherit dnsServiceRouteSpecs;

  policyDerivedDnsForwardersForTenants =
    tenantNames:
    uniqueStrings (
      lib.concatMap
        (tenantName:
          let
            allowedDnsServices =
              uniqueStrings (
                builtins.map
                  (relation:
                    let
                      serviceName = relation.to.name or null;
                    in
                    serviceName)
                  (builtins.filter (relation: relationEndpointMatchesTenant tenantName (relation.from or null)) dnsRelations)
              );
          in
          lib.concatMap (serviceName: lib.concatMap providerAddressesForDnsService (providersForService serviceName)) allowedDnsServices)
        tenantNames
    );

  policyDerivedDnsAllowFromForListeners =
    listenAddrs:
    let
      listenSet = uniqueStrings listenAddrs;
      hostedDnsServices =
        builtins.filter
          (serviceName:
            let
              serviceDef = serviceDefinitions.${serviceName};
              providerAddresses = lib.concatMap providerAddressesForDnsService (providersForService serviceName);
            in
            (serviceDef.trafficType or null) == "dns" && lib.any (addr: builtins.elem addr listenSet) providerAddresses)
          (sortedNames serviceDefinitions);
    in
    uniqueStrings (
      lib.concatMap
        (serviceName:
          lib.concatMap
            (relation:
              let
                relationAttrs = if builtins.isAttrs relation then relation else { };
                relationServiceName =
                  if builtins.isAttrs (relationAttrs.to or null) && builtins.isString (relationAttrs.to.name or null) then
                    relationAttrs.to.name
                  else
                    null;
              in
              if relationServiceName == serviceName then
                lib.concatMap
                  (tenantName: (tenantPrefixesForName tenantName) ++ (consumerInterfaceCidrsForTenant tenantName))
                  (tenantNamesForRelationEndpoint (relationAttrs.from or null))
              else
                [ ])
            dnsRelations)
        hostedDnsServices
    );

  policyDerivedDnsAllowedClassesForTenants = allowedClasses.forTenants;
  policyDerivedDnsAllowedClassesForListeners = allowedClasses.forListeners;
  policyDerivedDnsDirectEgressBlockedForTenants =
    tenantNames:
    builtins.any
      (
        deny:
        let
          denyPriority = relationPriority deny;
          hasMatchingAllow =
            builtins.any
              (
                allow:
                relationPriority allow <= denyPriority
                && externalEndpointsOverlap (allow.to or { }) (deny.to or { })
                && builtins.any
                  (tenantName:
                    relationEndpointMatchesTenant tenantName (allow.from or null)
                    && relationEndpointMatchesTenant tenantName (deny.from or null))
                  tenantNames
              )
              allowedDnsExternalRelations;
        in
        !hasMatchingAllow
        && builtins.any (tenantName: relationEndpointMatchesTenant tenantName (deny.from or null)) tenantNames
      )
      deniedDnsExternalRelations;
  policyDerivedDnsDirectEgressBlockedForListeners =
    listenAddrs:
    let
      hostedDnsServices = hostedDnsServicesForListeners listenAddrs;
    in
    builtins.any
      (
        relation:
        builtins.isAttrs (relation.from or null)
        && (relation.from.kind or null) == "service"
        && builtins.elem (relation.from.name or "") hostedDnsServices
      )
      allowedDnsExternalRelations;
}
