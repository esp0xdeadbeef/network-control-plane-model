{ common }:

{
  transitInterfaces,
  relations ? [ ],
}:
let
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  listOrEmpty = value: if builtins.isList value then value else [ ];

  coreInterfaces =
    builtins.filter
      (iface: common.uplinks iface != [ ] && common.laneKind iface == "uplink")
      transitInterfaces;

  policyInterfaces =
    builtins.filter
      (iface: common.laneKind iface == "access-uplink" && common.laneUplink iface != null)
      transitInterfaces;

  coreForPolicy = policyIface:
    let
      matchesCore =
        builtins.filter
          (coreIface: builtins.elem (common.laneUplink policyIface) (common.uplinks coreIface))
          coreInterfaces;
    in
    if matchesCore == [ ] then null else builtins.elemAt matchesCore 0;

  externalUplinks = endpoint:
    let
      value = attrsOrEmpty endpoint;
    in
    if (value.kind or null) != "external" then
      [ ]
    else
      (listOrEmpty (value.uplinks or null))
      ++ (if value ? name then [ value.name ] else [ ]);

  coreInterfacesFor = endpoint:
    let
      wanted = externalUplinks endpoint;
    in
    builtins.filter
      (iface: builtins.any (uplink: builtins.elem uplink (common.uplinks iface)) wanted)
      coreInterfaces;

  externalTransitRule = relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      fromCores = coreInterfacesFor (relation.from or null);
      toCores = coreInterfacesFor (relation.to or null);
      trafficType = relation.trafficType or "any";
      action = relation.action or "allow";
    in
    if action != "allow" || trafficType == "any" then
      [ ]
    else
      builtins.concatLists (
        builtins.map
          (fromIface:
            builtins.map
              (toIface: {
                action = "accept";
                relationId = relation.id or null;
                priority = relation.priority or null;
                inherit trafficType;
                from = attrsOrEmpty (relation.from or null);
                to = attrsOrEmpty (relation.to or null);
                fromInterface = fromIface.runtimeIfName;
                toInterface = toIface.runtimeIfName;
                applyTcpMssClamp = false;
              })
              toCores)
          fromCores
      );
in
  (builtins.concatLists (
    builtins.map
      (policyIface:
        let
          coreIface = coreForPolicy policyIface;
        in
        if coreIface == null then [ ] else common.selectorPairRule policyIface coreIface)
      policyInterfaces
  ))
  ++ (builtins.concatLists (builtins.map externalTransitRule relations))
