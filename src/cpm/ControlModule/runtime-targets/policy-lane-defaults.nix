# FS-540-HDS-010-SDS-010-SMS-045 / FS-315: the policy point realizes the
# scope's selected exit in its own policy table.
#
# The forwarding model emits the access-selected default on the upstream
# selector side of each access-uplink lane. The policy point, where the
# selection becomes a routing table (FS-315: "Every route shall belong to an
# explicit context table selected by modeled scope or lane"), must carry that
# same default on its own end of the same modeled lane, or an accepted forward
# flow steered into the policy table has no exit.
#
# The default prefix and the on-link next hop are both modeled facts: the
# prefix is the peer lane's default and the next hop is the peer address of the
# same modeled p2p link (`link::...` identity shared by both ends). Nothing is
# inferred from names or ordering, and no default is created for a lane whose
# peer does not carry one.
{ lib
, common
, ipam
,
}:
runtimeTargets:
let
  inherit (common) attrsOrEmpty listOrEmpty;

  defaultDst = family: if family == 4 then "0.0.0.0/0" else "::/0";

  laneKind = iface: (attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null)).kind or "";

  laneOf = iface: attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null);

  linkId =
    iface:
    let
      id = (attrsOrEmpty (iface.backingRef or null)).id or null;
    in
    if builtins.isString id && id != "" then id else null;

  routesOf = family: iface: listOrEmpty ((attrsOrEmpty (iface.routes or null))."ipv${builtins.toString family}" or null);

  hasDefault = family: iface: builtins.any (route: builtins.isAttrs route && (route.dst or null) == defaultDst family) (routesOf family iface);

  # Peer address of a modeled p2p link (/31 IPv4, /127 IPv6).
  peerAddress =
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

  # All interfaces of all targets keyed by their modeled link identity.
  interfacesByLink = builtins.foldl'
    (acc: targetName:
      builtins.foldl'
        (inner: ifName:
          let
            iface = runtimeTargets.${targetName}.effectiveRuntimeRealization.interfaces.${ifName};
            id = linkId iface;
          in
          if id == null || targetName == null then
            inner
          else if builtins.hasAttr id inner then
            inner // { ${id} = inner.${id} ++ [{ inherit targetName iface; }]; }
          else
            inner // { ${id} = [{ inherit targetName iface; }]; })
        acc
        (builtins.attrNames runtimeTargets.${targetName}.effectiveRuntimeRealization.interfaces))
    { }
    (builtins.attrNames runtimeTargets);

  peerDefaultsFor =
    family: targetName: iface:
    let
      id = linkId iface;
    in
    if id == null then
      [ ]
    else
      builtins.filter
        (entry: entry.targetName != targetName && hasDefault family entry.iface)
        (interfacesByLink.${id} or [ ]);

  defaultRouteFor =
    family: targetName: iface:
    let
      peerField = if family == 4 then "addr4" else "addr6";
      viaField = if family == 4 then "via4" else "via6";
      via = peerAddress family (iface.${peerField} or null);
    in
    if hasDefault family iface || via == null then
      null
    else if peerDefaultsFor family targetName iface == [ ] then
      null
    else
      {
        dst = defaultDst family;
        inherit family;
        proto = "internal";
        intent = {
          kind = "default-reachability";
          policyTableComplement = true;
          source = "policy-lane-default";
        };
        lane = laneOf iface;
        policyOnly = true;
        reason = "policy-table-default-reachability";
        ${viaField} = via;
      };

  complementInterface =
    targetName: iface:
    if laneKind iface != "access-uplink" then
      iface
    else
      let
        extra = builtins.filter (route: route != null) [
          (defaultRouteFor 4 targetName iface)
          (defaultRouteFor 6 targetName iface)
        ];
      in
      if extra == [ ] then
        iface
      else
        let
          routes = attrsOrEmpty (iface.routes or null);
        in
        iface
        // {
          routes = routes // {
            ipv4 = listOrEmpty (routes.ipv4 or null) ++ builtins.filter (route: route.family == 4) extra;
            ipv6 = listOrEmpty (routes.ipv6 or null) ++ builtins.filter (route: route.family == 6) extra;
          };
        };

  complementTarget =
    targetName: target:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
    in
    target
    // {
      effectiveRuntimeRealization = effective // {
        interfaces = builtins.mapAttrs (_ifName: iface: complementInterface targetName iface) interfaces;
      };
    };

in
builtins.mapAttrs complementTarget runtimeTargets
