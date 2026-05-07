{
  lib,
  helpers,
  common,
  sitePath,
  runtimeTargetNames,
  runtimeTargetsByNode,
  runtimeTargetsWithSynthesizedDefaults,
}:

let
  inherit (helpers) hasAttr isNonEmptyString requireAttrs sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty;
  p2pPeers = import ../../ControlModule/route-augmentation/p2p-peers.nix { inherit lib; };

  prefixesForAccessNode =
    accessNode:
    if !hasAttr accessNode runtimeTargetsByNode then
      { ipv4 = [ ]; ipv6 = [ ]; }
    else
      let
        target = runtimeTargetsByNode.${accessNode}.target;
        networks = attrsOrEmpty (target.networks or null);
        networkValues = map (name: attrsOrEmpty networks.${name}) (sortedNames networks);
      in
      {
        ipv4 = builtins.filter isNonEmptyString (map (network: network.ipv4 or null) networkValues);
        ipv6 = builtins.filter isNonEmptyString (map (network: network.ipv6 or null) networkValues);
      };

  hasRoute = family: routes: dst:
    builtins.any (route: builtins.isAttrs route && (route.dst or null) == dst) (listOrEmpty routes);

  routeFor = family: accessNode: peer: dst:
    {
      inherit dst;
      intent = {
        kind = "internal-reachability";
        source = "access-uplink-prefix";
        node = accessNode;
      };
      proto = "internal";
    }
    // {
      ${if family == 4 then "via4" else "via6"} = peer;
    };

  peerForPolicyAccess =
    family: accessNode: interfaces:
    let
      candidates =
        lib.filterAttrs
          (_: candidate:
            let
              lane = attrsOrEmpty ((attrsOrEmpty (candidate.backingRef or null)).lane or null);
            in
            (lane.kind or null) == "access" && (lane.access or null) == accessNode)
          interfaces;
      names = sortedNames candidates;
    in
    if names == [ ] then null else p2pPeers.peerForInterface family candidates.${builtins.head names};

  addFamilyRoutes = family: targetRole: interfaces: accessNode: iface: existing:
    let
      policyAccessPeer = peerForPolicyAccess family accessNode interfaces;
      peer =
        if targetRole == "policy" && isNonEmptyString policyAccessPeer then
          policyAccessPeer
        else
          p2pPeers.peerForInterface family iface;
      prefixes = if family == 4 then (prefixesForAccessNode accessNode).ipv4 else (prefixesForAccessNode accessNode).ipv6;
    in
    if !isNonEmptyString peer then
      existing
    else
      builtins.foldl'
        (acc: dst: if hasRoute family acc dst then acc else acc ++ [ (routeFor family accessNode peer dst) ])
        existing
        prefixes;

  addForInterface = targetPath: targetRole: interfaces: iface:
    let
      backingRef = attrsOrEmpty (iface.backingRef or null);
      lane = attrsOrEmpty (backingRef.lane or null);
      accessNode = lane.access or null;
      routes = attrsOrEmpty (iface.routes or null);
      existing4 = listOrEmpty (routes.ipv4 or null);
      existing6 = listOrEmpty (routes.ipv6 or null);
      updated4 = addFamilyRoutes 4 targetRole interfaces accessNode iface existing4;
      updated6 = addFamilyRoutes 6 targetRole interfaces accessNode iface existing6;
    in
    if (lane.kind or null) != "access-uplink" || !isNonEmptyString accessNode then
      iface
    else
      iface // { routes = routes // { ipv4 = updated4; ipv6 = updated6; }; };

  addForTarget = targetName: target:
    let
      targetPath = "${sitePath}.runtimeTargets.${targetName}";
      targetRole = target.role or null;
      effective = requireAttrs "${targetPath}.effectiveRuntimeRealization" (target.effectiveRuntimeRealization or null);
      interfaces = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces" (effective.interfaces or null);
      updatedInterfaces =
        builtins.mapAttrs (_: iface: addForInterface targetPath targetRole interfaces iface) interfaces;
    in
    target // { effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; }; };

in
{
  runtimeTargetsWithAccessUplinkPrefixes =
    builtins.listToAttrs (
      map (targetName: {
        name = targetName;
        value = addForTarget targetName runtimeTargetsWithSynthesizedDefaults.${targetName};
      }) runtimeTargetNames
    );
}
