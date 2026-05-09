{ common }:

transitInterfaces:
let
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
in
builtins.concatLists (
  builtins.map
    (policyIface:
      let
        coreIface = coreForPolicy policyIface;
      in
      if coreIface == null then [ ] else common.selectorPairRule policyIface coreIface)
    policyInterfaces
)
