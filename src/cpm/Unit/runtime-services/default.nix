{
  lib,
  helpers,
  sitePath,
  attachments,
  attrsOrEmpty,
  failInventory,
  policyDerivedDnsAllowFromForListeners,
  policyDerivedDnsAllowedClassesForListeners,
  policyDerivedDnsAllowedClassesForTenants,
  policyDerivedDnsForwardersForTenants,
  uniqueStrings,
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

  resolveRuntimeServices =
    {
      nodePath,
      nodeName,
      nodeAttrs,
      targetDef,
    }:
    let
      normalized = normalizeRuntimeServices targetDef;
      dnsService = attrsOrEmpty (normalized.dns or null);
      explicitForwarders =
        if builtins.isList (dnsService.forwarders or null) then requireStringList "${targetDef.nodePath}.services.dns.forwarders" dnsService.forwarders else [ ];
      explicitAllowFrom =
        if builtins.isList (dnsService.allowFrom or null) then requireStringList "${targetDef.nodePath}.services.dns.allowFrom" dnsService.allowFrom else [ ];
      listenAddresses =
        if builtins.isList (dnsService.listen or null) then requireStringList "${targetDef.nodePath}.services.dns.listen" dnsService.listen else [ ];
      tenantNames = tenantAttachmentsForNode nodePath nodeName nodeAttrs;
      derivedForwarders = policyDerivedDnsForwardersForTenants tenantNames;
      derivedAllowFrom =
        if builtins.isList (dnsService.listen or null) then policyDerivedDnsAllowFromForListeners dnsService.listen else [ ];
      derivedAllowedClasses =
        uniqueStrings (
          (policyDerivedDnsAllowedClassesForTenants tenantNames)
          ++ (
            if builtins.isList (dnsService.listen or null) then
              policyDerivedDnsAllowedClassesForListeners dnsService.listen
            else
              [ ]
          )
        );
      filteredDerivedForwarders = builtins.filter (addr: !(builtins.elem addr listenAddresses)) derivedForwarders;
      mergedForwarders = if filteredDerivedForwarders == [ ] then explicitForwarders else uniqueStrings filteredDerivedForwarders;
      mergedAllowFrom = if derivedAllowFrom == [ ] then explicitAllowFrom else uniqueStrings (explicitAllowFrom ++ derivedAllowFrom);
      mergedAllowedClasses = uniqueStrings ((dnsService.allowedUpstreamClasses or [ ]) ++ derivedAllowedClasses);
    in
    normalized
    // lib.optionalAttrs (dnsService != { }) {
      dns =
        dnsService
        // lib.optionalAttrs (mergedAllowFrom != [ ]) { allowFrom = mergedAllowFrom; }
        // lib.optionalAttrs (mergedForwarders != [ ]) { forwarders = mergedForwarders; }
        // lib.optionalAttrs (mergedAllowedClasses != [ ]) { allowedUpstreamClasses = mergedAllowedClasses; };
    };

in
{
  inherit
    resolveRuntimeServices
    tenantAttachmentsForNode
    ;
}
