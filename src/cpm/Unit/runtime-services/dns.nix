{
  lib,
  helpers,
  failInventory,
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

  publicResolverCidrs = [
    "1.1.1.1/32"
    "1.0.0.1/32"
    "8.8.8.8/32"
    "8.8.4.4/32"
    "9.9.9.9/32"
    "2606:4700:4700::1111/128"
    "2606:4700:4700::1001/128"
    "2001:4860:4860::8888/128"
    "2001:4860:4860::8844/128"
    "2620:fe::fe/128"
  ];

  defaultRoutePreference = [
    "local-access"
    "overlay-core"
    "service-dns"
    "explicit-egress-default"
  ];

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
          normalizeStringList dnsPath dns "forwarders"
        else if dns ? upstreams then
          normalizeStringList dnsPath dns "upstreams"
        else
          [ ];
      _forwarderConflict =
        if dns ? forwarders && dns ? upstreams then
          failInventory dnsPath "must define only one of 'forwarders' or 'upstreams'"
        else
          true;
      killSwitchInput = requireAttrs "${dnsPath}.killSwitch" (dns.killSwitch or { });
      killSwitch = {
        enabled = boolOrDefault "${dnsPath}.killSwitch.enabled" (killSwitchInput.enabled or null) true;
        blockPublicResolvers =
          boolOrDefault "${dnsPath}.killSwitch.blockPublicResolvers"
            (killSwitchInput.blockPublicResolvers or null)
            true;
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
        if dns ? routePreference then normalizeStringList dnsPath dns "routePreference" else defaultRoutePreference;
      allowedUpstreamClasses =
        if dns ? allowedUpstreamClasses then normalizeStringList dnsPath dns "allowedUpstreamClasses" else [ "local-access" ];
      deniedResolverCidrs =
        if dns ? deniedResolverCidrs then
          normalizeStringList dnsPath dns "deniedResolverCidrs"
        else
          publicResolverCidrs;
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
    in
    builtins.seq _forwarderConflict (
      builtins.seq _killSwitchNoPublicFallback (
      { }
      // lib.optionalAttrs (listen != [ ]) { inherit listen; }
      // lib.optionalAttrs (allowFrom != [ ]) { inherit allowFrom; }
      // lib.optionalAttrs (forwarders != [ ]) { inherit forwarders; }
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
      )
    );
}
