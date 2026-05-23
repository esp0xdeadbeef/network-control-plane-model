{ lib
, helpers
, sitePath
, attachments
, attrsOrEmpty
, failInventory
, policyDerivedDnsAllowFromForListeners
, policyDerivedDnsAllowedClassesForListeners
, policyDerivedDnsAllowedClassesForTenants
, policyDerivedDnsDirectEgressBlockedTenants
, policyDerivedDnsDirectEgressBlockedForListeners
, policyDerivedDnsDirectEgressBlockedForTenants
, policyDerivedDnsForwardersForListeners
, policyDerivedDnsForwardersForTenants
, uniqueStrings
,
}:

let
  inherit (helpers)
    isNonEmptyString
    requireAttrs
    requireList
    requireStringList
    sortedNames
    ;

  dns = import ./dns.nix { inherit lib helpers failInventory; };
  mdns = import ./mdns.nix { inherit lib helpers failInventory; };
  inherit (dns) normalizeDnsService;
  inherit (mdns) normalizeMdnsService;

  orderedUniqueStrings =
    values:
    builtins.foldl'
      (
        acc: value:
        if isNonEmptyString value && !(builtins.elem value acc) then acc ++ [ value ] else acc
      )
      [ ]
      values;

  stripPrefixLength = value:
    if !(isNonEmptyString value) then "" else builtins.head (lib.splitString "/" value);

  normalizeRuntimeServices = targetDef:
    let
      servicesPath = "${targetDef.nodePath}.services";
      services = requireAttrs servicesPath (targetDef.node.services or null);
    in
    builtins.listToAttrs (
      builtins.map
        (serviceName: {
          name = serviceName;
          value =
            if serviceName == "dns" then
              normalizeDnsService servicesPath services.${serviceName}
            else if serviceName == "mdns" then
              normalizeMdnsService servicesPath services.${serviceName}
            else
              services.${serviceName};
        })
        (sortedNames services)
    );

  tenantAttachmentsForNode = nodePath: nodeName: nodeAttrs:
    uniqueStrings (
      (builtins.map
        (attachment:
          let attachmentAttrs = requireAttrs "${sitePath}.attachments[*]" attachment;
          in
          if (attachmentAttrs.kind or null) == "tenant" && (attachmentAttrs.unit or null) == nodeName && isNonEmptyString (attachmentAttrs.name or null) then
            attachmentAttrs.name
          else
            "")
        attachments)
      ++ (
        if builtins.isList (nodeAttrs.attachments or null) then
          builtins.map
            (attachment:
              let attachmentAttrs = requireAttrs "${nodePath}.attachments[*]" attachment;
              in
              if (attachmentAttrs.kind or null) == "tenant" && isNonEmptyString (attachmentAttrs.name or null) then attachmentAttrs.name else "")
            nodeAttrs.attachments
        else
          [ ]
      )
    );

  resolveRuntimeServices = import ./resolve.nix {
    inherit
      lib
      attrsOrEmpty
      requireStringList
      uniqueStrings
      orderedUniqueStrings
      stripPrefixLength
      tenantAttachmentsForNode
      policyDerivedDnsAllowFromForListeners
      policyDerivedDnsAllowedClassesForListeners
      policyDerivedDnsAllowedClassesForTenants
      policyDerivedDnsDirectEgressBlockedTenants
      policyDerivedDnsDirectEgressBlockedForListeners
      policyDerivedDnsDirectEgressBlockedForTenants
      policyDerivedDnsForwardersForListeners
      policyDerivedDnsForwardersForTenants
      normalizeRuntimeServices
      ;
  };

in
{
  inherit
    resolveRuntimeServices
    tenantAttachmentsForNode
    ;
}
