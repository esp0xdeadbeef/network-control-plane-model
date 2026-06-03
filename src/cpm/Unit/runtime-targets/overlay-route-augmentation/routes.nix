{ lib
, helpers
, common
, overlayProvisioning
, overlayUnderlayEndpoints
, defaultViaRoutes
, runtimePrefixExitNodes
,
}:
let
  inherit (helpers) isNonEmptyString;
  inherit (common) listOrEmpty;
  prefixRoutes = import ./prefix-routes.nix {
    inherit lib helpers common overlayProvisioning runtimePrefixExitNodes;
  };
  delegatedOverlayDefaultRoutes =
    family: routes:
    let
      defaultDst = if family == 4 then "0.0.0.0/0" else "::/0";
      familyRoutes = listOrEmpty (routes.${if family == 4 then "ipv4" else "ipv6"} or null);
      publicExitPeerSiteFor =
        route:
        let
          overlayName = route.overlay or null;
          overlay = if isNonEmptyString overlayName then overlayProvisioning.${overlayName} or { } else { };
        in
          overlay.publicExitPeerSite or route.peerSite or null;
      overlayDefaults =
        builtins.filter
          (route:
            (route.dst or null) == defaultDst
            && ((route.intent or { }).kind or null) == "overlay-reachability"
            && (route.proto or null) == "overlay")
          familyRoutes;
    in
    lib.concatMap
      (route:
      builtins.map
        (exitNode:
        route
        // {
          policyOnly = true;
          scope = "link";
          intent = {
            kind = "delegated-public-egress";
            inherit exitNode;
          };
        }
        // lib.optionalAttrs (isNonEmptyString (publicExitPeerSiteFor route)) {
          peerSite = publicExitPeerSiteFor route;
        })
        runtimePrefixExitNodes)
      overlayDefaults;
  withoutGenericOverlayDefaults =
    family: routes:
    let
      defaultDst = if family == 4 then "0.0.0.0/0" else "::/0";
    in
    builtins.filter
      (
        route:
          !(
            (route.dst or null) == defaultDst
            && ((route.intent or { }).kind or null) == "overlay-reachability"
            && (route.proto or null) == "overlay"
          )
      )
      (listOrEmpty (routes.${if family == 4 then "ipv4" else "ipv6"} or null));
  underlayEndpointRoutes =
    family: routes:
    let
      viaField = if family == 4 then "via4" else "via6";
      endpoints = builtins.filter (endpoint: (endpoint.family or null) == family && isNonEmptyString (endpoint.sourceFile or null)) overlayUnderlayEndpoints;
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
  overlayEndpointRoutesVia =
    family: overlayNamesForInterface: via:
    let
      viaField = if family == 4 then "via4" else "via6";
      endpoints =
        builtins.filter
          (endpoint: (endpoint.family or null) == family && isNonEmptyString (endpoint.sourceFile or null) && builtins.elem (endpoint.overlay or null) overlayNamesForInterface)
          overlayUnderlayEndpoints;
    in
    if !isNonEmptyString via then [ ] else
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
        ${viaField} = via;
      })
      endpoints;
  overlayNodeRoutesVia =
    family: overlayNamesForInterface: via:
    let
      viaField = if family == 4 then "via4" else "via6";
      prefixField = if family == 4 then "ipv4" else "ipv6";
      prefixes =
        lib.unique (lib.concatMap
          (overlayName:
            let
              structuredPrefixes = listOrEmpty (overlayProvisioning.${overlayName}.nodeRoutePrefixRecords.${prefixField} or null);
              legacyPrefixes = map
                (dst: {
                  inherit dst;
                  overlay = overlayName;
                })
                (listOrEmpty (overlayProvisioning.${overlayName}.nodeRoutePrefixes.${prefixField} or null));
            in
            if structuredPrefixes != [ ] then structuredPrefixes else legacyPrefixes)
          overlayNamesForInterface);
    in
    if !isNonEmptyString via then [ ] else
    builtins.map
      (prefix:
        {
          inherit family;
          dst = prefix.dst;
          proto = "internal";
          intent = { kind = "overlay-node-reachability"; };
          ${viaField} = via;
        }
        // lib.optionalAttrs (isNonEmptyString (prefix.overlay or null)) { overlay = prefix.overlay; }
        // lib.optionalAttrs (isNonEmptyString (prefix.peerSite or null)) { peerSite = prefix.peerSite; })
      prefixes;
  defaultReachabilityVia =
    family: via:
    let
      dst = if family == 4 then "0.0.0.0/0" else "::/0";
      viaField = if family == 4 then "via4" else "via6";
    in
    if !isNonEmptyString via then [ ] else [{
      inherit dst family;
      proto = "default";
      intent = { kind = "default-reachability"; };
      ${viaField} = via;
    }];
in
{
  inherit delegatedOverlayDefaultRoutes defaultReachabilityVia defaultViaRoutes;
  inherit overlayEndpointRoutesVia overlayNodeRoutesVia;
  inherit (prefixRoutes)
    delegatedOverlayAuthorityDefaults
    delegatedOverlayDefaultsVia
    delegatedOverlayExitDefaultsVia
    overlayPeerTenantRoutes
    overlayRuntimeRoutedPrefixRoutes
    overlayRuntimeRoutedPrefixRoutesVia
    ;
  inherit underlayEndpointRoutes withoutGenericOverlayDefaults;
}
