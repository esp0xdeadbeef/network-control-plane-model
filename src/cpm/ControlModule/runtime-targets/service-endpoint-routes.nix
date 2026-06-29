{
  lib,
  common,
  ipam,
  hasP2PPrefixLength,
  routeIntent,
}:

let
  inherit (common) attrsOrEmpty listOrEmpty;

  serviceRecords =
    services:
    builtins.listToAttrs (
      builtins.map
        (service: {
          name = service.name;
          value = service;
        })
        (builtins.filter
          (service: builtins.isAttrs service && builtins.isString (service.name or null) && service.name != "")
          (listOrEmpty services))
    );

  externalServiceRules =
    rules:
    builtins.filter
      (rule:
      (rule.action or null) == "accept"
      && ((attrsOrEmpty (rule.from or null)).kind or null) == "external"
      && ((attrsOrEmpty (rule.to or null)).kind or null) == "service")
      (listOrEmpty rules);

  providerAddresses =
    family: service:
    let
      field = if family == 4 then "ipv4" else "ipv6";
    in
    lib.unique (lib.concatMap (endpoint: listOrEmpty (endpoint.${field} or null)) (
      listOrEmpty (service.providerEndpoints or null)
    ));

  p2pPeerAddress =
    family: cidr:
    let
      parsed = if builtins.isString cidr then ipam.splitCIDR cidr else null;
      expectedPrefixLen = if family == 4 then 31 else 127;
      parsedAddress =
        if parsed == null || parsed.prefixLen != expectedPrefixLen then
          null
        else if family == 4 then
          ipam.parseIPv4 parsed.addr
        else
          ipam.parseIPv6 parsed.addr;
      ipv4PeerInt =
        if parsedAddress == null || family != 4 then
          null
        else
          let
            addrInt = ipam.ipv4ToInt parsedAddress;
          in
          if lib.mod addrInt 2 == 0 then addrInt + 1 else addrInt - 1;
      ipv6Peer =
        if parsedAddress == null || family != 6 then
          null
        else
          builtins.genList
            (
              idx:
              if idx == 7 then
                if lib.mod (builtins.elemAt parsedAddress 7) 2 == 0 then
                  (builtins.elemAt parsedAddress 7) + 1
                else
                  (builtins.elemAt parsedAddress 7) - 1
              else
                builtins.elemAt parsedAddress idx
            )
            8;
    in
    if parsedAddress == null then
      null
    else if family == 4 then
      ipam.renderIPv4 (ipam.ipv4FromInt ipv4PeerInt)
    else
      ipam.renderIPv6 ipv6Peer;

  routeCandidates =
    family: iface:
    builtins.filter
      (route:
      builtins.isAttrs route
      && ((routeIntent route).kind or null) == "internal-reachability"
      && !hasP2PPrefixLength (route.dst or null)
      && (route.${if family == 4 then "via4" else "via6"} or null) != null)
      (listOrEmpty ((attrsOrEmpty (iface.routes or null)).${if family == 4 then "ipv4" else "ipv6"} or null));

  endpointRoutes =
    family: rule: service: ifaceArg:
    let
      fromIface =
        if builtins.isAttrs ifaceArg && (ifaceArg ? fromIface || ifaceArg ? toIface) then
          attrsOrEmpty (ifaceArg.fromIface or { })
        else
          ifaceArg;
      toIface =
        if builtins.isAttrs ifaceArg && ifaceArg ? toIface then
          attrsOrEmpty ifaceArg.toIface
        else
          ifaceArg;
      routeIface =
        if builtins.isAttrs ifaceArg && ifaceArg ? routeIface then
          attrsOrEmpty ifaceArg.routeIface
        else
          fromIface;
      viaField = if family == 4 then "via4" else "via6";
      candidates = routeCandidates family routeIface;
      peer = p2pPeerAddress family (routeIface.${if family == 4 then "addr4" else "addr6"} or null);
    in
    if peer == null && candidates == [ ] then
      [ ]
    else
      let
        via = if peer != null then peer else (builtins.head candidates).${viaField};
      in
      builtins.map
        (dst: {
          inherit dst family;
          proto = "internal";
          intent = {
            kind = "service-endpoint-reachability";
            service = service.name;
          };
          relationId = rule.relationId or null;
          trafficType = rule.trafficType or null;
          ${viaField} = via;
        })
        (providerAddresses family service);
in
{
  inherit
    endpointRoutes
    externalServiceRules
    serviceRecords
    ;
}
