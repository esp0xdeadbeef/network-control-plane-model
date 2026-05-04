{ }:

let
  matches = pattern: value:
    builtins.isString value && builtins.match pattern value != null;

  containsToken = token: value:
    matches ".*${token}.*" value;

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

  suffixAfter =
    prefix: value:
    let
      parts = builtins.match "${prefix}(.+)" value;
    in
    if parts == null then null else builtins.elemAt parts 0;

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
        builtins.filter (iface: matches "access-.+" iface.runtimeIfName) transitInterfaces;
      policyInterfaces =
        builtins.filter (iface: matches "policy-.+" iface.runtimeIfName) transitInterfaces;
      policyForAccess = accessIface:
        let
          suffix = suffixAfter "access-" accessIface.runtimeIfName;
          matchesPolicy =
            builtins.filter
              (policyIface: policyIface.runtimeIfName == "policy-${suffix}")
              policyInterfaces;
        in
        if suffix == null || matchesPolicy == [ ] then null else builtins.elemAt matchesPolicy 0;
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
      selectorIfaceName = iface:
        "${iface.runtimeIfName} ${iface.sourceInterfaceName}";
      coreInterfaces =
        builtins.filter (iface: matches "core.*" iface.runtimeIfName) transitInterfaces;
      policyInterfaces =
        builtins.filter (iface: !(matches "core.*" iface.runtimeIfName)) transitInterfaces;
      coreTransitRules = buildMeshRules coreInterfaces;

      firstMatchingCore = predicate:
        let
          matchesCore = builtins.filter predicate coreInterfaces;
        in
        if matchesCore == [ ] then null else builtins.elemAt matchesCore 0;

      coreForPolicy = policyIface:
        let
          name = selectorIfaceName policyIface;
          wantsOverlay =
            containsToken "ew" name
            || containsToken "storage" name
            || containsToken "sto" name;
          wantsA =
            containsToken "isp-a" name
            || matches ".*-a$" name;
          wantsB =
            containsToken "isp-b" name
            || matches ".*-b$" name;
          wantsWan = containsToken "wan" name;
        in
        if wantsOverlay then
          firstMatchingCore (coreIface: containsToken "nebula" (selectorIfaceName coreIface))
        else if wantsA then
          let
            exact = firstMatchingCore (coreIface: coreIface.runtimeIfName == "core-a");
          in
          if exact != null then exact else firstMatchingCore (coreIface: containsToken "isp" (selectorIfaceName coreIface))
        else if wantsB then
          let
            exact = firstMatchingCore (coreIface: coreIface.runtimeIfName == "core-b");
          in
          if exact != null then exact else firstMatchingCore (coreIface: containsToken "isp" (selectorIfaceName coreIface))
        else if wantsWan then
          let
            plain = firstMatchingCore (coreIface: coreIface.runtimeIfName == "core");
          in
          if plain != null then plain else firstMatchingCore (coreIface: containsToken "isp" (selectorIfaceName coreIface))
        else
          null;
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
