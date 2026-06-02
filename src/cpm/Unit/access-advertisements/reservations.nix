{ helpers
, ipam
, advertisementHelpers
,
}:

let
  inherit (helpers) requireAttrs requireList requireString;
  inherit (advertisementHelpers) failInventory isNonEmptyString;

  requireInt = path: value:
    if builtins.isInt value then value else failInventory path "must be an integer";

  normalizeMac = path: value:
    let
      mac = requireString path value;
      normalized = builtins.replaceStrings [ "-" ] [ ":" ] mac;
    in
    if builtins.match "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}" normalized != null then
      normalized
    else
      failInventory path "must be a MAC address";

  duplicate = values:
    let
      names = builtins.attrNames (builtins.listToAttrs (map (value: { name = value; value = true; }) values));
    in
    builtins.length names != builtins.length values;

  ensureUniqueValues = path: label: values:
    if duplicate values then failInventory path "duplicate ${label} in the same network" else true;

  reservationHostOffset = reservationPath: attrs: familyName:
    let
      familyAttrs = requireAttrs "${reservationPath}.${familyName}" (attrs.${familyName} or null);
    in
    requireInt "${reservationPath}.${familyName}.hostOffset" (familyAttrs.hostOffset or null);

  resolveReservations =
    family: familyName: perNodePrefixLength: entryPath: interfaceName: subnet: rawReservations:
    let
      reservations = if rawReservations == null then [ ] else requireList "${entryPath}.reservations" rawReservations;
      rendered =
        builtins.genList
          (idx:
            let
              reservationPath = "${entryPath}.reservations[${toString idx}]";
              attrs = requireAttrs reservationPath (builtins.elemAt reservations idx);
              mac = normalizeMac "${reservationPath}.mac" (attrs.mac or null);
              hostOffset = reservationHostOffset reservationPath attrs familyName;
              cidr = ipam.allocOne {
                inherit family perNodePrefixLength;
                prefix = subnet;
                offset = hostOffset;
              };
              address = builtins.elemAt (builtins.split "/" cidr) 0;
            in
            {
              id =
                if isNonEmptyString (attrs.id or null) then
                  attrs.id
                else if isNonEmptyString (attrs.name or null) then
                  attrs.name
                else
                  mac;
              inherit mac hostOffset address cidr;
              source = "inventory-realization";
            }
            // (if isNonEmptyString (attrs.hostname or null) then { hostname = attrs.hostname; } else { })
            // (if isNonEmptyString (attrs.duid or null) then { duid = attrs.duid; } else { }))
          (builtins.length reservations);
      _uniqueMacs = ensureUniqueValues "${entryPath}.reservations" "MAC address" (map (reservation: reservation.mac) rendered);
      _uniqueOffsets =
        ensureUniqueValues
          "${entryPath}.reservations"
          "${familyName}.hostOffset"
          (map (reservation: toString reservation.hostOffset) rendered);
    in
    builtins.seq _uniqueMacs (builtins.seq _uniqueOffsets rendered);
in
{
  inherit resolveReservations;
}
