# FS-460 / FS-540-HDS-010-SDS-010-SMS-020: overlay DNS ingress transit.
#
# When a modeled DNS relation enters the site from an overlay ("external" whose
# name is the overlay), the overlay termination node must route the provider
# tenant's prefixes back through its modeled underlay egress. Otherwise that
# node can only reach the provider through an ambient default, which is exactly
# the "route by broad default instead of by the modeled relation" behavior
# FS-550/FS-540 reject.
#
# The inputs are all modeled facts: the relation (external -> service, dns), the
# service's provider tenants, those tenants' modeled prefixes, and the
# termination node's uplink lane toward the overlay's underlay egress. The next
# hop is the on-link peer of that lane. Nothing is inferred from names or order,
# and no route is emitted for a lane the relation does not name.
{ lib
, common
, ipam
,
}:
{ runtimeTargets
, services ? [ ]
, allowedRelations ? [ ]
,
}:
let
  inherit (common) attrsOrEmpty listOrEmpty uniqueStrings;

  laneOf = iface: attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null);

  interfacesOf =
    target: attrsOrEmpty ((attrsOrEmpty (target.effectiveRuntimeRealization or null)).interfaces or null);

  routesOf = family: iface: listOrEmpty ((attrsOrEmpty (iface.routes or null))."ipv${builtins.toString family}" or null);

  serviceByName =
    name:
    let
      matches = builtins.filter (service: (service.name or null) == name) services;
    in
    if matches == [ ] then null else builtins.head matches;

  # Overlay ingress DNS relations: an "external" source whose name is the
  # overlay, targeting a service. Their name is the overlay lane name.
  overlayDnsRelations = builtins.filter
    (
      relation:
      (relation.action or "allow") == "allow"
      && ((attrsOrEmpty (relation.from or null)).kind or null) == "external"
      && ((attrsOrEmpty (relation.to or null)).kind or null) == "service"
      && (relation.trafficType or null) == "dns"
      && builtins.isString ((attrsOrEmpty (relation.from or null)).name or null)
    )
    allowedRelations;

  # The tenant identity lives on the target's modeled attachments; the tenant
  # interface's lane names the access scope, not the tenant.
  targetHostsTenant =
    targetName: tenant:
    builtins.any
      (attachment:
      builtins.isAttrs attachment
      && (attachment.kind or null) == "tenant"
      && (attachment.name or null) == tenant)
      (listOrEmpty (runtimeTargets.${targetName}.attachments or null));

  tenantPrefixes =
    tenant:
    uniqueStrings (
      builtins.concatLists (
        builtins.map
          (targetName:
          builtins.concatLists (
            builtins.map
              (
                iface:
                let
                  lane = laneOf iface;
                  entry =
                    family: value:
                    if builtins.isString value && value != "" then
                      let
                        network = ipam.canonicalNetworkPrefix value;
                      in
                      lib.optional (network != null) network
                    else
                      [ ];
                in
                if (iface.sourceKind or null) == "tenant" && targetHostsTenant targetName tenant then
                  entry 4 (iface.addr4 or null) ++ entry 6 (iface.addr6 or null)
                else
                  [ ]
              )
              (builtins.attrValues (interfacesOf runtimeTargets.${targetName}))
          ))
          (builtins.attrNames runtimeTargets)
      )
    );

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

  relationRoutes =
    targetName: relation:
    let
      to = attrsOrEmpty (relation.to or null);
      from = attrsOrEmpty (relation.from or null);
      service = serviceByName (to.name or null);
      providerTenants = if service == null then [ ] else listOrEmpty (service.providerTenants or null);
      overlayName = from.name or null;
      prefixes = uniqueStrings (builtins.concatMap tenantPrefixes providerTenants);
      routeFor =
        family:
        iface:
        let
          viaField = if family == 4 then "via4" else "via6";
          addrField = if family == 4 then "addr4" else "addr6";
          via = peerAddress family (iface.${addrField} or null);
        in
        if via == null then
          [ ]
        else
          builtins.map
            (dst: {
              inherit dst family;
              proto = "internal";
              intent = {
                kind = "internal-reachability";
                source = "overlay-ingress-return";
              };
              lane = laneOf iface;
              relationId = relation.id or null;
              ${viaField} = via;
            })
            prefixes;
    in
    if overlayName == null || prefixes == [ ] then
      [ ]
    else
      builtins.concatLists (
        builtins.map
          (
            iface:
            let
              lane = laneOf iface;
              laneUplinks = listOrEmpty (lane.uplinks or null) ++ lib.optional (builtins.isString (lane.uplink or null)) lane.uplink;
            in
            if (iface.sourceKind or null) == "p2p" && builtins.elem overlayName laneUplinks then
              routeFor 4 iface ++ routeFor 6 iface
            else
              [ ]
          )
          (builtins.attrValues (interfacesOf runtimeTargets.${targetName}))
      );

  # Only the overlay termination node (a core that owns the overlay ingress)
  # carries the transit route set; selectors and the policy point already receive
  # the relation-scoped legs from their own projection.
  addRoutes =
    targetName: target:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
      targetRoutes =
        if (target.role or "") != "core" then
          [ ]
        else
          builtins.concatLists (builtins.map (relationRoutes targetName) overlayDnsRelations);
    in
    if targetRoutes == [ ] then
      target
    else
      target
      // {
        effectiveRuntimeRealization = effective // {
          interfaces = builtins.mapAttrs
            (
              _ifName: iface:
                let
                  lane = laneOf iface;
                  laneUplinks =
                    listOrEmpty (lane.uplinks or null)
                    ++ lib.optional (builtins.isString (lane.uplink or null)) lane.uplink;
                  overlayNames = builtins.map (relation: (attrsOrEmpty (relation.from or null)).name or null) overlayDnsRelations;
                  applicable =
                    (iface.sourceKind or null) == "p2p"
                    && builtins.any (name: name != null && builtins.elem name laneUplinks) overlayNames;
                  own = if applicable then builtins.filter (route: builtins.elem (route.dst or null) (lib.unique (map (r: r.dst) targetRoutes))) targetRoutes else [ ];
                  routes = attrsOrEmpty (iface.routes or null);
                  existing4 = routesOf 4 iface;
                  existing6 = routesOf 6 iface;
                  keyOf = route: "${builtins.toString (route.family or 0)}|${route.dst or ""}|${route.via4 or route.via6 or ""}";
                  filtered =
                    family: existing: builtins.filter
                      (route: !(builtins.any (own: keyOf own == keyOf route) own))
                      existing;
                  add4 = builtins.filter (route: (route.family or null) == 4) own;
                  add6 = builtins.filter (route: (route.family or null) == 6) own;
                in
                iface
                // {
                  routes = routes // {
                    ipv4 = filtered 4 existing4 ++ add4;
                    ipv6 = filtered 6 existing6 ++ add6;
                  };
                }
            )
            interfaces;
        };
      };
in
builtins.mapAttrs addRoutes runtimeTargets
