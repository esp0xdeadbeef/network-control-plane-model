{ lib, helpers, cpmData }:

let
  inherit (helpers) isNonEmptyString sortedNames;
  common = import ../lib/common.nix { inherit helpers; };
  inherit (common) attrsOrEmpty uniqueStrings;
in
{
  forTarget =
    overlayName: entry:
    let
      siteData = attrsOrEmpty ((attrsOrEmpty cpmData.${entry.enterpriseName}).${entry.siteName} or null);
      overlay = attrsOrEmpty ((attrsOrEmpty (siteData.overlays or null)).${overlayName} or null);
      overlayNodes = attrsOrEmpty (overlay.nodes or null);
      logicalNode = attrsOrEmpty (entry.target.logicalNode or null);
      nodeName = if isNonEmptyString (logicalNode.name or null) then logicalNode.name else null;
      overlayNode = if nodeName != null then attrsOrEmpty (overlayNodes.${nodeName} or null) else { };
    in
    uniqueStrings (
      lib.optional (isNonEmptyString (overlayNode.addr4 or null)) overlayNode.addr4
      ++ lib.optional (isNonEmptyString (overlayNode.addr6 or null)) overlayNode.addr6
    );

  forEnterprise =
    enterpriseName: overlayName:
    let
      enterpriseSites = attrsOrEmpty (cpmData.${enterpriseName} or null);
    in
    uniqueStrings (
      builtins.concatLists (
        builtins.map
          (siteName:
          let
            siteData = attrsOrEmpty (enterpriseSites.${siteName} or null);
            overlay = attrsOrEmpty ((attrsOrEmpty (siteData.overlays or null)).${overlayName} or null);
            nodes = attrsOrEmpty (overlay.nodes or null);
          in
          builtins.concatLists (
            builtins.map
              (nodeName:
              let node = attrsOrEmpty (nodes.${nodeName} or null);
              in
              lib.optional (isNonEmptyString (node.addr4 or null)) node.addr4
              ++ lib.optional (isNonEmptyString (node.addr6 or null)) node.addr6)
              (sortedNames nodes)
          ))
          (sortedNames enterpriseSites)
      )
    );
}
