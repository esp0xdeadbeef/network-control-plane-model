{ }:

let
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };

  backingRef = iface: attrsOrEmpty (iface.backingRef or { });

  lane = iface: attrsOrEmpty ((backingRef iface).lane or { });

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

  buildMeshRules = transitInterfaces:
    builtins.concatLists (
      builtins.map
        (fromIface:
          builtins.map
            (toIface:
              {
                action = "accept";
                fromInterface = fromIface.runtimeIfName;
                toInterface = toIface.runtimeIfName;
                applyTcpMssClamp = false;
              })
            (builtins.filter
              (toIface: toIface.runtimeIfName != fromIface.runtimeIfName)
              transitInterfaces))
        transitInterfaces
    );
in
{
  buildAccessRules = localInterfaces: transitInterfaces:
    builtins.concatLists (
      builtins.map
        (localIface:
          builtins.concatLists (
            builtins.map
              (transitIface: selectorPairRule localIface transitIface)
              transitInterfaces
          ))
        localInterfaces
    );

  inherit buildMeshRules;

  buildDownstreamSelectorRules = transitInterfaces:
    let
      accessInterfaces =
        builtins.filter (iface: laneKind iface == "access-edge" && laneAccess iface != null) transitInterfaces;
      policyInterfaces =
        builtins.filter (iface: laneKind iface == "access" && laneAccess iface != null) transitInterfaces;
      policyForAccess = accessIface:
        let
          matchesPolicy =
            builtins.filter
              (policyIface: laneAccess policyIface == laneAccess accessIface)
              policyInterfaces;
        in
        if matchesPolicy == [ ] then null else builtins.elemAt matchesPolicy 0;
    in
    builtins.concatLists (
      builtins.map
        (accessIface:
          let
            policyIface = policyForAccess accessIface;
          in
          if policyIface == null then [ ] else selectorPairRule accessIface policyIface)
        accessInterfaces
    );

  buildUpstreamSelectorRules = transitInterfaces:
    let
      coreInterfaces =
        builtins.filter (iface: (uplinks iface) != [ ] && laneKind iface == "uplink") transitInterfaces;
      policyInterfaces =
        builtins.filter (iface: laneKind iface == "access-uplink" && laneUplink iface != null) transitInterfaces;
      coreTransitRules = buildMeshRules coreInterfaces;

      coreForPolicy = policyIface:
        let
          matchesCore = builtins.filter (coreIface: builtins.elem (laneUplink policyIface) (uplinks coreIface)) coreInterfaces;
        in
        if matchesCore == [ ] then null else builtins.elemAt matchesCore 0;
    in
    builtins.concatLists (
      builtins.map
        (policyIface:
          let
            coreIface = coreForPolicy policyIface;
          in
          if coreIface == null then [ ] else selectorPairRule policyIface coreIface)
        policyInterfaces
    )
    ++ coreTransitRules;

  buildExitRules = transitInterfaces: uplinkInterfaces:
    builtins.concatLists (
      builtins.map
        (transitIface:
          builtins.concatLists (
            builtins.map
              (uplinkIface: selectorPairRule transitIface uplinkIface)
              uplinkInterfaces
          ))
        transitInterfaces
    );
}
