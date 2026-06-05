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

  requireEnum = path: allowed: value:
    let
      rendered = requireString path value;
    in
    if builtins.elem rendered allowed then
      rendered
    else
      failInventory path "must be one of ${builtins.concatStringsSep ", " allowed}";

  orderedUniqueStrings =
    values:
    builtins.foldl'
      (
        acc: value:
        if isNonEmptyString value && !(builtins.elem value acc) then acc ++ [ value ] else acc
      )
      [ ]
      values;

  normalizeStringList = mdnsPath: mdns: fieldName:
    let
      path = "${mdnsPath}.${fieldName}";
      value = mdns.${fieldName} or [ ];
    in
    builtins.map
      (entry:
        let rendered = requireString "${path}[*]" entry;
        in if isNonEmptyString rendered then rendered else failInventory path "must not contain empty strings")
      (requireList path value);

  boolField = attrs: fieldName:
    if builtins.isBool (attrs.${fieldName} or null) then attrs.${fieldName} else false;

  normalizeAdvertisementData = relationshipPath: relationship:
    let
      path = "${relationshipPath}.allowedAdvertisementData";
      data = requireAttrs path (relationship.allowedAdvertisementData or null);
    in
    if builtins.attrNames data == [ ] then
      failInventory path "must describe at least one allowed advertisement datum"
    else
      data;

  normalizeRelationship = relationshipsPath: relationship:
    let
      relationshipAttrs = requireAttrs "${relationshipsPath}[*]" relationship;
    in
    lib.optionalAttrs (relationshipAttrs ? id) {
      id = requireString "${relationshipsPath}[*].id" relationshipAttrs.id;
    }
    // {
      requesterScope = requireString "${relationshipsPath}[*].requesterScope" (relationshipAttrs.requesterScope or null);
      responderScope = requireString "${relationshipsPath}[*].responderScope" (relationshipAttrs.responderScope or null);
      advertisedService = requireString "${relationshipsPath}[*].advertisedService" (relationshipAttrs.advertisedService or null);
      serviceType = requireString "${relationshipsPath}[*].serviceType" (relationshipAttrs.serviceType or null);
      discoveryProtocol =
        requireEnum
          "${relationshipsPath}[*].discoveryProtocol"
          [ "mdns" "bonjour-dns-sd" ]
          (relationshipAttrs.discoveryProtocol or null);
      direction =
        requireEnum
          "${relationshipsPath}[*].direction"
          [ "requester-to-responder" "bidirectional" ]
          (relationshipAttrs.direction or null);
      boundary =
        requireEnum
          "${relationshipsPath}[*].boundary"
          [ "same-scope" "relay" "proxy" "reflector" ]
          (relationshipAttrs.boundary or null);
      allowedAdvertisementData = normalizeAdvertisementData "${relationshipsPath}[*]" relationshipAttrs;
    };

  normalizeDiscoveryPolicy = mdnsPath: mdns:
    if mdns ? discoveryPolicy then
      let
        policyPath = "${mdnsPath}.discoveryPolicy";
        policy = requireAttrs policyPath mdns.discoveryPolicy;
        relationshipsPath = "${policyPath}.relationships";
        relationships = builtins.map (normalizeRelationship relationshipsPath) (requireList relationshipsPath (policy.relationships or null));
      in
      if relationships == [ ] then
        failInventory relationshipsPath "must contain at least one modeled discovery relationship"
      else
        {
          defaultDecision = "deny-unmodeled-visibility";
          inherit relationships;
        }
    else
      null;

in
{
  normalizeMdnsService = servicesPath: mdnsValue:
    let
      mdnsPath = "${servicesPath}.mdns";
      mdns = requireAttrs mdnsPath mdnsValue;
      reflector = if builtins.isBool (mdns.reflector or null) then mdns.reflector else false;
      allowInterfaces = normalizeStringList mdnsPath mdns "allowInterfaces";
      denyInterfaces = normalizeStringList mdnsPath mdns "denyInterfaces";
      discoveryPolicy = normalizeDiscoveryPolicy mdnsPath mdns;
      relationships = if discoveryPolicy == null then [ ] else discoveryPolicy.relationships;
      relationshipScopes =
        orderedUniqueStrings (
          builtins.concatLists (
            builtins.map
              (relationship: [ relationship.requesterScope relationship.responderScope ])
              relationships
          )
        );
      relationshipReflector =
        builtins.any
          (relationship: builtins.elem relationship.boundary [ "relay" "proxy" "reflector" ])
          relationships;
      publish =
        if mdns ? publish then
          let publishAttrs = requireAttrs "${mdnsPath}.publish" mdns.publish;
          in
          { }
          // lib.optionalAttrs (publishAttrs ? enable) { enable = boolField publishAttrs "enable"; }
          // lib.optionalAttrs (publishAttrs ? addresses) { addresses = boolField publishAttrs "addresses"; }
          // lib.optionalAttrs (publishAttrs ? userServices) { userServices = boolField publishAttrs "userServices"; }
          // lib.optionalAttrs (publishAttrs ? workstation) { workstation = boolField publishAttrs "workstation"; }
          // lib.optionalAttrs (publishAttrs ? domain) { domain = boolField publishAttrs "domain"; }
        else
          { };
      legacyAuthorityRequested = reflector || allowInterfaces != [ ] || denyInterfaces != [ ] || publish != { };
      _relationshipAuthority =
        if discoveryPolicy == null && legacyAuthorityRequested then
          failInventory mdnsPath "mDNS discovery authority requires discoveryPolicy.relationships; renderer-facing fields must not create discovery policy"
        else
          true;
      emittedReflector = reflector || relationshipReflector;
      emittedAllowInterfaces = if allowInterfaces != [ ] then allowInterfaces else relationshipScopes;
    in
    builtins.seq _relationshipAuthority (
      { reflector = emittedReflector; }
    // lib.optionalAttrs (emittedAllowInterfaces != [ ]) { allowInterfaces = emittedAllowInterfaces; }
    // lib.optionalAttrs (denyInterfaces != [ ]) { inherit denyInterfaces; }
    // lib.optionalAttrs (publish != { }) { inherit publish; }
    // lib.optionalAttrs (discoveryPolicy != null) {
      inherit discoveryPolicy;
      discoveryRelationships = relationships;
    }
    );
}
