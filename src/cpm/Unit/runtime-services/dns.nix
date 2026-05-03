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
      { }
      // lib.optionalAttrs (listen != [ ]) { inherit listen; }
      // lib.optionalAttrs (allowFrom != [ ]) { inherit allowFrom; }
      // lib.optionalAttrs (forwarders != [ ]) { inherit forwarders; }
      // lib.optionalAttrs (localZones != [ ]) { inherit localZones; }
      // lib.optionalAttrs (localRecords != [ ]) { inherit localRecords; }
    );
}
