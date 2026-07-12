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

  optionalStringList = path: value:
    if value == null then
      null
    else
      let
        entries = requireList path value;
        normalized =
          builtins.map
            (entry:
              let rendered = requireString "${path}[*]" entry;
              in if rendered == "" then failInventory path "must not contain empty strings" else rendered)
            entries;
      in
      if normalized == [ ] then failInventory path "must contain at least one entry" else normalized;

  requireEnum = path: allowed: value:
    let rendered = requireString path value;
    in
    if builtins.elem rendered allowed then
      rendered
    else
      failInventory path "must be one of ${builtins.concatStringsSep ", " allowed}";

  normalizeStatePredicate = path: behaviorPath: value: behaviorValue:
    if value == null && behaviorValue == null then
      null
    else if builtins.isAttrs value then
      {
        present = requireBool "${path}.present" (value.present or true);
        behavior = requireString "${path}.behavior" (value.behavior or behaviorValue);
        reason = optionalNonEmptyString "${path}.reason" (value.reason or null);
        source = requireString "${path}.source" (value.source or "inventory-realization");
      }
    else if builtins.isBool value then
      {
        present = value;
        behavior = requireString behaviorPath behaviorValue;
        source = "inventory-realization";
      }
    else if builtins.isString value then
      {
        present = true;
        behavior = requireString path value;
        source = "inventory-realization";
      }
    else if behaviorValue != null then
      {
        present = true;
        behavior = requireString behaviorPath behaviorValue;
        source = "inventory-realization";
      }
    else
      failInventory path "must be a boolean, string, or attribute set";

  normalizeFs880NamespaceFields = reservationPath: attrs:
    let
      namespace = optionalNonEmptyString "${reservationPath}.namespace" (attrs.namespace or null);
      namespaceOwner = optionalNonEmptyString "${reservationPath}.namespaceOwner" (attrs.namespaceOwner or null);
      requesterScope = optionalNonEmptyString "${reservationPath}.requesterScope" (attrs.requesterScope or null);
      requesterScopes = optionalStringList "${reservationPath}.requesterScopes" (attrs.requesterScopes or null);
      recordClass =
        if attrs ? recordClass then
          requireEnum "${reservationPath}.recordClass" [ "A" "AAAA" "dhcp4-lease-name" "dhcpv6-lease-name" ] attrs.recordClass
        else
          null;
      fallbackBehavior = optionalNonEmptyString "${reservationPath}.fallbackBehavior" (attrs.fallbackBehavior or null);
      deniedClasses =
        if attrs ? deniedClasses then
          optionalStringList "${reservationPath}.deniedClasses" attrs.deniedClasses
        else if attrs ? deniedRecordClasses then
          optionalStringList "${reservationPath}.deniedRecordClasses" attrs.deniedRecordClasses
        else
          null;
      conflictBehavior = optionalNonEmptyString "${reservationPath}.conflictBehavior" (attrs.conflictBehavior or null);
      conflict = normalizeStatePredicate "${reservationPath}.conflict" "${reservationPath}.conflictBehavior" (attrs.conflict or null) conflictBehavior;
      staleBehavior = optionalNonEmptyString "${reservationPath}.staleBehavior" (attrs.staleBehavior or null);
      stale = normalizeStatePredicate "${reservationPath}.stale" "${reservationPath}.staleBehavior" (attrs.stale or null) staleBehavior;
      revocationBehavior = optionalNonEmptyString "${reservationPath}.revocationBehavior" (attrs.revocationBehavior or null);
      revocation = normalizeStatePredicate "${reservationPath}.revocation" "${reservationPath}.revocationBehavior" (attrs.revocation or null) revocationBehavior;
    in
    { }
    // (if namespace != null then { inherit namespace; } else { })
    // (if namespaceOwner != null then { inherit namespaceOwner; } else { })
    // (if requesterScope != null then { inherit requesterScope; } else { })
    // (if requesterScopes != null then { inherit requesterScopes; } else { })
    // (if recordClass != null then { inherit recordClass; } else { })
    // (if fallbackBehavior != null then { inherit fallbackBehavior; } else { })
    // (if deniedClasses != null then { inherit deniedClasses; } else { })
    // (if conflictBehavior != null then { inherit conflictBehavior; } else { })
    // (if conflict != null then { inherit conflict; } else { })
    // (if staleBehavior != null then { inherit staleBehavior; } else { })
    // (if stale != null then { inherit stale; } else { })
    // (if revocationBehavior != null then { inherit revocationBehavior; } else { })
    // (if revocation != null then { inherit revocation; } else { });

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

  # Returns the scoped reservation identifier, or null when only the
  # path-level fallback is available (no meaningful identity).
  reservationRequirementScoped = reservationPath: attrs:
    if isNonEmptyString (attrs.id or null) then
      attrs.id
    else if isNonEmptyString (attrs.name or null) then
      attrs.name
    else if isNonEmptyString (attrs.hostname or null) then
      attrs.hostname
    else if isNonEmptyString (attrs.mac or null) then
      attrs.mac
    else
      null;

  requirementLabelFor = reservationPath: attrs:
    "reservation requirement '${reservationRequirement reservationPath attrs}'";

  # Diagnostic emission with required scope guard per SMS-030 FC2.
  # Rejects unscoped identity diagnostics before they reach downstream emission.
  failInventoryIdentityDiagnostic = reservationPath: attrs: message:
    let
      scoped = reservationRequirementScoped reservationPath attrs;
    in
    if scoped == null then
      failInventory reservationPath "diagnostic.reservation-identity-diagnostic-unscoped: missing identity diagnostic cannot name the affected reservation requirement at ${reservationPath}"
    else
      failInventory reservationPath message;

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

  findDuplicates = values:
    let
      indexList = builtins.genList (i: i) (builtins.length values);
      findIdx = val: builtins.filter (i: builtins.elemAt values i == val) indexList;
      seen = {};
      dups = builtins.foldl' (acc: i:
        let val = builtins.elemAt values i;
        in if builtins.hasAttr val acc then acc else
          let indices = findIdx val;
          in if builtins.length indices > 1 then acc // { ${val} = indices; } else acc // { ${val} = []; })
        {} indexList;
      dupVals = builtins.filter (v: builtins.length dups.${v} > 0) (builtins.attrNames dups);
    in
    if dupVals == [] then
      { ok = true; dupValues = []; dupIndices = []; }
    else
      { ok = false; dupValues = dupVals; dupIndices = builtins.head (map (v: dups.${v}) dupVals); };

  ensureUniqueValues = path: label: values:
    let result = findDuplicates values;
    in if result.ok then true else
      failInventory path "duplicate ${label} \"${builtins.head result.dupValues}\" across reservations [${toString (builtins.head result.dupIndices)}]";

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
          failInventoryIdentityDiagnostic reservationPath attrs
            "diagnostic.reservation-identity-source-missing: ${requirementLabel} requires accepted MAC source classification from ${classifierId}";
      accepted = requireBool "${classificationPath}.accepted" (classification.accepted or null);
      purpose = requireString "${classificationPath}.purpose" (classification.purpose or null);
      sourceClass = requireString "${classificationPath}.sourceClass" (classification.sourceClass or null);
      expectedPurpose = expectedPurposeFor familyName;
      source = optionalNonEmptyString "${classificationPath}.source" (classification.source or null);
      disposable = optionalBool "${classificationPath}.disposable" (classification.disposable or null);
      secretRef = optionalNonEmptyString "${classificationPath}.secretRef" (classification.secretRef or null);
      sourceFile = optionalNonEmptyString "${classificationPath}.sourceFile" (classification.sourceFile or null);
      _accepted =
        if accepted then
          true
        else
          failInventoryIdentityDiagnostic reservationPath attrs
            "diagnostic.reservation-identity-source-missing: ${requirementLabel} must be accepted by ${classifierId} before reservation identity consumption";
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
        else if source == "protected-inventory" || secretRef != null || sourceFile != null then
          true
        else
          failInventory classificationPath "${requirementLabel} requires protected inventory source='protected-inventory', secretRef, or sourceFile for non-public reservation identity";
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
          // (if sourceFile != null then { inherit sourceFile; } else { })
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
              identitySource = requireMacSourceClassification reservationPath attrs familyName;
              mac =
                if isNonEmptyString (attrs.mac or null) then
                  normalizeMac "${reservationPath}.mac" requirementLabel attrs.mac
                else
                  null;
              hasRuntimeSourceFile = isNonEmptyString (identitySource.sourceFile or null);
              scopedIdentity = reservationRequirementScoped reservationPath attrs;
              _identityMaterial =
                if mac != null then
                  true
                else if familyName == "ipv4" && (identitySource.sourceClass or "") == "protected" && hasRuntimeSourceFile then
                  true
                else
                  failInventoryIdentityDiagnostic reservationPath attrs
                    "diagnostic.reservation-identity-source-missing: ${requirementLabel} requires complete MAC address or protected runtime sourceFile";
              _scopedRuntimeIdentity =
                if mac != null || scopedIdentity != null then
                  true
                else
                  failInventoryIdentityDiagnostic reservationPath attrs
                    "diagnostic.reservation-identity-diagnostic-unscoped: runtime secret reservation source must name a reservation handle";
              hostOffset = reservationHostOffset reservationPath attrs familyName;
              cidr = ipam.allocOne {
                inherit family perNodePrefixLength;
                prefix = subnet;
                offset = hostOffset;
              };
              address = builtins.elemAt (builtins.split "/" cidr) 0;
            in
            builtins.seq _identityMaterial (
              builtins.seq _scopedRuntimeIdentity (
                {
                  id =
                    if isNonEmptyString (attrs.id or null) then
                      attrs.id
                    else if isNonEmptyString (attrs.name or null) then
                      attrs.name
                    else
                      if mac != null then mac else scopedIdentity;
                  inherit hostOffset address cidr identitySource;
                  source = "inventory-realization";
                }
                // (if mac != null then { inherit mac; } else { })
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
                // (if isNonEmptyString (attrs.duid or null) then { duid = attrs.duid; } else { })
                // (normalizeFs880NamespaceFields reservationPath attrs)
              )
            )
          )
          (builtins.length reservations);
      _identityMaterialForced = builtins.deepSeq rendered true;
      _uniqueMacs = ensureUniqueValues "${entryPath}.reservations" "MAC address" (map (reservation: reservation.mac) (builtins.filter (reservation: isNonEmptyString (reservation.mac or null)) rendered));
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
    builtins.seq _identityMaterialForced (builtins.seq _uniqueMacs (builtins.seq _uniqueOffsets (builtins.seq _uniqueIds rendered)));
in
{
  inherit resolveReservations;
}
