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
