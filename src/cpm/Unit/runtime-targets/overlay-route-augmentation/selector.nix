{ lib
, helpers
, overlayProvisioning
, runtimePrefixExitNodes
, p2pPeerAddress
, defaultReachabilityVia
,
}:
let
  inherit (helpers) hasAttr sortedNames;

  overlayPeerViaFor =
    family: overlayName: interfaces:
    let
      addrField = if family == 4 then "addr4" else "addr6";
      candidates =
        lib.concatMap
          (
            ifName:
            let
              iface = interfaces.${ifName};
              lane = ((iface.backingRef or { }).lane or { });
            in
            if (iface.sourceKind or null) == "p2p" && (lane.kind or null) == "uplink" && (lane.uplink or null) == overlayName then
              [ (p2pPeerAddress family (iface.${addrField} or null)) ]
            else
              [ ]
          )
          (sortedNames interfaces);
    in
    if candidates == [ ] then null else builtins.head candidates;

  policyPeerViaFor =
    family: overlayName: interfaces:
    let
      addrField = if family == 4 then "addr4" else "addr6";
      candidates =
        lib.concatMap
          (
            ifName:
            let
              iface = interfaces.${ifName};
              lane = ((iface.backingRef or { }).lane or { });
            in
            if (iface.sourceKind or null) == "p2p" && (lane.kind or null) == "access-uplink" && (lane.uplink or null) == overlayName then
              [ (p2pPeerAddress family (iface.${addrField} or null)) ]
            else
              [ ]
          )
          (sortedNames interfaces);
    in
    if candidates == [ ] then null else builtins.head candidates;

  policyDefaultVia =
    family: accessNode: uplink: via:
    builtins.map
      (route:
      route
      // {
        policyOnly = true;
        metric = 2000;
        reason = "policy-derived-default";
        lane = { access = accessNode; inherit uplink; };
      })
      (defaultReachabilityVia family via);

  overlayIngressPolicyDefaults =
    iface: interfaces:
    let
      lane = ((iface.backingRef or { }).lane or { });
      uplinkName = lane.uplink or null;
      enabled = (lane.kind or null) == "uplink" && hasAttr uplinkName overlayProvisioning;
    in
    if !enabled then
      { ipv4 = [ ]; ipv6 = [ ]; }
    else
      {
        ipv4 = policyDefaultVia 4 null uplinkName (policyPeerViaFor 4 uplinkName interfaces);
        ipv6 = policyDefaultVia 6 null uplinkName (policyPeerViaFor 6 uplinkName interfaces);
      };

  overlayPolicyLaneDefaults =
    iface:
    let
      lane = ((iface.backingRef or { }).lane or { });
      accessNode = lane.access or null;
      uplinkName = lane.uplink or null;
      enabled = (lane.kind or null) == "access-uplink" && hasAttr uplinkName overlayProvisioning;
    in
    if !enabled then
      { ipv4 = [ ]; ipv6 = [ ]; }
    else
      {
        ipv4 = policyDefaultVia 4 accessNode uplinkName (p2pPeerAddress 4 (iface.addr4 or null));
        ipv6 = policyDefaultVia 6 accessNode uplinkName (p2pPeerAddress 6 (iface.addr6 or null));
      };

  accessOverlayDefaults =
    iface: interfaces:
    let
      lane = ((iface.backingRef or { }).lane or { });
      accessNode = lane.access or null;
      uplinkName = lane.uplink or null;
      enabled =
        (lane.kind or null) == "access-uplink"
        && builtins.elem accessNode runtimePrefixExitNodes
        && hasAttr uplinkName overlayProvisioning;
    in
    if !enabled then
      { ipv4 = [ ]; ipv6 = [ ]; }
    else
      {
        ipv4 = policyDefaultVia 4 accessNode uplinkName (overlayPeerViaFor 4 uplinkName interfaces);
        ipv6 = policyDefaultVia 6 accessNode uplinkName (overlayPeerViaFor 6 uplinkName interfaces);
      };
in
{
  inherit accessOverlayDefaults overlayIngressPolicyDefaults overlayPolicyLaneDefaults;
}
