{ common, ipv4, ipv6 }:

let
  inherit (common) pow2 splitCIDR;
  inherit (ipv4) ipv4FromInt ipv4NetworkBaseInt ipv4ToInt parseIPv4 renderIPv4;
  inherit (ipv6) ipv6FromInt ipv6NetworkBaseInt ipv6ToInt parseIPv6 renderIPv6;

  allocOne =
    {
      family,
      prefix,
      perNodePrefixLength,
      offset,
    }:
    let
      cidr = splitCIDR prefix;
    in
    if cidr == null then
      throw "ipam: prefix must be CIDR (got ${builtins.toJSON prefix})"
    else if family == 4 then
      let
        parsed = parseIPv4 cidr.addr;
        prefixLen = cidr.prefixLen;
      in
      if parsed == null then
        throw "ipam: invalid IPv4 prefix address '${toString cidr.addr}'"
      else if !(builtins.isInt prefixLen) || prefixLen < 0 || prefixLen > 32 then
        throw "ipam: invalid IPv4 prefix length '/${toString prefixLen}'"
      else if perNodePrefixLength != 32 then
        throw "ipam: only perNodePrefixLength=32 is supported for IPv4 right now"
      else
        let
          base = ipv4NetworkBaseInt { addrInt = ipv4ToInt parsed; inherit prefixLen; };
          cap = pow2 (32 - prefixLen);
          _cap = if offset < 0 || offset >= cap then throw "ipam: IPv4 offset ${toString offset} overflows ${toString prefix} capacity ${toString cap}" else true;
        in
        "${renderIPv4 (ipv4FromInt (builtins.seq _cap (base + offset)))}/32"
    else if family == 6 then
      let
        parsed = parseIPv6 cidr.addr;
        prefixLen = cidr.prefixLen;
      in
      if parsed == null then
        throw "ipam: invalid IPv6 prefix address '${toString cidr.addr}'"
      else if !(builtins.isInt prefixLen) || prefixLen < 0 || prefixLen > 128 then
        throw "ipam: invalid IPv6 prefix length '/${toString prefixLen}'"
      else if perNodePrefixLength != 128 then
        throw "ipam: only perNodePrefixLength=128 is supported for IPv6 right now"
      else
        let
          base = ipv6NetworkBaseInt { addrInt = ipv6ToInt parsed; inherit prefixLen; };
          cap = pow2 (128 - prefixLen);
          _cap = if offset < 0 || offset >= cap then throw "ipam: IPv6 offset ${toString offset} overflows ${toString prefix} capacity ${toString cap}" else true;
        in
        "${renderIPv6 (ipv6FromInt (builtins.seq _cap (base + offset)))}/128"
    else
      throw "ipam: invalid family ${toString family}";

in
{
  inherit allocOne;
}
