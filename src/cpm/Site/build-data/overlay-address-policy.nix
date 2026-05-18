{
  common,
  ipam,
  lib,
}:

let
  inherit (common) attrsOrEmpty failInventory listOrEmpty;

  stripMask = value:
    if builtins.isString value then builtins.elemAt (lib.splitString "/" value) 0 else null;

  pow2 = n: builtins.foldl' (acc: _: acc * 2) 1 (builtins.genList (i: i) n);

  cidrContainsIPv6 =
    cidr: address:
    let
      parsedCidr = ipam.splitCIDR cidr;
      cidrAddr = if parsedCidr == null then null else ipam.parseIPv6 parsedCidr.addr;
      addr = ipam.parseIPv6 address;
    in
    if parsedCidr == null || cidrAddr == null || addr == null then
      false
    else
      let
        fullHextets = builtins.div parsedCidr.prefixLen 16;
        partialBits = lib.mod parsedCidr.prefixLen 16;
        fullMatch =
          builtins.genList (idx: builtins.elemAt addr idx) fullHextets
          == builtins.genList (idx: builtins.elemAt cidrAddr idx) fullHextets;
        partialMatch =
          if partialBits == 0 then
            true
          else
            let
              block = pow2 (16 - partialBits);
              idx = fullHextets;
            in
            builtins.div (builtins.elemAt addr idx) block == builtins.div (builtins.elemAt cidrAddr idx) block;
      in
      fullMatch && partialMatch;

  cidrContains =
    family: cidr: address:
    if family == 4 then common.cidrContainsAddress cidr address else cidrContainsIPv6 cidr address;

  sourceClassFor = family: nodeCfg: nodeIpamCfg:
    if family == 4 then
      nodeCfg.addr4SourceClass or (nodeIpamCfg.addr4SourceClass or null)
    else
      nodeCfg.addr6SourceClass or (nodeIpamCfg.addr6SourceClass or null);

  sourceSecretFor = family: nodeCfg: nodeIpamCfg:
    let
      field = if family == 4 then "addr4SecretName" else "addr6SecretName";
    in
    nodeCfg.${field} or (nodeIpamCfg.${field} or null);

  validateSource =
    {
      address,
      allowedClasses,
      family,
      nodeCfg,
      nodeIpamCfg,
      overlayPath,
      required,
    }:
    let
      sourceClass = sourceClassFor family nodeCfg nodeIpamCfg;
    in
    if address == null || !required then
      { }
    else if !(builtins.isString sourceClass && sourceClass != "") then
      failInventory "${overlayPath}.ipam.nodes.<node>.addr${toString family}SourceClass" "source class is required by overlay addressSourcePolicy"
    else if allowedClasses != [ ] && !(builtins.elem sourceClass allowedClasses) then
      failInventory "${overlayPath}.ipam.nodes.<node>.addr${toString family}SourceClass" "source class '${sourceClass}' is not allowed by overlay addressSourcePolicy"
    else
      {
        "addr${toString family}Source" =
          {
            class = sourceClass;
          }
          // (
            let secretName = sourceSecretFor family nodeCfg nodeIpamCfg;
            in if builtins.isString secretName && secretName != "" then { inherit secretName; } else { }
          );
      };
in
{
  validateAddress =
    {
      address,
      family,
      nodeName,
      overlayPath,
      prefix,
    }:
    if address == null || prefix == null then
      true
    else if cidrContains family prefix (stripMask address) then
      true
    else
      failInventory "${overlayPath}.ipam.nodes.${nodeName}.addr${toString family}" "address '${address}' is outside overlay pool '${prefix}'";

  sourceMetadata =
    {
      address,
      addressSourcePolicy,
      family,
      nodeCfg,
      nodeIpamCfg,
      overlayPath,
    }:
    validateSource {
      inherit address family nodeCfg nodeIpamCfg overlayPath;
      required = (addressSourcePolicy.required or false) == true;
      allowedClasses = listOrEmpty (addressSourcePolicy.allowedClasses or null);
    };
}
