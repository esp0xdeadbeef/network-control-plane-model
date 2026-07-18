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
  inherit (dnsPolicy) effectiveTrafficTypeForRelation;

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

  stripPrefixLength = value:
    if !(builtins.isString value) || value == "" then "" else builtins.head (lib.splitString "/" value);

  providerNodeAddresses = providerName:
    let
      node = if builtins.hasAttr providerName dnsPolicy.nodes then dnsPolicy.nodes.${providerName} else { };
      loopback = if builtins.isAttrs (node.loopback or null) then node.loopback else { };
      interfaces = if builtins.isAttrs (node.interfaces or null) then node.interfaces else { };
      interfaceAddresses = lib.concatMap
        (iface: [
          (stripPrefixLength (iface.addr4 or ""))
          (stripPrefixLength (iface.addr6 or ""))
        ])
        (builtins.attrValues interfaces);
    in
    uniqueStrings ([
      (stripPrefixLength (loopback.ipv4 or ""))
      (stripPrefixLength (loopback.ipv6 or ""))
    ] ++ interfaceAddresses);

  hostedDnsServicesForListeners = listenAddrs:
    let listenerSet = uniqueStrings listenAddrs;
    in
    builtins.filter
      (serviceName:
        let
          serviceDef = serviceDefinitions.${serviceName};
          providerNames = providersForService serviceName;
          providerAddresses = lib.concatMap providerNodeAddresses providerNames;
        in
        (serviceDef.trafficType or null) == "dns"
        && providerNames != [ ]
        && lib.any (address: builtins.elem address listenerSet) providerAddresses)
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
