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
