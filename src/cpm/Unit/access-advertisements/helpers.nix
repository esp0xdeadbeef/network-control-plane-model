{ helpers, endpointInventoryIndex }:

let
  inherit (helpers) hasAttr requireString requireStringList;

  attrsOrEmpty = value:
    if builtins.isAttrs value then
      value
    else
      { };

  boolOr = fallback: value:
    if builtins.isBool value then
      value
    else
      fallback;

  isNonEmptyString = value:
    builtins.isString value && value != "";

  isIPv4Literal = value:
    builtins.isString value
    && builtins.match "([0-9]{1,3}\\.){3}[0-9]{1,3}" value != null;

  isIPv6Literal = value:
    builtins.isString value
    && builtins.match ".*:.*" value != null
    && builtins.match "[0-9A-Fa-f:.]+" value != null;

  stripMask = addr:
    if isNonEmptyString addr then
      builtins.elemAt (builtins.split "/" addr) 0
    else
      null;

  failInventory = path: message:
    throw "inventory.nix update required: ${path}: ${message}";

  failForwarding = path: message:
    throw "forwarding-model update required: ${path}: ${message}";

  validateOptionalStringMatch = entryPath: fieldName: value: expected: message:
    if value == null then
      true
    else
      let
        rendered = requireString "${entryPath}.${fieldName}" value;
      in
      if rendered == expected then true else failInventory "${entryPath}.${fieldName}" message;

  validateOptionalResolvedIPv4Match = entryPath: fieldName: value: expected: message:
    if value == null then
      true
    else
      let
        rendered = requireString "${entryPath}.${fieldName}" value;
        resolved = if rendered == "router-self" then expected else rendered;
      in
      if resolved == expected then true else failInventory "${entryPath}.${fieldName}" message;

  validateOptionalStringListMatch = entryPath: fieldName: value: expected: message:
    if value == null then
      true
    else
      let
        rendered = requireStringList "${entryPath}.${fieldName}" value;
      in
      if rendered == expected then true else failInventory "${entryPath}.${fieldName}" message;

  resolveAdvertisedIPv4Target = entryPath: fieldName: routerAddress: index: rawValue:
    let
      address = requireString "${entryPath}.${fieldName}[${toString index}]" rawValue;
    in
    if address == "router-self" then
      routerAddress
    else if address == routerAddress || hasAttr address endpointInventoryIndex.byIPv4 || isIPv4Literal address then
      address
    else
      failInventory
        "${entryPath}.${fieldName}[${toString index}]"
        "must resolve to an explicit router interface address, 'router-self', inventory.endpoints IPv4 address, or explicit IPv4 literal; '${address}' is not explicitly defined";

  resolveAdvertisedIPv6Target = entryPath: fieldName: routerAddress: index: rawValue:
    let
      address = requireString "${entryPath}.${fieldName}[${toString index}]" rawValue;
    in
    if address == "router-self" then
      routerAddress
    else if address == routerAddress || hasAttr address endpointInventoryIndex.byIPv6 || isIPv6Literal address then
      address
    else
      failInventory
        "${entryPath}.${fieldName}[${toString index}]"
        "must resolve to an explicit router interface address, 'router-self', inventory.endpoints IPv6 address, or explicit IPv6 literal; '${address}' is not explicitly defined";

  resolveAdvertisedIPv4Targets = entryPath: fieldName: routerAddress: rawValue:
    let
      configured =
        if rawValue == null then [ "router-self" ] else requireStringList "${entryPath}.${fieldName}" rawValue;
    in
    builtins.genList
      (idx: resolveAdvertisedIPv4Target entryPath fieldName routerAddress idx (builtins.elemAt configured idx))
      (builtins.length configured);

  resolveAdvertisedIPv6Targets = entryPath: fieldName: routerAddress: rawValue:
    let
      configured =
        if rawValue == null then [ "router-self" ] else requireStringList "${entryPath}.${fieldName}" rawValue;
    in
    builtins.genList
      (idx: resolveAdvertisedIPv6Target entryPath fieldName routerAddress idx (builtins.elemAt configured idx))
      (builtins.length configured);

in
{
  inherit
    attrsOrEmpty
    boolOr
    failForwarding
    failInventory
    isNonEmptyString
    resolveAdvertisedIPv4Targets
    resolveAdvertisedIPv6Targets
    stripMask
    validateOptionalResolvedIPv4Match
    validateOptionalStringListMatch
    validateOptionalStringMatch
    ;
}
