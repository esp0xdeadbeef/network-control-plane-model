{
  helpers,
  ipam,
  enterpriseRoot,
}:

let
  inherit (helpers)
    requireAttrs
    requireString
    sortedNames
    ;

  commonLib = import ../../ControlModule/lib/common.nix { inherit helpers; };
  inherit (commonLib)
    attrsOrEmpty
    listOrEmpty
    mergeRoutes
    uniqueStrings
    ;

  allSiteEntries =
    builtins.concatLists (
      builtins.map
        (enterpriseKey:
          let
            enterpriseValue = requireAttrs "forwardingModel.enterprise.${enterpriseKey}" (enterpriseRoot.${enterpriseKey} or null);
            siteRoot = requireAttrs "forwardingModel.enterprise.${enterpriseKey}.site" (enterpriseValue.site or null);
          in
          builtins.map
            (siteKey:
              let
                candidateSite = requireAttrs "forwardingModel.enterprise.${enterpriseKey}.site.${siteKey}" siteRoot.${siteKey};
              in
              {
                enterpriseKey = enterpriseKey;
                siteKey = siteKey;
                site = candidateSite;
                siteId = requireString "forwardingModel.enterprise.${enterpriseKey}.site.${siteKey}.siteId" (candidateSite.siteId or null);
                siteDisplayName = requireString "forwardingModel.enterprise.${enterpriseKey}.site.${siteKey}.siteName" (candidateSite.siteName or null);
              })
            (sortedNames siteRoot))
        (sortedNames enterpriseRoot)
    );

  pow2 = n: builtins.foldl' (acc: _: acc * 2) 1 (builtins.genList (i: i) n);

  ipv4ToInt =
    octets:
    let
      a = builtins.elemAt octets 0;
      b = builtins.elemAt octets 1;
      c = builtins.elemAt octets 2;
      d = builtins.elemAt octets 3;
    in
    a * 16777216 + b * 65536 + c * 256 + d;

  ipv4NetworkBaseInt =
    { addrInt, prefixLen }:
    let
      block = pow2 (32 - prefixLen);
    in
    (builtins.div addrInt block) * block;

  cidrContainsAddress =
    cidr: address:
    let
      parsedCidr = ipam.splitCIDR cidr;
    in
    if parsedCidr == null then
      false
    else
      let
        cidrAddr = ipam.parseIPv4 parsedCidr.addr;
        addr = ipam.parseIPv4 address;
      in
      cidrAddr != null
      && addr != null
      && ipv4NetworkBaseInt { addrInt = ipv4ToInt addr; prefixLen = parsedCidr.prefixLen; }
      == ipv4NetworkBaseInt { addrInt = ipv4ToInt cidrAddr; prefixLen = parsedCidr.prefixLen; };

  failForwarding = path: message:
    throw "forwarding-model update required: ${path}: ${message}";

  failInventory = path: message:
    throw "inventory.nix update required: ${path}: ${message}";

in
{
  inherit
    allSiteEntries
    attrsOrEmpty
    cidrContainsAddress
    failForwarding
    failInventory
    listOrEmpty
    mergeRoutes
    uniqueStrings
    ;
}
