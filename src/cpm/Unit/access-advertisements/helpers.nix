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

  validateOptionalResolvedIPv6Match = entryPath: fieldName: value: expected: message:
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

  toInt = value: builtins.fromJSON value;

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

  defaultDHCP4Pool = entryPath: subnet:
    let
      match =
        if isNonEmptyString subnet then
          builtins.match "([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})/([0-9]{1,2})" subnet
        else
          null;
      hostCountByPrefix = {
        "24" = 256;
        "25" = 128;
        "26" = 64;
        "27" = 32;
        "28" = 16;
        "29" = 8;
        "30" = 4;
      };
    in
    if match == null then
      failForwarding
        "${entryPath}.pool"
        "cannot derive default DHCPv4 pool from tenant IPv4 prefix '${toString subnet}'; expected an IPv4 CIDR with prefix length /24 through /30"
    else if !(hasAttr (builtins.elemAt match 4) hostCountByPrefix) then
      failForwarding
        "${entryPath}.pool"
        "cannot derive default DHCPv4 pool from tenant IPv4 prefix '${toString subnet}'; expected prefix length /24 through /30"
    else
      let
        prefix = "${builtins.elemAt match 0}.${builtins.elemAt match 1}.${builtins.elemAt match 2}";
        hostBase = toInt (builtins.elemAt match 3);
        prefixLength = builtins.elemAt match 4;
        hostCount = hostCountByPrefix.${prefixLength};
        startHost = if prefixLength == "24" then hostBase + 100 else hostBase + 2;
        endHost = if prefixLength == "24" then hostBase + 200 else hostBase + hostCount - 2;
      in
      {
        start = "${prefix}.${toString startHost}";
        end = "${prefix}.${toString endHost}";
      };

in
{
  inherit
    attrsOrEmpty
    boolOr
    failForwarding
    failInventory
    defaultDHCP4Pool
    isNonEmptyString
    resolveAdvertisedIPv4Targets
    resolveAdvertisedIPv6Targets
    stripMask
    validateOptionalResolvedIPv4Match
    validateOptionalResolvedIPv6Match
    validateOptionalStringListMatch
    validateOptionalStringMatch
    ;
}
