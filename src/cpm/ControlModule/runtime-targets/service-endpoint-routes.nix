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

  # Does a modelled (non-host) route on `iface` already cover `address`?
  #
  # A service address that sits inside a modelled prefix -- a tenant /24, an
  # overlay /24, and so on -- is already reached by that prefix's own route on
  # the lane. Synthesizing a more specific /32 or /128 for it adds no
  # reachability: the covering route already names the modelled next hop for the
  # lane. What the host route adds is specificity, so it wins over the modelled
  # route whenever the two disagree about the next hop, and the packet is sent
  # somewhere the modelled lane never authorised. Measured on the cobalt HAT: a
  # service /32 via the ingress peer beat the fabric /31 naming the real next hop
  # and reflected the query back out the interface it arrived on.
  #
  # FS-540-HDS-010 `Each requester-to-resolver relation` requires the service
  # route to ride the lane that owns its next hop and not to be expanded into
  # equal-prefix routes per attachment; FS-540-HDS-010-SDS-010-SMS-020 lists "one
  # requester table receives equal-prefix DNS routes through competing access-lane
  # next hops" as a failure condition. Deferring to the covering modelled prefix
  # keeps exactly one route meaning per destination.
  prefixContainsAddress =
    family: cidr: address:
    let
      parsed = if builtins.isString cidr then ipam.splitCIDR cidr else null;
      fullLen = if family == 4 then 32 else 128;
      parsedAddr =
        if parsed == null then
          null
        else if family == 4 then
          ipam.parseIPv4 parsed.addr
        else
          ipam.parseIPv6 parsed.addr;
      targetAddr =
        if !(builtins.isString address) then
          null
        else if family == 4 then
          ipam.parseIPv4 address
        else
          ipam.parseIPv6 address;
      take = count: values: builtins.genList (idx: builtins.elemAt values idx) count;
      fullHextets = if parsed == null then 0 else builtins.div parsed.prefixLen 16;

      # IPv4 containment, computed here rather than taken from `common`.
      # `common` is supplied by the caller, and a focused caller (a case that
      # exercises `endpointRoutes` directly) passes only the helpers that module
      # needs, so reaching for an optional member of it failed at evaluation with
      # `attribute 'cidrContainsAddress' missing`.
      ipv4ToInt =
        octets: builtins.foldl' (acc: octet: acc * 256 + octet) 0 octets;
      ipv4Contains =
        let
          cidrOctets = ipam.parseIPv4 parsed.addr;
          addrOctets = ipam.parseIPv4 address;
          hostBits = 32 - parsed.prefixLen;
          blockSize = builtins.foldl' (acc: _: acc * 2) 1 (builtins.genList (i: i) hostBits);
        in
        cidrOctets != null
        && addrOctets != null
        && parsed.prefixLen <= 32
        && builtins.div (ipv4ToInt cidrOctets) blockSize
        == builtins.div (ipv4ToInt addrOctets) blockSize;
    in
    parsed != null
    && parsedAddr != null
    && targetAddr != null
    # A host route is not a covering prefix; it cannot justify suppressing
    # itself, nor another host route for the same address.
    && parsed.prefixLen < fullLen
    && (
      if family == 4 then
        ipv4Contains
      else
        parsed.prefixLen == 127
        || (
          lib.mod parsed.prefixLen 16 == 0
          && take fullHextets parsedAddr == take fullHextets targetAddr
        )
    );

  coveredByModelledPrefix =
    family: iface: address:
    let
      viaField = if family == 4 then "via4" else "via6";
      routes = listOrEmpty (
        (attrsOrEmpty (iface.routes or null)).${if family == 4 then "ipv4" else "ipv6"} or null
      );
    in
    builtins.any
      (route:
        (routeIntent route).kind or null == "internal-reachability"
        # A /31 or /127 names a point-to-point link, not the service prefix; those
        # are the fabric routes this rule exists to stop shadowing.
        && !hasP2PPrefixLength (route.dst or null)
        && (route.${viaField} or null) != null
        && prefixContainsAddress family (route.dst or null) address)
      routes;

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
      bareAddress = a: builtins.head (lib.splitString "/" a);
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
        (address: {
          # Emit an explicit host prefix so the service endpoint route shares
          # the same destination key as the fabric internal-reachability host
          # route (e.g. 10.1.1.9/32). A bare address would become a second,
          # distinct destination and let a wrong-direction fabric route win.
          dst =
            if lib.hasInfix "/" address then
              address
            else
              "${address}/${if family == 4 then "32" else "128"}";
          inherit family;
          proto = "internal";
          intent = {
            kind = "service-endpoint-reachability";
            service = service.name;
          };
          relationId = rule.relationId or null;
          trafficType = rule.trafficType or null;
          ${viaField} = via;
        })
        (builtins.filter
          (address: !(coveredByModelledPrefix family routeIface (bareAddress address)))
          (providerAddresses family service));
in
{
  inherit
    coveredByModelledPrefix
    endpointRoutes
    externalServiceRules
    prefixContainsAddress
    serviceRecords
    ;
}
