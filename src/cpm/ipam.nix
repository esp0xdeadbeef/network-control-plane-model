{ lib }:

let
  common = import ./ControlModule/lib/ipam/common.nix { inherit lib; };
  ipv4 = import ./ControlModule/lib/ipam/ipv4.nix { inherit common; };
  ipv6 = import ./ControlModule/lib/ipam/ipv6.nix { inherit lib common; };
  allocation = import ./ControlModule/lib/ipam/allocation.nix {
    inherit common ipv4 ipv6;
  };
  canonicalNetworkPrefix =
    value:
    let
      pow2 = exponent: builtins.foldl' (acc: _: acc * 2) 1 (builtins.genList (index: index) exponent);
      parsedCidr = if builtins.isString value then common.splitCIDR value else null;
      isIpv6 = parsedCidr != null && builtins.match ".*:.*" parsedCidr.addr != null;
      parsedAddress =
        if parsedCidr == null then
          null
        else if isIpv6 then
          ipv6.parseIPv6 parsedCidr.addr
        else
          ipv4.parseIPv4 parsedCidr.addr;
      validPrefixLength =
        parsedCidr != null
        && parsedCidr.prefixLen >= 0
        && parsedCidr.prefixLen <= (if isIpv6 then 128 else 32);
      networkAddress =
        if parsedAddress == null || !validPrefixLength then
          null
        else if isIpv6 then
          let
            completeHextets = builtins.div parsedCidr.prefixLen 16;
            remainingBits = parsedCidr.prefixLen - completeHextets * 16;
            networkHextets = lib.imap0 (
              index: hextet:
              if index < completeHextets then
                hextet
              else if index == completeHextets && remainingBits > 0 then
                let block = pow2 (16 - remainingBits); in (builtins.div hextet block) * block
              else
                0
            ) parsedAddress;
          in
          ipv6.renderIPv6 networkHextets
        else
          ipv4.renderIPv4 (ipv4.ipv4FromInt (ipv4.ipv4NetworkBaseInt {
            addrInt = ipv4.ipv4ToInt parsedAddress;
            inherit (parsedCidr) prefixLen;
          }));
    in
    if networkAddress == null then null else "${networkAddress}/${toString parsedCidr.prefixLen}";
in
{
  inherit canonicalNetworkPrefix;
  inherit (common) splitCIDR;
  inherit (ipv4)
    ipv4FromInt
    ipv4NetworkBaseInt
    ipv4ToInt
    parseIPv4
    renderIPv4
    ;
  inherit (ipv6)
    ipv6NetworkBaseInt
    ipv6ToInt
    parseIPv6
    renderIPv6
    ;
  inherit (allocation) allocOne;
}
