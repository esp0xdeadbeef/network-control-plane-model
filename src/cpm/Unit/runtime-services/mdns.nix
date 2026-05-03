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

in
{
  normalizeMdnsService = servicesPath: mdnsValue:
    let
      mdnsPath = "${servicesPath}.mdns";
      mdns = requireAttrs mdnsPath mdnsValue;
      reflector = if builtins.isBool (mdns.reflector or null) then mdns.reflector else false;
      allowInterfaces = normalizeStringList mdnsPath mdns "allowInterfaces";
      denyInterfaces = normalizeStringList mdnsPath mdns "denyInterfaces";
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
    in
    { inherit reflector; }
    // lib.optionalAttrs (allowInterfaces != [ ]) { inherit allowInterfaces; }
    // lib.optionalAttrs (denyInterfaces != [ ]) { inherit denyInterfaces; }
    // lib.optionalAttrs (publish != { }) { inherit publish; };
}
