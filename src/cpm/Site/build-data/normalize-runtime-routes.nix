{
  lib,
  common,
  overlayNames ? [ ],
  attachments ? [ ],
  routedPrefixesByTenant ? { },
}:

let
  inherit (common) attrsOrEmpty listOrEmpty;

  routeKey =
    family: route:
    if !builtins.isAttrs route then
      null
    else
      builtins.toJSON {
        inherit family;
        dst = route.dst or null;
        intent = route.intent or null;
        lane = route.lane or null;
        metric = route.metric or null;
        policyOnly = route.policyOnly or null;
        proto = route.proto or null;
        reason = route.reason or null;
        table = route.table or null;
        sourceFile = route.sourceFile or null;
        via4 = route.via4 or null;
        via6 = route.via6 or null;
        scope = route.scope or null;
      };

  uniqueRoutes =
    family: routes:
    (builtins.foldl'
      (acc: route:
        let key = routeKey family route;
        in
        if key == null || builtins.hasAttr key acc.seen then
          acc
        else
          {
            seen = acc.seen // { ${key} = true; };
            values = acc.values ++ [ route ];
          })
      { seen = { }; values = [ ]; }
      routes).values;

  defaultDst = family: if family == 4 then "0.0.0.0/0" else "::/0";
  rolesWithPolicyDefaults = {
    downstream-selector = true;
    policy = true;
    upstream-selector = true;
  };
  runtimePrefixExitNodes =
    lib.unique (
      lib.concatMap
        (
          tenantName:
          builtins.map
            (attachment: attachment.unit)
            (
              builtins.filter
                (
                  attachment:
                  (attachment.kind or null) == "tenant"
                  && (attachment.name or null) == tenantName
                  && builtins.isString (attachment.unit or null)
                )
                attachments
            )
        )
        (
          builtins.filter
            (
              tenantName:
              builtins.any
                (prefix: (prefix.allocation or null) == "runtime" || (prefix.source or null) == "intent-routed-prefix")
                (listOrEmpty (routedPrefixesByTenant.${tenantName} or null))
            )
            (builtins.attrNames routedPrefixesByTenant)
        )
    );

  classifyRoute =
    targetRole: family: route:
    if !builtins.isAttrs route then
      null
    else if
      let
        lane = attrsOrEmpty (route.lane or null);
      in
      family == 6
      && (route.dst or null) == defaultDst family
      && (lane.access or "") != ""
      && builtins.elem (lane.access or "") runtimePrefixExitNodes
      && overlayNames != [ ]
      && !(builtins.elem (lane.uplink or "") overlayNames)
    then
      null
    else if
      builtins.isAttrs route
      && builtins.hasAttr targetRole rolesWithPolicyDefaults
      && (route.dst or null) == defaultDst family
    then
      route
      // {
        policyOnly = true;
        reason = route.reason or "policy-derived-default";
      }
    else
      route;

  hasLanedDefaultWithSameVia =
    family: route: routes:
    let
      viaField = if family == 4 then "via4" else "via6";
    in
    builtins.any
      (
        other:
        builtins.isAttrs other
        && (other.dst or null) == (route.dst or null)
        && (other.${viaField} or null) == (route.${viaField} or null)
        && ((attrsOrEmpty (other.lane or null)).access or "") != ""
      )
      routes;

  dropDuplicateUnlanedDefaults =
    family: routes:
    builtins.filter
      (
        route:
        !(
          builtins.isAttrs route
          && (route.dst or null) == defaultDst family
          && ((route.intent or { }).kind or null) == "default-reachability"
          && ((attrsOrEmpty (route.lane or null)).access or "") == ""
          && hasLanedDefaultWithSameVia family route routes
        )
      )
      routes;

  normalizeRuntimeTargetRoutes =
    target:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
      normalizedInterfaces =
        builtins.mapAttrs
          (_ifName: iface:
            let
              routes = attrsOrEmpty (iface.routes or null);
              targetRole = target.role or "";
              ipv4 = dropDuplicateUnlanedDefaults 4 (builtins.filter (route: route != null) (builtins.map (classifyRoute targetRole 4) (listOrEmpty (routes.ipv4 or null))));
              ipv6 = dropDuplicateUnlanedDefaults 6 (builtins.filter (route: route != null) (builtins.map (classifyRoute targetRole 6) (listOrEmpty (routes.ipv6 or null))));
            in
            if ipv4 == [ ] && ipv6 == [ ] then
              iface
            else
              iface // { routes = routes // { ipv4 = uniqueRoutes 4 ipv4; ipv6 = uniqueRoutes 6 ipv6; }; })
          interfaces;
    in
    if interfaces == { } then target else target // { effectiveRuntimeRealization = effective // { interfaces = normalizedInterfaces; }; };
in
{
  inherit normalizeRuntimeTargetRoutes uniqueRoutes;
}
