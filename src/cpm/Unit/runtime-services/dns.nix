{ lib
, helpers
, failInventory
,
}:

let
  inherit (helpers)
    isNonEmptyString
    requireAttrs
    requireList
    requireString
    ;

  normalizeStringList = dnsPath: dns: fieldName:
    let
      path = "${dnsPath}.${fieldName}";
      value = dns.${fieldName} or [ ];
    in
    builtins.map
      (entry:
        let rendered = requireString "${path}[*]" entry;
        in if isNonEmptyString rendered then rendered else failInventory path "must not contain empty strings")
      (requireList path value);

  ipv4Octet = "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])";

  isIpv4Address =
    value:
    builtins.match "${ipv4Octet}\\.${ipv4Octet}\\.${ipv4Octet}\\.${ipv4Octet}" value != null;

  isIpv6Address =
    value:
    builtins.match "([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}" value != null;
  defaults = import ./dns-defaults.nix;
  namespaceContracts = import ./dns-namespace-contracts.nix { inherit lib helpers failInventory; };
  normalizeNamespaceFallback = import ./dns-namespace-fallback.nix { inherit lib helpers failInventory; };
  localRecords = import ./dns-local-records.nix { inherit lib helpers failInventory; };
  validationAuthorityContract = import ./dns-validation-authority.nix {
    inherit
      lib
      helpers
      failInventory
      isIpv4Address
      isIpv6Address
      ;
  };
  inherit (localRecords)
    normalizeLocalRecords
    normalizeLocalZones
    ;
  inherit (namespaceContracts)
    normalizeLeaseNameScopes
    normalizeNamespaceAuthority
    normalizeNamespaceDiagnostics
    normalizeRecordPublications
    ;

  normalizeForwarderList = dnsPath: dns: fieldName:
    let
      path = "${dnsPath}.${fieldName}";
    in
    builtins.map
      (entry:
        let
          rendered = requireString "${path}[*]" entry;
        in
        if !(isNonEmptyString rendered) then
          failInventory path "must not contain empty strings"
        else if isIpv4Address rendered || isIpv6Address rendered then
          rendered
        else
          failInventory path "must contain IPv4 or IPv6 address literals; resolve runtime placeholders before CPM")
      (requireList path (dns.${fieldName} or [ ]));

  boolOrDefault =
    path: value: default:
    if value == null then
      default
    else if builtins.isBool value then
      value
    else
      failInventory path "must be a boolean";

  attrsList =
    path: value:
    builtins.map
      (entry: requireAttrs "${path}[*]" entry)
      (requireList path value);

in
{
  normalizeDnsService = servicesPath: dnsValue:
    let
      dnsPath = "${servicesPath}.dns";
      dns = requireAttrs dnsPath dnsValue;
      listen = normalizeStringList dnsPath dns "listen";
      allowFrom = normalizeStringList dnsPath dns "allowFrom";
      forwarders =
        if dns ? forwarders then
          normalizeForwarderList dnsPath dns "forwarders"
        else if dns ? upstreams then
          normalizeForwarderList dnsPath dns "upstreams"
        else
          [ ];
      implementation =
        if dns ? implementation then requireString "${dnsPath}.implementation" dns.implementation else null;
      outgoingInterfaces =
        if dns ? outgoingInterfaces then normalizeStringList dnsPath dns "outgoingInterfaces" else [ ];
      rolesInput = if dns ? roles then requireAttrs "${dnsPath}.roles" dns.roles else { };
      localRoleInput = if rolesInput ? local then requireAttrs "${dnsPath}.roles.local" rolesInput.local else { };
      recursionRoleInput = if rolesInput ? recursion then requireAttrs "${dnsPath}.roles.recursion" rolesInput.recursion else { };
      localRole =
        { }
        // lib.optionalAttrs (localRoleInput ? listen) { listen = normalizeStringList "${dnsPath}.roles.local" localRoleInput "listen"; }
        // lib.optionalAttrs (localRoleInput ? allowFrom) { allowFrom = normalizeStringList "${dnsPath}.roles.local" localRoleInput "allowFrom"; };
      recursionRole =
        { }
        // lib.optionalAttrs (recursionRoleInput ? outgoingInterfaces) { outgoingInterfaces = normalizeStringList "${dnsPath}.roles.recursion" recursionRoleInput "outgoingInterfaces"; }
        // lib.optionalAttrs (recursionRoleInput ? allowedUpstreamClasses) { allowedUpstreamClasses = normalizeStringList "${dnsPath}.roles.recursion" recursionRoleInput "allowedUpstreamClasses"; };
      roles =
        { }
        // lib.optionalAttrs (localRole != { }) { local = localRole; }
        // lib.optionalAttrs (recursionRole != { }) { recursion = recursionRole; };
      _forwarderConflict =
        if dns ? forwarders && dns ? upstreams then
          failInventory dnsPath "must define only one of 'forwarders' or 'upstreams'"
        else
          true;
      deniedResolverCidrs =
        if dns ? deniedResolverCidrs then
          normalizeStringList dnsPath dns "deniedResolverCidrs"
        else
          [ ];
      killSwitchInput = requireAttrs "${dnsPath}.killSwitch" (dns.killSwitch or { });
      killSwitch = {
        enabled = boolOrDefault "${dnsPath}.killSwitch.enabled" (killSwitchInput.enabled or null) true;
        blockPublicResolvers =
          boolOrDefault "${dnsPath}.killSwitch.blockPublicResolvers"
            (killSwitchInput.blockPublicResolvers or null)
            (deniedResolverCidrs != [ ]);
        blockImplicitDefaultRouteDns =
          boolOrDefault "${dnsPath}.killSwitch.blockImplicitDefaultRouteDns"
            (killSwitchInput.blockImplicitDefaultRouteDns or null)
            true;
        allowPublicResolverFallback =
          boolOrDefault "${dnsPath}.killSwitch.allowPublicResolverFallback"
            (killSwitchInput.allowPublicResolverFallback or null)
            false;
      };
      _killSwitchNoPublicFallback =
        if killSwitch.enabled && killSwitch.blockPublicResolvers && killSwitch.allowPublicResolverFallback then
          failInventory
            "${dnsPath}.killSwitch.allowPublicResolverFallback"
            "must be false when DNS public resolver blocking is enabled"
        else
          true;
      routePreference =
        if dns ? routePreference then normalizeStringList dnsPath dns "routePreference" else defaults.defaultRoutePreference;
      allowedUpstreamClasses =
        if dns ? allowedUpstreamClasses then normalizeStringList dnsPath dns "allowedUpstreamClasses" else [ "local-access" ];
      _killSwitchExplicitDeniedResolverCidrs =
        if killSwitch.enabled && killSwitch.blockPublicResolvers && deniedResolverCidrs == [ ] then
          failInventory
            "${dnsPath}.deniedResolverCidrs"
            "must be explicitly set to one or more CIDRs when DNS public resolver blocking is enabled"
        else
          true;
      directEgressBlockedTenants =
        if dns ? directEgressBlockedTenants then normalizeStringList dnsPath dns "directEgressBlockedTenants" else null;
      routeContracts = requireList "${dnsPath}.routeContracts" (dns.routeContracts or [ ]);
      policyMatrix = requireList "${dnsPath}.policyMatrix" (dns.policyMatrix or [ ]);
      upstreamResolvers = requireList "${dnsPath}.upstreamResolvers" (dns.upstreamResolvers or [ ]);
      recursionMode =
        if dns ? recursionMode then
          let
            value = requireString "${dnsPath}.recursionMode" dns.recursionMode;
          in
          if builtins.elem value [
            "iterative"
            "forwarding"
            "local-only"
          ] then
            value
          else
            failInventory "${dnsPath}.recursionMode" "must be iterative, forwarding, or local-only"
        else
          null;
      localForwardZones = builtins.map
        (zone:
          let
            name = requireString "${dnsPath}.localForwardZones[*].name" (zone.name or null);
            relationId = requireString "${dnsPath}.localForwardZones[*].relationId" (zone.relationId or null);
            forwardTo = normalizeForwarderList "${dnsPath}.localForwardZones[*]" zone "forwardTo";
            forwardFirst = boolOrDefault "${dnsPath}.localForwardZones[*].forwardFirst" (zone.forwardFirst or null) false;
          in
          if name == "" || relationId == "" || forwardTo == [ ] then
            failInventory "${dnsPath}.localForwardZones[*]" "requires non-empty name, relationId, and forwardTo"
          else
            { inherit name relationId forwardTo forwardFirst; })
        (attrsList "${dnsPath}.localForwardZones" (dns.localForwardZones or [ ]));
      requesterPolicies = builtins.map
        (policy:
          let
            requesterService = requireString "${dnsPath}.requesterPolicies[*].requesterService" (policy.requesterService or null);
            relationId = requireString "${dnsPath}.requesterPolicies[*].relationId" (policy.relationId or null);
            action = requireString "${dnsPath}.requesterPolicies[*].action" (policy.action or null);
            sourcePrefixes = normalizeStringList "${dnsPath}.requesterPolicies[*]" policy "sourcePrefixes";
            namespaces = normalizeStringList "${dnsPath}.requesterPolicies[*]" policy "namespaces";
          in
          if requesterService == "" || relationId == "" || sourcePrefixes == [ ] || namespaces == [ ] then
            failInventory "${dnsPath}.requesterPolicies[*]" "requires requesterService, relationId, sourcePrefixes, and namespaces"
          else if action != "refuse_non_local" then
            failInventory "${dnsPath}.requesterPolicies[*].action" "must be refuse_non_local for a local-only requester"
          else
            { inherit requesterService relationId action sourcePrefixes namespaces; })
        (attrsList "${dnsPath}.requesterPolicies" (dns.requesterPolicies or [ ]));
      localOnlyPolicy =
        if dns ? localOnlyPolicy then
          let
            policy = requireAttrs "${dnsPath}.localOnlyPolicy" dns.localOnlyPolicy;
            providerService = requireString "${dnsPath}.localOnlyPolicy.providerService" (policy.providerService or null);
            relationId = requireString "${dnsPath}.localOnlyPolicy.relationId" (policy.relationId or null);
            namespaces = normalizeStringList "${dnsPath}.localOnlyPolicy" policy "namespaces";
            recursion = boolOrDefault "${dnsPath}.localOnlyPolicy.recursion" (policy.recursion or null) false;
            publicFallback = boolOrDefault "${dnsPath}.localOnlyPolicy.publicFallback" (policy.publicFallback or null) false;
            transitiveEgress = boolOrDefault "${dnsPath}.localOnlyPolicy.transitiveEgress" (policy.transitiveEgress or null) false;
            missAction = requireString "${dnsPath}.localOnlyPolicy.missAction" (policy.missAction or null);
          in
          if providerService == "" || relationId == "" || namespaces == [ ] || missAction != "refuse" then
            failInventory "${dnsPath}.localOnlyPolicy" "requires providerService, relationId, namespaces, and missAction=refuse"
          else if recursion || publicFallback || transitiveEgress then
            failInventory "${dnsPath}.localOnlyPolicy" "must not grant recursion, public fallback, or transitive egress"
          else
            {
              inherit
                providerService
                relationId
                namespaces
                recursion
                publicFallback
                transitiveEgress
                missAction
                ;
            }
        else
          null;
      reproducibilityWarnings = attrsList
        "${dnsPath}.reproducibilityWarnings"
        (dns.reproducibilityWarnings or [ ]);
      validationAuthority =
        if dns ? validationAuthority then
          validationAuthorityContract.normalize
            "${dnsPath}.validationAuthority"
            dns.validationAuthority
        else
          null;
      localZones = normalizeLocalZones dnsPath dns;
      localRecords = normalizeLocalRecords dnsPath dns;
      namespaceFallback = normalizeNamespaceFallback dnsPath dns;
      namespaceAuthority = normalizeNamespaceAuthority dnsPath dns;
      namespaceDiagnostics = normalizeNamespaceDiagnostics dnsPath dns;
      leaseNameScopes = normalizeLeaseNameScopes dnsPath dns namespaceAuthority namespaceFallback namespaceDiagnostics;
      recordPublications = normalizeRecordPublications dnsPath dns;
    in
    builtins.seq _forwarderConflict (
      builtins.seq _killSwitchNoPublicFallback (
        builtins.seq _killSwitchExplicitDeniedResolverCidrs ({ }
          // lib.optionalAttrs (implementation != null) { inherit implementation; }
          // lib.optionalAttrs (listen != [ ]) { inherit listen; }
          // lib.optionalAttrs (allowFrom != [ ]) { inherit allowFrom; }
          // lib.optionalAttrs (forwarders != [ ]) { inherit forwarders; }
          // lib.optionalAttrs (outgoingInterfaces != [ ]) { inherit outgoingInterfaces; }
          // lib.optionalAttrs (roles != { }) { inherit roles; }
          // lib.optionalAttrs (directEgressBlockedTenants != null) { inherit directEgressBlockedTenants; }
          // lib.optionalAttrs (upstreamResolvers != [ ]) { inherit upstreamResolvers; }
          // lib.optionalAttrs (recursionMode != null) { inherit recursionMode; }
          // lib.optionalAttrs (localForwardZones != [ ]) { inherit localForwardZones; }
          // lib.optionalAttrs (requesterPolicies != [ ]) { inherit requesterPolicies; }
          // lib.optionalAttrs (localOnlyPolicy != null) { inherit localOnlyPolicy; }
          // lib.optionalAttrs (dns ? reproducibilityWarnings) { inherit reproducibilityWarnings; }
          // lib.optionalAttrs (validationAuthority != null) { inherit validationAuthority; }
          // {
          inherit
            allowedUpstreamClasses
            deniedResolverCidrs
            killSwitch
            policyMatrix
            routeContracts
            routePreference
            ;
        }
          // lib.optionalAttrs (localZones != [ ]) { inherit localZones; }
          // lib.optionalAttrs (localRecords != [ ]) { inherit localRecords; }
          // lib.optionalAttrs (namespaceFallback != null) { inherit namespaceFallback; }
          // lib.optionalAttrs (namespaceAuthority != [ ]) { inherit namespaceAuthority; }
          // lib.optionalAttrs (leaseNameScopes != [ ]) { inherit leaseNameScopes; }
          // lib.optionalAttrs (recordPublications != [ ]) { inherit recordPublications; }
          // lib.optionalAttrs (namespaceDiagnostics != [ ]) { inherit namespaceDiagnostics; }
        )
      )
    );
}

