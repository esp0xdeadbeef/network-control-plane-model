{ lib
, helpers
, common
, overlayProvisioning
, interfaceOverlayLaneNames
, interfaceOverlayNames
, p2pPeerAddress
, defaultViaRoutes
, overlayNodeRoutesVia
, overlayPeerTenantRoutes
, overlayRuntimeRoutedPrefixRoutes
, overlayRuntimeRoutedPrefixRoutesVia
, delegatedOverlayDefaultRoutes
, delegatedOverlayAuthorityDefaults
, withoutGenericOverlayDefaults
, runtimePrefixExitNodes
, overlayUnderlayEndpoints
,
}:

let
  inherit (helpers) hasAttr isNonEmptyString;
  inherit (common) attrsOrEmpty listOrEmpty mergeRoutes;

  overlayNodeRouteAugmenters = import ./overlay-node-routes.nix {
    inherit
      lib
      helpers
      common
      overlayProvisioning
      p2pPeerAddress
      overlayNodeRoutesVia
      overlayRuntimeRoutedPrefixRoutesVia
      ;
  };
  inherit (overlayNodeRouteAugmenters)
    addOverlayNodeRoutesToSelector
    addOverlayNodeRoutesToCoreOverlay
    ;

  underlayEndpointRoutesFor =
    family: overlayNames: routes:
    let
      viaField = if family == 4 then "via4" else "via6";
      endpoints =
        builtins.filter
          (
            endpoint:
            (endpoint.family or null) == family
            && isNonEmptyString (endpoint.sourceFile or null)
            && builtins.elem (endpoint.overlay or null) overlayNames
          )
          overlayUnderlayEndpoints;
    in
    lib.concatMap
      (defaultRoute:
      builtins.map
        (endpoint: {
          inherit family;
          sourceFile = endpoint.sourceFile;
          proto = "underlay";
          overlay = endpoint.overlay;
          intent = {
            kind = "overlay-underlay-reachability";
            source = "overlay-underlay-endpoint";
          };
          ${viaField} = defaultRoute.${viaField};
        })
        endpoints)
      (defaultViaRoutes family routes);

  addOverlayUnderlayEndpointRoutesToCore =
    nodeRole: interfaces:
    if nodeRole != "core" || overlayUnderlayEndpoints == [ ] then
      interfaces
    else
      let
        nodeOverlayNames = interfaceOverlayNames interfaces;
      in
      if nodeOverlayNames == [ ] then
        interfaces
      else
        lib.mapAttrs
          (
            _: iface:
            let
              routes = attrsOrEmpty (iface.routes or null);
              extraRoutes = {
                ipv4 = underlayEndpointRoutesFor 4 nodeOverlayNames routes;
                ipv6 = underlayEndpointRoutesFor 6 nodeOverlayNames routes;
              };
            in
            if
              (iface.sourceKind or null) != "p2p"
              || (extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ])
            then
              iface
            else
              iface // { routes = mergeRoutes routes extraRoutes; }
          )
          interfaces;

  addDelegatedOverlayDefaultRoutesToCore =
    nodeRole: interfaces:
    if nodeRole != "core" || runtimePrefixExitNodes == [ ] then
      interfaces
    else
      lib.mapAttrs
        (
          _: iface:
          let
            overlayName = ((iface.backingRef or { }).name or null);
            runtimeNode = iface.logicalNode or null;
            routes = attrsOrEmpty (iface.routes or null);
            delegatedDefaultsFromRoutes4 = delegatedOverlayDefaultRoutes 4 routes;
            delegatedDefaultsFromRoutes6 = delegatedOverlayDefaultRoutes 6 routes;
            delegatedDefaults = {
              ipv4 =
                if delegatedDefaultsFromRoutes4 != [ ] then
                  delegatedDefaultsFromRoutes4
                else
                  delegatedOverlayAuthorityDefaults 4 overlayName runtimeNode;
              ipv6 =
                if delegatedDefaultsFromRoutes6 != [ ] then
                  delegatedDefaultsFromRoutes6
                else
                  delegatedOverlayAuthorityDefaults 6 overlayName runtimeNode;
            };
            cleanedRoutes = routes // {
              ipv4 = withoutGenericOverlayDefaults 4 routes;
              ipv6 = withoutGenericOverlayDefaults 6 routes;
            };
          in
          if
            (iface.sourceKind or null) != "overlay"
            || (delegatedDefaults.ipv4 == [ ] && delegatedDefaults.ipv6 == [ ])
          then
            iface
          else
            iface // { routes = mergeRoutes cleanedRoutes delegatedDefaults; }
        )
        interfaces;

  # The NAT/NAT66 source prefixes of an egress-only WireGuard overlay are the
  # local tenant scopes the tunnel serves. Their return path (un-NAT'd replies
  # coming back out of the tunnel) must route toward the fabric, not the
  # underlay bootstrap path (FS-470 return-route expectation).
  addEgressSourceReturnRoutesToCore =
    nodeRole: interfaces:
    if nodeRole != "core" then
      interfaces
    else
      lib.mapAttrs
        (
          _: iface:
          let
            lane = ((iface.backingRef or { }).lane or { });
            overlayName = lane.uplink or null;
            overlayCfg =
              if isNonEmptyString overlayName && hasAttr overlayName overlayProvisioning then
                overlayProvisioning.${overlayName}
              else
                { };
            providerContract = attrsOrEmpty (overlayCfg.providerContract or null);
            nat = attrsOrEmpty (providerContract.nat or null);
            sourceCidrs4 = listOrEmpty ((attrsOrEmpty (nat.ipv4 or null)).sourceCidrs or null);
            sourceCidrs6 = listOrEmpty ((attrsOrEmpty (nat.ipv6 or null)).sourceCidrs or null);
            via4 = p2pPeerAddress 4 (iface.addr4 or null);
            via6 = p2pPeerAddress 6 (iface.addr6 or null);
            isOverlayFabric =
              (iface.sourceKind or null) == "p2p"
              && (lane.kind or null) == "uplink"
              && isNonEmptyString overlayName
              && hasAttr overlayName overlayProvisioning;
            routes = attrsOrEmpty (iface.routes or null);
            returnRoutes = {
              ipv4 =
                if via4 == null then
                  [ ]
                else
                  builtins.map
                    (cidr: {
                      dst = cidr;
                      family = 4;
                      via4 = via4;
                      proto = "internal";
                      intent = {
                        kind = "internal-reachability";
                        source = "egress-source-return";
                      };
                    })
                    sourceCidrs4;
              ipv6 =
                if via6 == null then
                  [ ]
                else
                  builtins.map
                    (cidr: {
                      dst = cidr;
                      family = 6;
                      via6 = via6;
                      proto = "internal";
                      intent = {
                        kind = "internal-reachability";
                        source = "egress-source-return";
                      };
                    })
                    sourceCidrs6;
            };
          in
          if !isOverlayFabric || (returnRoutes.ipv4 == [ ] && returnRoutes.ipv6 == [ ]) then
            iface
          else
            iface // { routes = mergeRoutes routes returnRoutes; }
        )
        interfaces;

  addRuntimePrefixReturnsToCoreOverlay =
    nodeRole: interfaces:
    if nodeRole != "core" then
      interfaces
    else
      lib.mapAttrs
        (
          _: iface:
          let
            overlayName = ((iface.backingRef or { }).name or null);
            routes = attrsOrEmpty (iface.routes or null);
            extraRoutes = {
              ipv4 =
                if isNonEmptyString overlayName && hasAttr overlayName overlayProvisioning then
                  builtins.filter (route: (route.family or null) == 4) (overlayPeerTenantRoutes overlayName)
                else
                  [ ];
              ipv6 =
                if isNonEmptyString overlayName && hasAttr overlayName overlayProvisioning then
                  (builtins.filter (route: (route.family or null) == 6) (overlayPeerTenantRoutes overlayName))
                  ++ overlayRuntimeRoutedPrefixRoutes overlayName
                else
                  [ ];
            };
          in
          if (iface.sourceKind or null) != "overlay" || (extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ]) then
            iface
          else
            iface // { routes = mergeRoutes routes extraRoutes; }
        )
        interfaces;

  # An egress-only WireGuard overlay terminates a policy-routed provider exit
  # (FS-470). Its generic default (0.0.0.0/0 and ::/0 over the tunnel, the
  # WireGuard AllowedIPs) must be installed in the core's shared fabric policy
  # table so tenant payload ingressing from the upstream-selector is routed
  # through the tunnel — not the underlay bootstrap path, which must stay
  # payload-inert (URS: underlay reachability does not become payload
  # reachability).
  addGenericOverlayDefaultRoutesToCore =
    nodeRole: interfaces:
    if nodeRole != "core" then
      interfaces
    else
      lib.mapAttrs
        (
          _: iface:
          let
            overlayName = ((iface.backingRef or { }).name or null);
            overlayCfg =
              if isNonEmptyString overlayName && hasAttr overlayName overlayProvisioning then
                overlayProvisioning.${overlayName}
              else
                { };
            providerContract = attrsOrEmpty (overlayCfg.providerContract or null);
            providerMode = (attrsOrEmpty (providerContract.provider or null)).mode or null;
            isEgressOnlyOverlay =
              (iface.sourceKind or null) == "overlay"
              && isNonEmptyString overlayName
              && providerMode == "egress-only";
            routes = attrsOrEmpty (iface.routes or null);
            genericDefaults = {
              ipv4 = [
                {
                  dst = "0.0.0.0/0";
                  family = 4;
                  inherit overlayName;
                  overlay = overlayName;
                  policyOnly = true;
                  proto = "overlay";
                  scope = "link";
                  intent = {
                    kind = "default-reachability";
                    source = "overlay-egress";
                  };
                }
              ];
              ipv6 = [
                {
                  dst = "::/0";
                  family = 6;
                  inherit overlayName;
                  overlay = overlayName;
                  policyOnly = true;
                  proto = "overlay";
                  scope = "link";
                  intent = {
                    kind = "default-reachability";
                    source = "overlay-egress";
                  };
                }
              ];
            };
          in
          if !isEgressOnlyOverlay then
            iface
          else
            iface // { routes = mergeRoutes routes genericDefaults; }
        )
        interfaces;


in
{
  inherit
    addOverlayNodeRoutesToSelector
    addOverlayNodeRoutesToCoreOverlay
    addOverlayUnderlayEndpointRoutesToCore
    addDelegatedOverlayDefaultRoutesToCore
    addGenericOverlayDefaultRoutesToCore
    addEgressSourceReturnRoutesToCore
    addRuntimePrefixReturnsToCoreOverlay
    ;
}
