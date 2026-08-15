{
  lib,
  attrsOrEmpty,
  requireStringList,
  uniqueStrings,
  orderedUniqueStrings,
  stripPrefixLength,
  tenantAttachmentsForNode,
  policyDerivedDnsAllowFromForListeners,
  policyDerivedDnsAllowedClassesForListeners,
  policyDerivedDnsAllowedClassesForTenants,
  policyDerivedDnsDirectEgressBlockedTenants,
  policyDerivedDnsDirectEgressBlockedForListeners,
  policyDerivedDnsDirectEgressBlockedForTenants,
  policyDerivedDnsForwardersForListeners,
  policyDerivedDnsForwardersForTenants,
  policyDerivedDnsUpstreamRecordsForListeners,
  normalizeRuntimeServices,
}:

{ nodePath
    , nodeName
    , nodeAttrs
    , targetDef
    , loopback ? { }
    , runtimeOriginEgress ? null
    ,
    }:
    let
      normalized = normalizeRuntimeServices targetDef;
      dnsService = attrsOrEmpty (normalized.dns or null);
      explicitForwarders =
        if builtins.isList (dnsService.forwarders or null) then requireStringList "${targetDef.nodePath}.services.dns.forwarders" dnsService.forwarders else [ ];
      registeredUpstreams =
        if builtins.isList (dnsService.registeredUpstreams or null) then dnsService.registeredUpstreams else [ ];
      explicitAllowFrom =
        if builtins.isList (dnsService.allowFrom or null) then requireStringList "${targetDef.nodePath}.services.dns.allowFrom" dnsService.allowFrom else [ ];
      listenAddresses =
        if builtins.isList (dnsService.listen or null) then requireStringList "${targetDef.nodePath}.services.dns.listen" dnsService.listen else [ ];
      explicitOutgoingInterfaces =
        if builtins.isList (dnsService.outgoingInterfaces or null) then
          requireStringList "${targetDef.nodePath}.services.dns.outgoingInterfaces" dnsService.outgoingInterfaces
        else
          [ ];
      roles = attrsOrEmpty (dnsService.roles or null);
      recursionRole = attrsOrEmpty (roles.recursion or null);
      explicitRecursionOutgoingInterfaces =
        if builtins.isList (recursionRole.outgoingInterfaces or null) then
          requireStringList "${targetDef.nodePath}.services.dns.roles.recursion.outgoingInterfaces" recursionRole.outgoingInterfaces
        else
          [ ];
      derivedOutgoingInterfaces =
        if (nodeAttrs.role or null) == "core" then
          [ ]
        else
          builtins.filter (addr: addr != "127.0.0.1" && addr != "::1") listenAddresses;
      tenantNames = tenantAttachmentsForNode nodePath nodeName nodeAttrs;
      tenantDerivedForwarders = policyDerivedDnsForwardersForTenants tenantNames;
      listenerDerivedForwarders =
        if builtins.isList (dnsService.listen or null) then
          policyDerivedDnsForwardersForListeners dnsService.listen
        else
          [ ];
      derivedForwarders = orderedUniqueStrings (
        if listenerDerivedForwarders != [ ] then
          listenerDerivedForwarders
        else
          tenantDerivedForwarders
      );
      derivedUpstreamRecords =
        if builtins.isList (dnsService.listen or null) then
          policyDerivedDnsUpstreamRecordsForListeners dnsService.listen
        else
          [ ];
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
      directEgressBlockedTenants = policyDerivedDnsDirectEgressBlockedTenants tenantNames;
      filteredDerivedForwarders = builtins.filter (addr: !(builtins.elem addr listenAddresses)) derivedForwarders;
      mergedForwarders =
        if registeredUpstreams != [ ] then
          [ ]
        else if explicitForwarders != [ ] then
          explicitForwarders
        else if derivedUpstreamRecords != [ ] then
          [ ]
        else
          orderedUniqueStrings filteredDerivedForwarders;
      mergedAllowFrom = if derivedAllowFrom == [ ] then explicitAllowFrom else uniqueStrings (explicitAllowFrom ++ derivedAllowFrom);
      mergedOutgoingInterfaces =
        if explicitOutgoingInterfaces != [ ] then
          explicitOutgoingInterfaces
        else if mergedForwarders != [ ] then
          derivedOutgoingInterfaces
        else
          [ ];
      mergedAllowedClasses = uniqueStrings ((dnsService.allowedUpstreamClasses or [ ]) ++ derivedAllowedClasses);
      loopbackRecursionSources = orderedUniqueStrings [
        (stripPrefixLength (loopback.ipv4 or loopback.addr4 or ""))
        (stripPrefixLength (loopback.ipv6 or loopback.addr6 or ""))
      ];
      runtimeOriginEnabled = (attrsOrEmpty runtimeOriginEgress).enabled or false;
      recursionOutgoingInterfaces =
        if explicitRecursionOutgoingInterfaces != [ ] then
          explicitRecursionOutgoingInterfaces
        else if explicitOutgoingInterfaces != [ ] then
          explicitOutgoingInterfaces
        else if (nodeAttrs.role or null) == "core" && runtimeOriginEnabled then
          loopbackRecursionSources
        else if (nodeAttrs.role or null) == "core" then
          [ ]
        else
          mergedOutgoingInterfaces;
      mergedRoles =
        roles
        // {
          recursion = recursionRole // {
            outgoingInterfaces = recursionOutgoingInterfaces;
            allowedUpstreamClasses = mergedAllowedClasses;
          };
        }
        // lib.optionalAttrs (listenAddresses != [ ] || mergedAllowFrom != [ ]) {
          local = (attrsOrEmpty (roles.local or null))
            // lib.optionalAttrs (listenAddresses != [ ]) { listen = listenAddresses; }
            // lib.optionalAttrs (mergedAllowFrom != [ ]) { allowFrom = mergedAllowFrom; };
        };
      blockDirectEgress =
        (policyDerivedDnsDirectEgressBlockedForTenants tenantNames)
        || (
          builtins.isList (dnsService.listen or null)
          && policyDerivedDnsDirectEgressBlockedForListeners dnsService.listen
        );
      validatePolicyDerivedDns =
        if dnsService == { } then
          true
        else
          builtins.deepSeq derivedForwarders (
            builtins.deepSeq derivedUpstreamRecords true
          );
    in
    builtins.seq validatePolicyDerivedDns (
      normalized
      // lib.optionalAttrs (dnsService != { }) {
        dns =
          dnsService
          // lib.optionalAttrs (mergedAllowFrom != [ ]) { allowFrom = mergedAllowFrom; }
          // lib.optionalAttrs (mergedForwarders != [ ]) { forwarders = mergedForwarders; }
          // lib.optionalAttrs (derivedUpstreamRecords != [ ]) { upstreamResolvers = derivedUpstreamRecords; }
          // lib.optionalAttrs (mergedOutgoingInterfaces != [ ]) { outgoingInterfaces = mergedOutgoingInterfaces; }
          // { roles = mergedRoles; }
          // lib.optionalAttrs (mergedAllowedClasses != [ ]) { allowedUpstreamClasses = mergedAllowedClasses; }
          // lib.optionalAttrs blockDirectEgress { inherit directEgressBlockedTenants; }
          // lib.optionalAttrs blockDirectEgress { blockDirectEgress = true; };
      }
    )
