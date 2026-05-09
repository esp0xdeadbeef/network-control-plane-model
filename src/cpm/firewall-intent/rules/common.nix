{ }:

let
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };

  backingRef = iface: attrsOrEmpty (iface.backingRef or { });

  lane = iface: attrsOrEmpty ((backingRef iface).lane or { });
in
{
  laneKind = iface: (lane iface).kind or null;

  laneAccess = iface: (lane iface).access or null;

  laneUplink = iface: (lane iface).uplink or null;

  uplinks = iface:
    let
      ref = backingRef iface;
      laneValue = lane iface;
    in
    builtins.filter (uplink: uplink != null) (
      (ref.uplinks or [ ])
      ++ (laneValue.uplinks or [ ])
      ++ (if (laneValue.uplink or null) == null then [ ] else [ laneValue.uplink ])
    );

  selectorPairRule = fromIface: toIface: [
    {
      action = "accept";
      fromInterface = fromIface.runtimeIfName;
      toInterface = toIface.runtimeIfName;
      applyTcpMssClamp = true;
    }
    {
      action = "accept";
      fromInterface = toIface.runtimeIfName;
      toInterface = fromIface.runtimeIfName;
      applyTcpMssClamp = false;
    }
  ];
}
