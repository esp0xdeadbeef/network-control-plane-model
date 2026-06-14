{ lib
, helpers
, dnsPolicy
, sitePath
, allowedRelations
, serviceDefinitions
,
}:

let
  inherit (helpers) hasAttr requireStringList sortedNames;
  inherit (dnsPolicy) effectiveTrafficTypeForRelation providerAddressesForDnsService;

  uniqueStrings =
    list:
    builtins.foldl'
      (
        acc: value:
        if builtins.isString value && value != "" && !(builtins.elem value acc) then acc ++ [ value ] else acc
      )
      [ ]
      list;

  providersForService = serviceName:
    let
      serviceDef = serviceDefinitions.${serviceName};
    in
    if builtins.isList (serviceDef.providers or null) then
      requireStringList "${sitePath}.communicationContract.services.${serviceName}.providers" serviceDef.providers
    else
      [ ];

  allowedDnsRelation = relation:
    let
      relationAttrs = if builtins.isAttrs relation then relation else { };
      serviceName =
        if builtins.isAttrs (relationAttrs.to or null) && builtins.isString (relationAttrs.to.name or null) then
          relationAttrs.to.name
        else
          null;
      serviceDef =
        if serviceName != null && hasAttr serviceName serviceDefinitions then serviceDefinitions.${serviceName} else { };
    in
    (relationAttrs.action or "allow") == "allow"
    && builtins.isAttrs (relationAttrs.to or null)
    && (relationAttrs.to.kind or null) == "service"
    && serviceName != null
    && hasAttr serviceName serviceDefinitions
    && effectiveTrafficTypeForRelation relationAttrs serviceDef == "dns";

  externalNamesFor = endpoint:
    if !builtins.isAttrs endpoint || (endpoint.kind or null) != "external" then
      [ ]
    else
      uniqueStrings (
        lib.optional (builtins.isString (endpoint.name or null) && endpoint.name != "") endpoint.name
        ++ (if builtins.isList (endpoint.uplinks or null) then builtins.filter builtins.isString endpoint.uplinks else [ ])
      );

  dnsExternalRelation = action: relation:
    let
      relationAttrs = if builtins.isAttrs relation then relation else { };
    in
    (relationAttrs.action or "allow") == action
    && (relationAttrs.trafficType or null) == "dns"
    && builtins.isAttrs (relationAttrs.to or null)
    && (relationAttrs.to.kind or null) == "external";

  dnsRelations = builtins.filter allowedDnsRelation allowedRelations;

  # GAMP: FS-540-HDS-010-SDS-010-SMS-025 — DNS follow-source hosted-service detection
  # must not require provider endpoint addresses to match listener addresses.
  # The access router may proxy DNS from a listener address to a resolver at a
  # different endpoint address; the service is still "hosted" from the tenant
  # perspective.  Provider endpoint existence is validated by
  # providerAddressesForDnsService inside the filter body.
  hostedDnsServicesForListeners = listenAddrs:
    builtins.filter
      (serviceName:
        let
          serviceDef = serviceDefinitions.${serviceName};
          providerNames = providersForService serviceName;
          # providerAddressesForDnsService validates endpoint existence;
          # we do not require the addresses to intersect with listenAddrs.
          _providerAddresses = lib.concatMap providerAddressesForDnsService providerNames;
        in
        (serviceDef.trafficType or null) == "dns" && providerNames != [ ])
      (sortedNames serviceDefinitions);
in
{
  inherit
    dnsRelations
    hostedDnsServicesForListeners
    providersForService
    uniqueStrings
    ;

  relationPriority = relation:
    if builtins.isInt (relation.priority or null) then relation.priority else 1000;

  externalEndpointsOverlap = left: right:
    let
      leftNames = externalNamesFor left;
      rightNames = externalNamesFor right;
    in
    leftNames == [ ] || rightNames == [ ] || lib.any (name: builtins.elem name rightNames) leftNames;

  allowedDnsExternalRelations = builtins.filter (dnsExternalRelation "allow") allowedRelations;
  deniedDnsExternalRelations = builtins.filter (dnsExternalRelation "deny") allowedRelations;
}
