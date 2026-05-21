{
  lib,
  attrsOrEmpty,
  listOrEmpty,
  defaultDst,
}:

let
  rolesWithPolicyDefaults = {
    downstream-selector = true;
    policy = true;
    upstream-selector = true;
  };

  runtimePrefixExitNodes =
    {
      attachments,
      routedPrefixesByTenant,
    }:
    lib.unique (
      lib.concatMap
        (
          tenantName:
          builtins.map (attachment: attachment.unit) (
            builtins.filter (
              attachment:
              (attachment.kind or null) == "tenant"
              && (attachment.name or null) == tenantName
              && builtins.isString (attachment.unit or null)
            ) attachments
          )
        )
        (
          builtins.filter (
            tenantName:
            builtins.any (
              prefix:
              (prefix.allocation or null) == "runtime" || (prefix.source or null) == "intent-routed-prefix"
            ) (listOrEmpty (routedPrefixesByTenant.${tenantName} or null))
          ) (builtins.attrNames routedPrefixesByTenant)
        )
    );

  classifyRoute =
    {
      overlayNames,
      runtimeExitNodes,
      targetRole,
    }:
    family: route:
    if !builtins.isAttrs route then
      null
    else if
      builtins.hasAttr targetRole rolesWithPolicyDefaults && (route.dst or null) == defaultDst family
    then
      route
      // {
        policyOnly = true;
        reason = route.reason or "policy-derived-default";
      }
    else
      route;

  policyDefaultRoutes =
    { isPolicyDefault }:
    family: interfaces:
    lib.concatMap (
      ifName:
      let
        routes = attrsOrEmpty (interfaces.${ifName}.routes or null);
      in
      builtins.filter (isPolicyDefault family) (
        listOrEmpty (routes."ipv${builtins.toString family}" or null)
      )
    ) (builtins.attrNames interfaces);

  isPolicyTableComplementSource =
    family: route:
    builtins.isAttrs route
    && (route.policyOnly or false) != true
    && (route.dst or null) != defaultDst family
    && (route.dst or null) != null;

  policyTableComplements =
    family: defaults: routes:
    lib.concatMap (
      route:
      builtins.map (
        defaultRoute:
        route
        // {
          lane = defaultRoute.lane;
          policyOnly = true;
          reason = "policy-table-internal-reachability";
          intent = (attrsOrEmpty (route.intent or null)) // {
            policyTableComplement = true;
            source = "policy-default-lane";
          };
        }
      ) defaults
    ) (builtins.filter (isPolicyTableComplementSource family) routes);
in
{
  inherit
    rolesWithPolicyDefaults
    runtimePrefixExitNodes
    classifyRoute
    policyDefaultRoutes
    policyTableComplements
    ;
}
