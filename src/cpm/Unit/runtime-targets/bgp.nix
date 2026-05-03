{ lib, helpers, common, sitePath, nodes, policyNodeName, bgpSiteAsn }:

let
  inherit (helpers) hasAttr isNonEmptyString requireAttrs requireString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty;

  routerRoleSet = {
    access = true;
    core = true;
    downstream-selector = true;
    policy = true;
    upstream-selector = true;
  };

  loopbacksByNode =
    builtins.listToAttrs (
      builtins.map
        (nodeName:
          let
            nodePath = "${sitePath}.nodes.${nodeName}";
            nodeAttrs = requireAttrs nodePath nodes.${nodeName};
            loopback = requireAttrs "${nodePath}.loopback" (nodeAttrs.loopback or null);
          in
          {
            name = nodeName;
            value = {
              addr4 = requireString "${nodePath}.loopback.ipv4" (loopback.ipv4 or null);
              addr6 = requireString "${nodePath}.loopback.ipv6" (loopback.ipv6 or null);
            };
          })
        (sortedNames nodes)
    );

  routeIntentKind = r: if builtins.isAttrs (r.intent or null) then r.intent.kind or null else null;
  isHostRoute4 = dst: builtins.isString dst && lib.hasSuffix "/32" dst;
  isHostRoute6 = dst: builtins.isString dst && lib.hasSuffix "/128" dst;

  keepBgpRoute =
    family: r:
    let
      dst = r.dst or null;
      proto = r.proto or null;
      intentKind = routeIntentKind r;
    in
    builtins.isAttrs r
    && builtins.isString dst
    && (
      dst == (if family == 4 then "0.0.0.0/0" else "::/0")
      || proto == "uplink"
      || proto == "overlay"
      || intentKind == "overlay-reachability"
      || intentKind == "internal-reachability"
      || intentKind == "realized-interface-route"
      || (if family == 4 then isHostRoute4 dst else isHostRoute6 dst)
    );

  filterRoutesForBgp =
    routes:
    let
      routesAttrs = attrsOrEmpty routes;
    in
    {
      ipv4 = builtins.filter (keepBgpRoute 4) (listOrEmpty (routesAttrs.ipv4 or null));
      ipv6 = builtins.filter (keepBgpRoute 6) (listOrEmpty (routesAttrs.ipv6 or null));
    };

  bgpNeighborsForNode =
    nodeName:
    let
      isRouterNodeName =
        n:
        let
          nodePath = "${sitePath}.nodes.${n}";
          nodeAttrs = requireAttrs nodePath nodes.${n};
          roleRaw = nodeAttrs.role or null;
          role = if builtins.isString roleRaw then roleRaw else "";
        in
        isNonEmptyString role && hasAttr role routerRoleSet;
      routerNodeNames = builtins.filter isRouterNodeName (sortedNames nodes);
      isPolicy = nodeName == policyNodeName;
      peerNames = if isPolicy then builtins.filter (n: n != policyNodeName) routerNodeNames else [ policyNodeName ];
    in
    builtins.map
      (peerName:
        let
          peerLoop = loopbacksByNode.${peerName};
        in
        {
          peer_name = peerName;
          peer_asn = bgpSiteAsn;
          peer_addr4 = peerLoop.addr4;
          peer_addr6 = peerLoop.addr6;
          update_source = "lo";
          route_reflector_client = isPolicy;
        })
      peerNames;
in
{
  inherit bgpNeighborsForNode filterRoutesForBgp routerRoleSet;
}
