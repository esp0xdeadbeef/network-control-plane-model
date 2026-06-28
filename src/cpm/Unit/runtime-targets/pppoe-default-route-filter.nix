{ sortedNames }:

{
  filter =
    {
      targetId,
      nodeName,
      nodePath,
      pppoeLinkNames,
      ifaces,
    }:
    let
      isPppoeLink = iface:
        (iface.sourceKind or "") == "p2p"
        && builtins.hasAttr (iface.backingRef.name or "") pppoeLinkNames;
      defaultRoutesFor = routes:
        builtins.filter
          (r: ((r.intent or { }).kind or "") == "default-reachability")
          routes;
      routeDiagnostic = ifaceName: iface: family: route:
        {
          gampId = "FS-800-HDS-010-SDS-013-SMS-020";
          code = "pppoe-p2p-default-reachability-stripped";
          severity = "fatal";
          mode = "fail-closed";
          target = targetId;
          logicalNode = nodeName;
          interface = ifaceName;
          addressFamily = family;
          sourceKind = "p2p";
          sourceLocation = "${nodePath}.interfaces.${ifaceName}.routes.${family}";
          reason = "default-reachability is not allowed on PPPoE core p2p handoff interfaces";
          backingRef = iface.backingRef or null;
          route = {
            dst = route.dst or null;
            proto = route.proto or null;
            intent = route.intent or { };
          }
          // (if family == "ipv4" then { via = route.via4 or null; } else { via = route.via6 or null; });
        };
      diagnosticsForIface = ifaceName: iface:
        if isPppoeLink iface then
          let
            routes = iface.routes or { };
            ipv4 = defaultRoutesFor (routes.ipv4 or [ ]);
            ipv6 = defaultRoutesFor (routes.ipv6 or [ ]);
          in
          (builtins.map (route: routeDiagnostic ifaceName iface "ipv4" route) ipv4)
          ++ (builtins.map (route: routeDiagnostic ifaceName iface "ipv6" route) ipv6)
        else
          [ ];
      stripDefaultRoutes = iface:
        let
          routes = iface.routes or { };
          ipv4 = builtins.filter
            (r: ((r.intent or { }).kind or "") != "default-reachability")
            (routes.ipv4 or [ ]);
          ipv6 = builtins.filter
            (r: ((r.intent or { }).kind or "") != "default-reachability")
            (routes.ipv6 or [ ]);
        in
        iface // { routes = routes // { inherit ipv4 ipv6; }; };
    in
    {
      interfaces = builtins.mapAttrs (_: iface:
        if isPppoeLink iface then stripDefaultRoutes iface else iface
      ) ifaces;
      diagnostics = builtins.concatLists (
        builtins.map
          (ifaceName: diagnosticsForIface ifaceName ifaces.${ifaceName})
          (sortedNames ifaces)
      );
    };
}
