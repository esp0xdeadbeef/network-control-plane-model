{ helpers
, ipam
, advertisementHelpers
, binderSourceAudit
,
}:

let
  inherit (helpers) requireAttrs requireList requireString;
  inherit (advertisementHelpers) failInventory isNonEmptyString;

  classifierId = "FS-720-HDS-010-SDS-030-SMS-010";

  requireInt = path: value:
    if builtins.isInt value then value else failInventory path "must be an integer";

  hexDigitValues = {
    "0" = 0;
    "1" = 1;
    "2" = 2;
    "3" = 3;
    "4" = 4;
    "5" = 5;
    "6" = 6;
    "7" = 7;
    "8" = 8;
    "9" = 9;
    a = 10;
    A = 10;
    b = 11;
    B = 11;
    c = 12;
    C = 12;
    d = 13;
    D = 13;
    e = 14;
    E = 14;
    f = 15;
    F = 15;
  };

  parseHexOffset = path: value:
    let
      raw =
        if builtins.isInt value then
          toString value
        else if builtins.isString value then
          value
        else
          failInventory path "must be a hexadecimal integer offset";
      len = builtins.stringLength raw;
      step = idx: acc:
        if idx == len then
          acc
        else
          let
            digit = builtins.substring idx 1 raw;
          in
          if builtins.hasAttr digit hexDigitValues then
            step (idx + 1) (acc * 16 + hexDigitValues.${digit})
          else
            failInventory path "must be a hexadecimal integer offset";
    in
    if len == 0 then
      failInventory path "must be a hexadecimal integer offset"
    else
      step 0 0;

  requireBool = path: value:
    if builtins.isBool value then value else failInventory path "must be a boolean";

  optionalString = path: value:
    if value == null then null else requireString path value;

  optionalBool = path: value:
    if value == null then null else requireBool path value;

  optionalNonEmptyString = path: value:
    if value == null then
      null
    else
      let
        stringValue = requireString path value;
      in
      if stringValue == "" then
        failInventory path "must not be empty"
      else
        stringValue;

  reservationRequirement = reservationPath: attrs:
    if isNonEmptyString (attrs.id or null) then
      attrs.id
    else if isNonEmptyString (attrs.name or null) then
      attrs.name
    else if isNonEmptyString (attrs.hostname or null) then
      attrs.hostname
    else if isNonEmptyString (attrs.mac or null) then
      attrs.mac
    else
      reservationPath;

  requirementLabelFor = reservationPath: attrs:
    "reservation requirement '${reservationRequirement reservationPath attrs}'";

  normalizeMac = path: label: value:
    let
      mac =
        if isNonEmptyString value then
          value
        else
          failInventory path "${label} requires complete MAC address";
      normalized = builtins.replaceStrings [ "-" ] [ ":" ] mac;
    in
    if builtins.match "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}" normalized != null then
      normalized
    else
      failInventory path "${label} requires complete MAC address";

  duplicate = values:
    let
      names = builtins.attrNames (builtins.listToAttrs (map (value: { name = value; value = true; }) values));
    in
    builtins.length names != builtins.length values;

  ensureUniqueValues = path: label: values:
    if duplicate values then failInventory path "duplicate ${label} in the same network" else true;

  ensureUniqueReservationIds = path: values:
    if duplicate values then failInventory path "duplicate reservation id in the same service target" else true;

  reservationHostOffset = reservationPath: attrs: familyName:
    let
      familyAttrs = requireAttrs "${reservationPath}.${familyName}" (attrs.${familyName} or null);
    in
    if familyName == "ipv6" then
      parseHexOffset "${reservationPath}.${familyName}.hostOffset" (familyAttrs.hostOffset or null)
    else
      requireInt "${reservationPath}.${familyName}.hostOffset" (familyAttrs.hostOffset or null);

  expectedPurposeFor = familyName:
    if familyName == "ipv6" then "dhcpv6-reservation" else "static-dhcp-reservation";

  requireMacSourceClassification = reservationPath: attrs: familyName:
    let
      requirementLabel = requirementLabelFor reservationPath attrs;
      classificationPath = "${reservationPath}.macSource";
      classification =
        if builtins.isAttrs (attrs.macSource or null) then
          attrs.macSource
        else
          failInventory classificationPath "${requirementLabel} requires accepted MAC source classification from ${classifierId}";
      accepted = requireBool "${classificationPath}.accepted" (classification.accepted or null);
      purpose = requireString "${classificationPath}.purpose" (classification.purpose or null);
      sourceClass = requireString "${classificationPath}.sourceClass" (classification.sourceClass or null);
      expectedPurpose = expectedPurposeFor familyName;
      source = optionalNonEmptyString "${classificationPath}.source" (classification.source or null);
      disposable = optionalBool "${classificationPath}.disposable" (classification.disposable or null);
      secretRef = optionalNonEmptyString "${classificationPath}.secretRef" (classification.secretRef or null);
      _accepted =
        if accepted then
          true
        else
          failInventory classificationPath "${requirementLabel} must be accepted by ${classifierId} before reservation identity consumption";
      _purpose =
        if purpose == expectedPurpose then
          true
        else
          failInventory "${classificationPath}.purpose" "${requirementLabel} must use purpose '${expectedPurpose}' for ${familyName} reservation identity consumption";
      _protectedIdentityBoundary =
        if sourceClass != "protected" then
          true
        else if source == "public-inventory" then
          failInventory classificationPath "${requirementLabel} must not emit protected reservation identity material as public inventory"
        else if source == "protected-inventory" || secretRef != null then
          true
        else
          failInventory classificationPath "${requirementLabel} requires protected inventory source='protected-inventory' or secretRef for non-public reservation identity";
    in
    builtins.seq _accepted (
      builtins.seq _purpose (
        builtins.seq _protectedIdentityBoundary (
          {
            classifier = classifierId;
            inherit accepted purpose sourceClass;
          }
          // (if source != null then { inherit source; } else { })
          // (if disposable != null then { inherit disposable; } else { })
          // (if secretRef != null then { inherit secretRef; } else { })
        )
      )
    );

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
              requirementLabel = requirementLabelFor reservationPath attrs;
              mac = normalizeMac "${reservationPath}.mac" requirementLabel (attrs.mac or null);
              hostOffset = reservationHostOffset reservationPath attrs familyName;
              identitySource = requireMacSourceClassification reservationPath attrs familyName;
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
              inherit mac hostOffset address cidr identitySource;
              source = "inventory-realization";
            }
            // binderSourceAudit.make {
              path = reservationPath;
              field =
                "advertisements.${if familyName == "ipv4" then "dhcp4" else "dhcpv6"}.reservations";
              binderSourceClass =
                if (identitySource.sourceClass or "") == "protected" then
                  "protected-inventory"
                else
                  "public-inventory";
              binderSourcePath = reservationPath;
              upstreamBehaviorRef = entryPath;
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
      _uniqueIds =
        ensureUniqueReservationIds
          "${entryPath}.reservations"
          (map (reservation: reservation.id) rendered);
    in
    builtins.seq _uniqueMacs (builtins.seq _uniqueOffsets (builtins.seq _uniqueIds rendered));
in
{
  inherit resolveReservations;
}
