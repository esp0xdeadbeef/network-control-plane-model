{ helpers, common }:

let
  inherit (helpers) forceAll hasAttr isNonEmptyString requireAttrs requireList requireString requireStringList sortedNames;
  inherit (common) attrsOrEmpty collectNamesFromList collectStringValues failForwarding makeStringSet listOrEmpty;
in
{
  validate = sitePath: siteAttrs:
    let
      communicationContract =
        if siteAttrs ? communicationContract then requireAttrs "${sitePath}.communicationContract" siteAttrs.communicationContract else null;
    in
    if communicationContract == null then
      true
    else
      let
        relationPathRoot =
          if builtins.isList (communicationContract.relations or null) then "${sitePath}.communicationContract.relations" else "${sitePath}.communicationContract.allowedRelations";
        allowedRelations =
          if builtins.isList (communicationContract.relations or null) then
            requireList relationPathRoot communicationContract.relations
          else
            requireList relationPathRoot (communicationContract.allowedRelations or null);
        policy =
          if builtins.isAttrs (siteAttrs.policy or null) then requireAttrs "${sitePath}.policy" siteAttrs.policy else failForwarding "${sitePath}.policy.interfaceTags" "site.policy.interfaceTags is required";
        interfaceTags =
          if builtins.isAttrs (policy.interfaceTags or null) then policy.interfaceTags else failForwarding "${sitePath}.policy.interfaceTags" "site.policy.interfaceTags is required";
        domains = requireAttrs "${sitePath}.domains" (siteAttrs.domains or null);
        tenantSet = makeStringSet (collectNamesFromList (requireList "${sitePath}.domains.tenants" (domains.tenants or null)));
        uplinkNames = requireStringList "${sitePath}.uplinkNames" (siteAttrs.uplinkNames or null);
        externalSet = makeStringSet (uplinkNames ++ collectNamesFromList (requireList "${sitePath}.domains.externals" (domains.externals or null)));
        serviceSet =
          makeStringSet (
            collectNamesFromList ((listOrEmpty (communicationContract.services or null)) ++ (listOrEmpty (siteAttrs.services or null)))
          );
        explicitTagSet = makeStringSet (collectStringValues interfaceTags);
        useExplicitTagMapping = sortedNames explicitTagSet != [ ];
        validateExplicitTag = relationPath: tag:
          if hasAttr tag explicitTagSet then true else failForwarding relationPath "communicationContract references tag '${tag}' with no explicit site.policy.interfaceTags mapping";
        validateNamedReference = kind: knownSet: relationPath: endpointPath: name:
          if useExplicitTagMapping then
            validateExplicitTag relationPath name
          else if hasAttr name knownSet then
            true
          else
            failForwarding endpointPath "communicationContract references unknown ${kind} '${name}'";
        validateRelationEndpoint = relationIndex: relation: endpointName:
          let
            relationPath = "${relationPathRoot}[${toString relationIndex}]";
            endpointPath = "${relationPath}.${endpointName}";
            endpointRaw = relation.${endpointName} or null;
            endpoint = attrsOrEmpty endpointRaw;
            kind = endpoint.kind or null;
          in
          if endpointRaw == "any" || !builtins.isAttrs endpointRaw then
            true
          else if kind == "tenant" then
            validateNamedReference "tenant" tenantSet relationPath "${endpointPath}.name" (requireString "${endpointPath}.name" (endpoint.name or null))
          else if kind == "service" then
            validateNamedReference "service" serviceSet relationPath "${endpointPath}.name" (requireString "${endpointPath}.name" (endpoint.name or null))
          else if kind == "external" then
            if isNonEmptyString (endpoint.name or null) then
              validateNamedReference "external" externalSet relationPath "${endpointPath}.name" endpoint.name
            else if builtins.isList (endpoint.uplinks or null) then
              forceAll (map (uplinkName: validateNamedReference "external" externalSet relationPath "${endpointPath}.uplinks" uplinkName) (requireStringList "${endpointPath}.uplinks" endpoint.uplinks))
            else
              true
          else if kind == "tenant-set" then
            forceAll (map (tenantName: validateNamedReference "tenant" tenantSet relationPath "${endpointPath}.members" tenantName) (requireStringList "${endpointPath}.members" (endpoint.members or null)))
          else
            true;
        validateReturnBehavior = relationIndex: relation:
          let
            relationPath = "${relationPathRoot}[${toString relationIndex}]";
            relationId = if isNonEmptyString (relation.id or null) then relation.id else "<unknown>";
            topLevelPresent = relation ? returnBehavior;
            topLevel = relation.returnBehavior or null;
            publicIngressAuthority = relation.publicIngressTupleAuthority or null;
            nestedPresent =
              builtins.isAttrs publicIngressAuthority && publicIngressAuthority ? returnBehavior;
            nested = if nestedPresent then publicIngressAuthority.returnBehavior else null;
            validReturnBehavior = value: isNonEmptyString value;
            fail = message:
              failForwarding relationPath "allow relation '${relationId}' ${message}";
          in
          if (relation.action or "allow") != "allow" then
            true
          else if topLevelPresent && !validReturnBehavior topLevel then
            fail "has an invalid top-level returnBehavior"
          else if nestedPresent && !validReturnBehavior nested then
            fail "has an invalid publicIngressTupleAuthority.returnBehavior"
          else if topLevelPresent && nestedPresent && topLevel != nested then
            fail "has conflicting returnBehavior values '${topLevel}' and '${nested}'"
          else if topLevelPresent || nestedPresent then
            true
          else
            fail "is missing required returnBehavior";
      in
      forceAll (
        builtins.genList
          (idx:
            let relation = attrsOrEmpty (builtins.elemAt allowedRelations idx);
            in
            # FS-180-HDS-010-SDS-010-SMS-010: an incomplete or conflicting
            # allow tuple must fail before policy evaluation.
            builtins.seq
              (validateReturnBehavior idx relation)
              (builtins.seq (validateRelationEndpoint idx relation "from") (validateRelationEndpoint idx relation "to")))
          (builtins.length allowedRelations)
      );
}
