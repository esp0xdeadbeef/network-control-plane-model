{ helpers
, natHelpers
,
}:

let
  inherit (natHelpers) attrsOrEmpty hasHostIPv6;
in
{ interfaceRecords
, nat66ByUplink
,
}:
let
  explicitNat66Interfaces = builtins.filter
    (
      iface:
      let
        wan = attrsOrEmpty (iface.wan or null);
        egress = attrsOrEmpty (wan.egress or null);
        ipv6 = attrsOrEmpty (egress.ipv6 or null);
        translation = attrsOrEmpty (ipv6.translation or null);
        modeledNat66 = attrsOrEmpty (nat66ByUplink.${iface.upstream or ""} or null);
      in
      (translation.mode or null) == "nat66" && (modeledNat66.mode or null) == "nat66"
    )
    interfaceRecords;

  hasNat66EgressAuthority = iface:
    let
      hostUplink = attrsOrEmpty (iface.hostUplink or null);
      hostIpv6 = attrsOrEmpty (hostUplink.ipv6 or null);
      ifaceIpv6 = attrsOrEmpty (iface.ipv6 or null);
      wan = attrsOrEmpty (iface.wan or null);
      egress = attrsOrEmpty (wan.egress or null);
      wanIpv6 = attrsOrEmpty (egress.ipv6 or null);
      translation = attrsOrEmpty (wanIpv6.translation or null);
    in
    hasHostIPv6 iface
    && builtins.any (value: value == true) [
      (hostIpv6.egressAuthority or false)
      (hostIpv6.providerEgress or false)
      (hostIpv6.routeAuthority or false)
      (ifaceIpv6.egressAuthority or false)
      (wanIpv6.egressAuthority or false)
      (translation.egressAuthority or false)
    ];
in
{
  inherit explicitNat66Interfaces hasNat66EgressAuthority;
  explicitNat66RuntimeNames = map (iface: iface.runtimeIfName) explicitNat66Interfaces;
}
