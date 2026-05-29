{
  lib,
  helpers,
  common,
  overlayProvisioning,
  overlayUnderlayEndpoints,
  defaultViaFor,
  interfaceOverlayLaneNames,
  p2pPeerAddress,
  addOverlayNodeRoutesToSelector,
  addOverlayNodeRoutesToCoreOverlay,
  addOverlayUnderlayEndpointRoutesToCore,
  addDelegatedOverlayDefaultRoutesToCore,
  addRuntimePrefixReturnsToCoreOverlay,
  addRuntimePrefixReturnsToWanCore,
  underlayEndpointRoutes,
  delegatedOverlayDefaultsVia,
  delegatedOverlayExitDefaultsVia,
  accessOverlayDefaults,
  overlayIngressPolicyDefaults,
}:

let
  inherit (helpers) isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty mergeRoutes;

  defaultDst = family: if family == 4 then "0.0.0.0/0" else "::/0";

  peerReturnPrefixes =
    lib.unique (
      lib.concatMap
        (
          overlayName:
          (listOrEmpty (overlayProvisioning.${overlayName}.peerTenantPrefixes or null))
          ++ (listOrEmpty (overlayProvisioning.${overlayName}.peerRuntimeRoutedPrefixes or null))
        )
        (builtins.attrNames overlayProvisioning)
    );

  policyUplinkReturnRoutesVia =
    family: lane: via:
    let
      viaField = if family == 4 then "via4" else "via6";
      prefixes = builtins.filter
        (
          prefix:
          (prefix.family or null) == family
          && (isNonEmptyString (prefix.dst or null) || isNonEmptyString (prefix.sourceFile or null))
        )
        peerReturnPrefixes;
    in
    if !isNonEmptyString via then
      [ ]
    else
      builtins.map
        (
          prefix:
          let
            isRuntimePrefix = isNonEmptyString (prefix.sourceFile or null);
          in
          {
            inherit family;
            lane = {
              access = lane.access or null;
              uplink = lane.uplink or null;
            };
            policyOnly = true;
            proto = "internal";
            reason = "policy-table-overlay-return";
            intent = {
              kind = if isRuntimePrefix then "runtime-routed-prefix-return" else "overlay-reachability";
              source = if isRuntimePrefix then "intent-routed-prefix" else "peer-tenant-prefix";
              policyTableComplement = true;
            };
            ${viaField} = via;
          }
          // (if isNonEmptyString (prefix.dst or null) then { inherit (prefix) dst; } else { })
          // (if isNonEmptyString (prefix.sourceFile or null) then { inherit (prefix) sourceFile; } else { })
          // (if isNonEmptyString (prefix.tenantName or prefix.tenant or null) then {
            tenant = prefix.tenantName or prefix.tenant;
          } else { })
        )
        prefixes;

  hasScopedDefault =
    family: routes:
    builtins.any (
      route:
      (route.dst or null) == defaultDst family
      && (route.policyOnly or false) == true
      && ((route.intent or { }).kind or null) == "default-reachability"
      && ((route.lane or null) != null || (route.sourceFile or null) != null)
    ) routes;

  withoutUnscopedDefault =
    family: routes:
    builtins.filter (
      route:
      !(
        (route.dst or null) == defaultDst family
        && ((route.intent or { }).kind or null) == "default-reachability"
        && ((route.lane or null) == null)
        && ((route.sourceFile or null) == null)
      )
    ) routes;

  cleanDefaultsWhenScoped =
    family: routes:
    let
      existingRoutes = listOrEmpty (routes."ipv${builtins.toString family}" or null);
    in
    if hasScopedDefault family existingRoutes then
      withoutUnscopedDefault family existingRoutes
    else
      existingRoutes;

in
nodeRole: interfaces:
let
  selectorDefaultVia4 = defaultViaFor 4 interfaces;
  selectorDefaultVia6 = defaultViaFor 6 interfaces;
  coreInterfaces = addRuntimePrefixReturnsToWanCore nodeRole (
    addRuntimePrefixReturnsToCoreOverlay nodeRole (
      addDelegatedOverlayDefaultRoutesToCore nodeRole (
        addOverlayUnderlayEndpointRoutesToCore nodeRole (
          addOverlayNodeRoutesToCoreOverlay nodeRole (addOverlayNodeRoutesToSelector nodeRole interfaces)
        )
      )
    )
  );
in
if nodeRole != "upstream-selector" || overlayUnderlayEndpoints == [ ] then
  coreInterfaces
else
  lib.mapAttrs (
    _: iface:
    let
      lane = ((iface.backingRef or { }).lane or { });
      laneOverlayNames = builtins.filter (name: builtins.elem name (sortedNames overlayProvisioning)) (
        interfaceOverlayLaneNames iface
      );
      routes = attrsOrEmpty (iface.routes or null);
      policyDefaults = builtins.filter (
        route:
        (route.policyOnly or false) == true
        && ((route.intent or { }).kind or null) == "default-reachability"
      ) ((listOrEmpty (routes.ipv4 or null)) ++ (listOrEmpty (routes.ipv6 or null)));
      peer4 = p2pPeerAddress 4 (iface.addr4 or null);
      peer6 = p2pPeerAddress 6 (iface.addr6 or null);
      accessDefaults = accessOverlayDefaults iface coreInterfaces;
      overlayIngressDefaults = overlayIngressPolicyDefaults iface coreInterfaces;
      policyUplinkReturns =
        if
          (iface.sourceKind or null) == "p2p"
          && (lane.kind or null) == "access-uplink"
          && !(builtins.hasAttr (lane.uplink or "") overlayProvisioning)
        then
          {
            ipv4 = policyUplinkReturnRoutesVia 4 lane peer4;
            ipv6 = policyUplinkReturnRoutesVia 6 lane peer6;
          }
        else
          {
            ipv4 = [ ];
            ipv6 = [ ];
          };
      delegatedDefaults =
        if (iface.sourceKind or null) == "p2p" && laneOverlayNames != [ ] then
          {
            ipv4 =
              if overlayIngressDefaults.ipv4 != [ ] then
                [ ]
              else if policyDefaults != [ ] then
                delegatedOverlayExitDefaultsVia 4 peer4
              else
                delegatedOverlayDefaultsVia 4 laneOverlayNames selectorDefaultVia4;
            ipv6 =
              if overlayIngressDefaults.ipv6 != [ ] then
                [ ]
              else if policyDefaults != [ ] then
                delegatedOverlayExitDefaultsVia 6 peer6
              else
                delegatedOverlayDefaultsVia 6 laneOverlayNames selectorDefaultVia6;
          }
        else
          {
            ipv4 = [ ];
            ipv6 = [ ];
          };
      extraRoutes = {
        ipv4 =
          (underlayEndpointRoutes 4 routes)
          ++ delegatedDefaults.ipv4
          ++ accessDefaults.ipv4
          ++ overlayIngressDefaults.ipv4
          ++ policyUplinkReturns.ipv4;
        ipv6 =
          (underlayEndpointRoutes 6 routes)
          ++ delegatedDefaults.ipv6
          ++ accessDefaults.ipv6
          ++ overlayIngressDefaults.ipv6
          ++ policyUplinkReturns.ipv6;
      };
      finalRoutes = mergeRoutes routes extraRoutes;
      cleanedRoutes = finalRoutes // {
        ipv4 = cleanDefaultsWhenScoped 4 finalRoutes;
        ipv6 = cleanDefaultsWhenScoped 6 finalRoutes;
      };
    in
    if extraRoutes.ipv4 == [ ] && extraRoutes.ipv6 == [ ] then
      iface
    else
      iface // { routes = cleanedRoutes; }
  ) coreInterfaces
