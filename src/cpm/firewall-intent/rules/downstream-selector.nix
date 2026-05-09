{ common }:

transitInterfaces:
let
  accessInterfaces =
    builtins.filter
      (iface: common.laneKind iface == "access-edge" && common.laneAccess iface != null)
      transitInterfaces;

  policyInterfaces =
    builtins.filter
      (iface: common.laneKind iface == "access" && common.laneAccess iface != null)
      transitInterfaces;

  policyForAccess = accessIface:
    let
      matchesPolicy =
        builtins.filter
          (policyIface: common.laneAccess policyIface == common.laneAccess accessIface)
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
      if policyIface == null then [ ] else common.selectorPairRule accessIface policyIface)
    accessInterfaces
)
