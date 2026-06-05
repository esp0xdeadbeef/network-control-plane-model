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

  normalizeLocalZones = dnsPath: dns:
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

  normalizeLocalRecords = dnsPath: dns:
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
          _hasData =
            if a == [ ] && aaaa == [ ] then
              failInventory recordPath "must define at least one of 'a' or 'aaaa'"
            else
              true;
        in
        builtins.seq _hasData ({
          inherit name;
        } // lib.optionalAttrs (a != [ ]) {
          inherit a;
        } // lib.optionalAttrs (aaaa != [ ]) {
          inherit aaaa;
        }))
      (requireList path value);

in
{
  inherit
    normalizeLocalRecords
    normalizeLocalZones
    ;
}
