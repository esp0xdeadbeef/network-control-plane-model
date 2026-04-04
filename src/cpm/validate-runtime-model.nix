{ helpers }:

{ cpm }:

let
  inherit (helpers)
    aggregateWarnings
    emitWarnings
    isNonEmptyString
    makeWarning
    sortedNames
    warningIf;

  attrsOrEmpty = value:
    if builtins.isAttrs value then
      value
    else
      { };

  listOrEmpty = value:
    if builtins.isList value then
      value
    else
      [ ];

  startsWith = prefix: value:
    builtins.isString value
    && builtins.stringLength value >= builtins.stringLength prefix
    && builtins.substring 0 (builtins.stringLength prefix) value == prefix;

  isCompatibilityId = value:
    builtins.isString value
    && (
      startsWith "compat::" value
      || builtins.match ".*::unknown::.*" value != null
    );

  collectInterfaceWarnings = sitePath: targetName: ifName: iface:
    let
      ifaceAttrs = attrsOrEmpty iface;
      backingRef = attrsOrEmpty (ifaceAttrs.backingRef or null);
      backingKind = backingRef.kind or null;
      sourceKind = ifaceAttrs.sourceKind or null;
      routes = attrsOrEmpty (ifaceAttrs.routes or null);
      ifaceContext = {
        site = sitePath;
        target = targetName;
        interface = ifName;
        interfaceDefinition = ifaceAttrs;
      };
    in
    (warningIf
      (!isNonEmptyString (ifaceAttrs.runtimeTarget or null)
        || !isNonEmptyString (ifaceAttrs.runtimeIfName or null)
        || !isNonEmptyString (ifaceAttrs.renderedIfName or null))
      (makeWarning
        "invariant/runtime-model/interface-renderer-fields-required"
        "runtime interfaces must carry explicit runtimeTarget, runtimeIfName, and renderedIfName; renderer-side recovery is temporary"
        ifaceContext))
    ++
    (warningIf
      (!builtins.isAttrs (ifaceAttrs.backingRef or null)
        || !builtins.elem backingKind [ "link" "attachment" "overlay" ]
        || !isNonEmptyString (backingRef.id or null))
      (makeWarning
        "invariant/runtime-model/interface-backing-reference-required"
        "runtime interfaces must carry exactly one explicit backing reference with canonical identity; compatibility recovery is temporary"
        ifaceContext))
    ++
    (warningIf
      (!isNonEmptyString sourceKind || sourceKind == "unknown")
      (makeWarning
        "invariant/runtime-model/interface-semantic-kind-required"
        "runtime interfaces must carry explicit semantic kind; renderer-side semantic recovery is temporary"
        ifaceContext))
    ++
    (warningIf
      (sourceKind != "overlay"
        && !(
          isNonEmptyString (ifaceAttrs.addr4 or null)
          || isNonEmptyString (ifaceAttrs.addr6 or null)
        ))
      (makeWarning
        "invariant/runtime-model/interface-addresses-required"
        "runtime interfaces that participate in forwarding semantics must carry explicit addr4 or addr6; null-address recovery is temporary"
        ifaceContext))
    ++
    (warningIf
      (!builtins.isAttrs (ifaceAttrs.routes or null)
        || !builtins.isList (routes.ipv4 or null)
        || !builtins.isList (routes.ipv6 or null))
      (makeWarning
        "invariant/runtime-model/interface-routes-required"
        "runtime interfaces must carry explicit routes; renderer-side route recovery is temporary"
        ifaceContext))
    ++
    (warningIf
      (builtins.isAttrs (ifaceAttrs.backingRef or null)
        && isCompatibilityId (backingRef.id or null))
      (makeWarning
        "invariant/runtime-model/canonical-backing-identity-required"
        "runtime backing references must preserve canonical identity without compatibility ids or unknown placeholders; renderer-side resolution is temporary"
        ifaceContext));

  collectTargetWarnings = sitePath: targetName: target:
    let
      targetAttrs = attrsOrEmpty target;
      placement = attrsOrEmpty (targetAttrs.placement or null);
      effective = attrsOrEmpty (targetAttrs.effectiveRuntimeRealization or null);
      loopback = attrsOrEmpty (effective.loopback or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
      interfaceWarnings =
        builtins.concatLists (
          builtins.map
            (ifName: collectInterfaceWarnings sitePath targetName ifName interfaces.${ifName})
            (sortedNames interfaces)
        );
    in
    (warningIf
      (!isNonEmptyString (targetAttrs.runtimeTargetId or null)
        || !builtins.isAttrs (targetAttrs.placement or null)
        || !isNonEmptyString (placement.kind or null))
      (makeWarning
        "invariant/runtime-model/target-placement-required"
        "runtime targets must carry explicit runtimeTargetId and placement.kind; renderer-side placement recovery is temporary"
        {
          site = sitePath;
          target = targetName;
          targetDefinition = targetAttrs;
        }))
    ++
    (warningIf
      (!builtins.isAttrs (targetAttrs.effectiveRuntimeRealization or null)
        || !builtins.isAttrs (effective.loopback or null)
        || !builtins.isAttrs (effective.interfaces or null))
      (makeWarning
        "invariant/runtime-model/target-runtime-realization-required"
        "runtime targets must carry explicit effectiveRuntimeRealization, loopback, and interfaces; renderer-side reconstruction is temporary"
        {
          site = sitePath;
          target = targetName;
          targetDefinition = targetAttrs;
        }))
    ++
    (warningIf
      (!isNonEmptyString (loopback.addr4 or null)
        || !isNonEmptyString (loopback.addr6 or null)
        || (loopback.addr4 or null) == "0.0.0.0/32"
        || (loopback.addr6 or null) == "::/128")
      (makeWarning
        "invariant/loopback/runtime-loopback-required"
        "runtime targets must carry explicit loopback identities; synthesized loopback defaults are temporary"
        {
          site = sitePath;
          target = targetName;
          loopback = loopback;
        }))
    ++ interfaceWarnings;

  collectSiteWarnings = enterpriseName: siteName: site:
    let
      sitePath = "control_plane_model.data.${enterpriseName}.${siteName}";
      siteAttrs = attrsOrEmpty site;
      runtimeTargets = attrsOrEmpty (siteAttrs.runtimeTargets or null);
      targetNames = sortedNames runtimeTargets;
      targetWarnings =
        builtins.concatLists (
          builtins.map
            (targetName: collectTargetWarnings sitePath targetName runtimeTargets.${targetName})
            targetNames
        );

      routeBearingInterfaces =
        builtins.concatLists (
          builtins.map
            (targetName:
              let
                targetAttrs = attrsOrEmpty runtimeTargets.${targetName};
                effective = attrsOrEmpty (targetAttrs.effectiveRuntimeRealization or null);
                interfaces = attrsOrEmpty (effective.interfaces or null);
              in
              builtins.filter
                (value: value != null)
                (builtins.map
                  (ifName:
                    let
                      iface = attrsOrEmpty interfaces.${ifName};
                      routes = attrsOrEmpty (iface.routes or null);
                      ipv4 = listOrEmpty (routes.ipv4 or null);
                      ipv6 = listOrEmpty (routes.ipv6 or null);
                    in
                    if ipv4 != [ ] || ipv6 != [ ] then
                      {
                        target = targetName;
                        interface = ifName;
                        sourceKind = iface.sourceKind or null;
                        ipv4RouteCount = builtins.length ipv4;
                        ipv6RouteCount = builtins.length ipv6;
                      }
                    else
                      null)
                  (sortedNames interfaces)))
            targetNames
        );

      wanInterfaces =
        builtins.concatLists (
          builtins.map
            (targetName:
              let
                targetAttrs = attrsOrEmpty runtimeTargets.${targetName};
                effective = attrsOrEmpty (targetAttrs.effectiveRuntimeRealization or null);
                interfaces = attrsOrEmpty (effective.interfaces or null);
              in
              builtins.filter
                (value: value != null)
                (builtins.map
                  (ifName:
                    let
                      iface = attrsOrEmpty interfaces.${ifName};
                    in
                    if (iface.sourceKind or null) == "wan" then
                      {
                        target = targetName;
                        interface = ifName;
                        backingRef = iface.backingRef or null;
                      }
                    else
                      null)
                  (sortedNames interfaces)))
            targetNames
        );

      domains = attrsOrEmpty (siteAttrs.domains or null);
      externals = listOrEmpty (domains.externals or null);

      explicitEgress =
        builtins.isAttrs (siteAttrs.egress or null)
        || builtins.isList (siteAttrs.egress or null)
        || builtins.any
          (targetName:
            let
              targetAttrs = attrsOrEmpty runtimeTargets.${targetName};
              effective = attrsOrEmpty (targetAttrs.effectiveRuntimeRealization or null);
            in
            builtins.isAttrs (effective.egress or null)
            || builtins.isList (effective.egress or null))
          targetNames;
    in
    targetWarnings
    ++
    (warningIf
      (routeBearingInterfaces != [ ])
      (makeWarning
        "invariant/semantic-elevation/route-intent-required"
        "route semantic intent is not explicit in CPM; renderers must not derive default, internal, or egress meaning from proto or route patterns"
        {
          site = sitePath;
          interfaces = routeBearingInterfaces;
        }))
    ++
    (warningIf
      ((externals != [ ] || wanInterfaces != [ ]) && !explicitEgress)
      (makeWarning
        "invariant/semantic-elevation/egress-intent-required"
        "egress behavior is not explicit in CPM; renderers must not derive egress from WAN presence, externals, or route shape"
        {
          site = sitePath;
          externals = externals;
          wanInterfaces = wanInterfaces;
        }));

  collectWarnings = cpmAttrs:
    let
      data = attrsOrEmpty (cpmAttrs.data or null);
      enterpriseNames = sortedNames data;
    in
    builtins.concatLists (
      builtins.map
        (enterpriseName:
          let
            sites = attrsOrEmpty data.${enterpriseName};
            siteNames = sortedNames sites;
          in
          builtins.concatLists (
            builtins.map
              (siteName: collectSiteWarnings enterpriseName siteName sites.${siteName})
              siteNames
          ))
        enterpriseNames
    );

  cpmAttrs = attrsOrEmpty cpm;
  warnings = aggregateWarnings (collectWarnings cpmAttrs);
in
emitWarnings warnings true
