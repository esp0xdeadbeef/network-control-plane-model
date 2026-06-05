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

  normalizeNamespaceFallback = dnsPath: dns:
    let
      path = "${dnsPath}.namespaceFallback";
      value = dns.namespaceFallback or null;
    in
    if value == null then
      null
    else
      let
        cfg = requireAttrs path value;
        decisionsPath = "${path}.decisions";
        defaultPublicRecursionFallback =
          boolOrDefault "${path}.defaultPublicRecursionFallback"
            (cfg.defaultPublicRecursionFallback or null)
            false;
        normalizeDecision = decision:
          let
            decisionPath = "${decisionsPath}[*]";
            attrs = requireAttrs decisionPath decision;
            requesterScope = requireString "${decisionPath}.requesterScope" (attrs.requesterScope or null);
            namespace = requireString "${decisionPath}.namespace" (attrs.namespace or null);
            failedAnswerReason = requireString "${decisionPath}.failedAnswerReason" (attrs.failedAnswerReason or null);
            action = requireString "${decisionPath}.action" (attrs.action or null);
            leakPrevention = requireString "${decisionPath}.leakPrevention" (attrs.leakPrevention or null);
            allowedRecordClasses = normalizeStringList decisionPath attrs "allowedRecordClasses";
            deniedRecordClasses = normalizeStringList decisionPath attrs "deniedRecordClasses";
            publicRecursionFallback =
              boolOrDefault "${decisionPath}.publicRecursionFallback"
                (attrs.publicRecursionFallback or null)
                false;
            fallbackTarget =
              if attrs ? fallbackTarget then
                requireString "${decisionPath}.fallbackTarget" attrs.fallbackTarget
              else
                null;
            _validAction =
              if !(builtins.elem action [ "answer" "fallback" "block" "deny" ]) then
                failInventory "${decisionPath}.action" "must be one of answer, fallback, block, or deny"
              else
                true;
            _fallbackTargetRequired =
              if action == "fallback" && fallbackTarget == null then
                failInventory "${decisionPath}.fallbackTarget" "is required when namespace fallback action is 'fallback'"
              else
                true;
            _allowedClassesRequired =
              if allowedRecordClasses == [ ] then
                failInventory "${decisionPath}.allowedRecordClasses" "must contain at least one record class"
              else
                true;
            _deniedClassesRequired =
              if deniedRecordClasses == [ ] then
                failInventory "${decisionPath}.deniedRecordClasses" "must contain at least one denied record class"
              else
                true;
            _publicFallbackExplicit =
              if publicRecursionFallback && (action != "fallback" || fallbackTarget == null) then
                failInventory
                  "${decisionPath}.publicRecursionFallback"
                  "requires explicit fallback action and fallbackTarget"
              else
                true;
            _deniedRequesterScopeNoFallback =
              if failedAnswerReason == "denied-requester-scope" && (publicRecursionFallback || action == "fallback" || fallbackTarget != null) then
                failInventory
                  "${decisionPath}.publicRecursionFallback"
                  "must be false for denied requester scope; cross-tenant DNS denial cannot inherit public recursion fallback"
              else
                true;
          in
          builtins.seq _validAction (
            builtins.seq _fallbackTargetRequired (
              builtins.seq _allowedClassesRequired (
                builtins.seq _deniedClassesRequired (
                  builtins.seq _publicFallbackExplicit (
                    builtins.seq _deniedRequesterScopeNoFallback ({
                      inherit
                        action
                        allowedRecordClasses
                        deniedRecordClasses
                        failedAnswerReason
                        leakPrevention
                        namespace
                        publicRecursionFallback
                        requesterScope
                        ;
                    } // lib.optionalAttrs (fallbackTarget != null) { inherit fallbackTarget; })
                  )
                )
              )
            )
          );
        decisions = builtins.map normalizeDecision (requireList decisionsPath (cfg.decisions or null));
        _hasDecision =
          if decisions == [ ] then
            failInventory decisionsPath "must contain at least one namespace miss or fallback decision"
          else
            true;
      in
      builtins.seq _hasDecision {
        inherit defaultPublicRecursionFallback decisions;
      };

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
      localZones =
        let
          path = "${dnsPath}.localZones";
          value = dns.localZones or [ ];
        in
        builtins.map
          (entry:
            let
              zone = requireAttrs "${path}[*]" entry;
              name = requireString "${path}[*].name" (zone.name or null);
              zoneType = if isNonEmptyString (zone.type or null) then zone.type else "static";
            in
            if isNonEmptyString name then { inherit name; type = zoneType; } else failInventory "${path}[*].name" "must not be empty")
          (requireList path value);
      localRecords =
        let
          path = "${dnsPath}.localRecords";
          value = dns.localRecords or [ ];
        in
        builtins.map
          (record:
            let
              recordPath = "${path}[*]";
              attrs = requireAttrs recordPath record;
              name = requireString "${recordPath}.name" (attrs.name or null);
              normalizeRecordValues =
                fieldName:
                builtins.map
                  (entry:
                  let rendered = requireString "${recordPath}.${fieldName}[*]" entry;
                  in if isNonEmptyString rendered then rendered else failInventory "${recordPath}.${fieldName}" "must not contain empty strings")
                  (requireList "${recordPath}.${fieldName}" (attrs.${fieldName} or [ ]));
              a = normalizeRecordValues "a";
              aaaa = normalizeRecordValues "aaaa";
              _hasData = if a == [ ] && aaaa == [ ] then failInventory recordPath "must define at least one of 'a' or 'aaaa'" else true;
            in
            builtins.seq _hasData ({ inherit name; } // lib.optionalAttrs (a != [ ]) { inherit a; } // lib.optionalAttrs (aaaa != [ ]) { inherit aaaa; }))
          (requireList path value);
      namespaceFallback = normalizeNamespaceFallback dnsPath dns;
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
        )
      )
    );
}
