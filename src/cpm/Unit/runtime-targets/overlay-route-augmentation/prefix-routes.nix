{ lib
, helpers
, common
, overlayProvisioning
, runtimePrefixExitNodes
,
}:
let
  inherit (helpers) isNonEmptyString;
  inherit (common) listOrEmpty;
in
{
  # FS-171 (single writer): the forwarding model is the authoritative writer of
  # the overlay peer route set.  It emits `overlayReachability.<overlay>.
  # routes4/routes6` from the overlay's MODELED imported prefixes (URS:
  # "Overlay transport shall model endpoint identity, permitted peers, bootstrap
  # dependencies, imported and exported prefixes, ..."), each record carrying
  # the concrete peer-site identity (FS-460), and those entries already reach
  # the runtime target as interface routes.  The control plane model consumes
  # that set; it must not synthesize a second copy here.  A second writer for
  # the same route meaning is a duplicate-owner defect (FS-171) and produced
  # duplicate overlay routes (FS-315).
  overlayPeerTenantRoutes =
    _overlayName: [ ];

  overlayRuntimeRoutedPrefixRoutesVia =
    overlayNamesForInterface: via:
    let
      prefixes = lib.unique (lib.concatMap (overlayName: listOrEmpty (overlayProvisioning.${overlayName}.peerRuntimeRoutedPrefixes or null)) overlayNamesForInterface);
    in
    if !isNonEmptyString via then [ ] else
    builtins.map
      (prefix: prefix // {
        proto = "overlay";
        intent = {
          kind = "runtime-routed-prefix-return";
          source = "intent-routed-prefix";
        };
        via6 = via;
      })
      prefixes;

  delegatedOverlayDefaultsVia =
    family: overlayNamesForInterface: via:
    let
      dst = if family == 4 then "0.0.0.0/0" else "::/0";
      viaField = if family == 4 then "via4" else "via6";
      prefixes = lib.unique (lib.concatMap (overlayName: listOrEmpty (overlayProvisioning.${overlayName}.peerRuntimeRoutedPrefixes or null)) overlayNamesForInterface);
    in
    if !isNonEmptyString via || prefixes == [ ] then [ ] else
    builtins.map
      (prefix: {
        inherit dst family;
        policyOnly = true;
        proto = "default";
        intent = {
          kind = "delegated-public-egress";
          source = "intent-routed-prefix";
        };
        ${viaField} = via;
      }
      // (if isNonEmptyString (prefix.sourceFile or null) then { sourceFile = prefix.sourceFile; } else { })
      // (if isNonEmptyString (prefix.tenant or null) then { tenant = prefix.tenant; } else { }))
      prefixes;

  delegatedOverlayAuthorityDefaults =
    family: overlayName: runtimeNode:
    let
      dst = if family == 4 then "0.0.0.0/0" else "::/0";
      overlay = if isNonEmptyString overlayName then overlayProvisioning.${overlayName} or { } else { };
      runtimeNodeCfg =
        if isNonEmptyString runtimeNode then
          let
            allNodes =
              builtins.foldl'
                (acc: k:
                  let
                    v = overlay.${k} or null;
                  in
                    if builtins.isAttrs v && builtins.isAttrs (v.runtimeNodes or null) then
                      acc // v.runtimeNodes
                    else
                      acc)
                (overlay.runtimeNodes or { })
                (builtins.attrNames overlay);
          in
            allNodes.${runtimeNode} or { }
        else
          { };
      unsafeRoutes = listOrEmpty (runtimeNodeCfg.unsafeRoutes or null);
      routeInstalled = route: (route.install or true) != false;
      hasRoute = routeDst:
        builtins.any
          (route: routeInstalled route && (route.route or null) == routeDst)
          unsafeRoutes;
      hasAuthority =
        if family == 4 then
          hasRoute "0.0.0.0/0" || (hasRoute "0.0.0.0/1" && hasRoute "128.0.0.0/1")
        else
          hasRoute "::/0" || (hasRoute "::/1" && hasRoute "8000::/1");
    in
    if !isNonEmptyString overlayName || !isNonEmptyString runtimeNode || !hasAuthority then [ ] else
    builtins.map
      (exitNode: {
        inherit dst family;
        overlay = overlayName;
        policyOnly = true;
        proto = "overlay";
        scope = "link";
        intent = {
          kind = "delegated-public-egress";
          inherit exitNode;
        };
      })
      runtimePrefixExitNodes;

  delegatedOverlayExitDefaultsVia =
    family: via:
    let
      dst = if family == 4 then "0.0.0.0/0" else "::/0";
      viaField = if family == 4 then "via4" else "via6";
    in
    if !isNonEmptyString via then [ ] else
    builtins.map
      (exitNode: {
        inherit dst family;
        policyOnly = true;
        proto = "default";
        intent = {
          kind = "delegated-public-egress";
          inherit exitNode;
        };
        ${viaField} = via;
      })
      runtimePrefixExitNodes;

  overlayRuntimeRoutedPrefixRoutes =
    overlayName:
    builtins.map
      (prefix:
      prefix
      // {
        proto = "overlay";
        intent = {
          kind = "runtime-routed-prefix-return";
          source = "intent-routed-prefix";
        };
      })
      (listOrEmpty (overlayProvisioning.${overlayName}.peerRuntimeRoutedPrefixes or null));
}
