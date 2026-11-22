{
  lib,
  attrsOrEmpty,
  listOrEmpty,
  defaultDst,
}:

let
  rolesWithPolicyDefaults = {
    access = true;
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
      builtins.concatLists (
        builtins.map
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
    builtins.concatLists (
      builtins.map (
        ifName:
        let
          routes = attrsOrEmpty (interfaces.${ifName}.routes or null);
        in
        builtins.filter (isPolicyDefault family) (
          listOrEmpty (routes."ipv${builtins.toString family}" or null)
        )
      ) (builtins.attrNames interfaces)
    );

  isPolicyTableComplementSource =
    family: route:
    builtins.isAttrs route
    && (route.policyOnly or false) != true
    && (route.dst or null) != defaultDst family
    && (route.dst or null) != null;

  # FS-315: one (prefix, lane) authority has ONE next-hop set. Several
  # interfaces of one access lane can each carry the same prefix (measured on
  # `single-wan`, `downstream-selector`: 10.20.10.0/24 arrives with lane admin
  # from ens5 and lane mgmt from ens8). Copying every one of them into the lane's
  # policy table installs the same destination twice with different next hops --
  # `ip route replace` keys on (table, destination), so the surviving route is
  # whoever wrote last, and the containerlab renderer refuses the site
  # (FS-310-HDS-020-SDS-010-SMS-060).
  #
  # The complement is therefore built from ONE member per (family, destination,
  # lane access): the member with the lowest next-hop string, so two evaluations
  # agree. This selects a member; it does not delete the base routes, so
  # per-requester-lane reachability (FS-540 ... SMS-040) still sees each lane's
  # own path.
  oneMemberPerLanePrefix =
    family: routes:
    let
      viaField = if family == 4 then "via4" else "via6";
      laneAccessOf = route: (attrsOrEmpty (route.lane or null)).access or null;
      keyOf = route: builtins.toJSON [
        family
        (route.dst or null)
        (laneAccessOf route)
      ];
      viaOf = route: let v = route.${viaField} or null; in if builtins.isString v then v else "";
      grouped = builtins.foldl'
        (acc: route:
          let k = keyOf route;
          in acc // {
            ${k} =
              if builtins.hasAttr k acc
              then (if viaOf route < viaOf acc.${k} then route else acc.${k})
              else route;
          })
        { }
        routes;
    in
    builtins.attrValues grouped;

  policyTableComplements =
    family: defaults: routes:
    builtins.concatLists (
      builtins.map (
        route:
        let
          routeLaneAccess = (attrsOrEmpty (route.lane or null)).access or null;
          # FS-315: a route's policy-table presence is its modeled lane
          # relation. An unlaned route has no lane relation and shall not be
          # copied into any sibling policy lane, so it produces no complement.
          # A laned route is copied only into the defaults on its own lane.
          matching =
            if routeLaneAccess == null then
              [ ]
            else
              builtins.filter (d: (attrsOrEmpty (d.lane or null)).access or null == routeLaneAccess) defaults;
        in
        builtins.map (
          _defaultRoute:
          route
          // {
            # FS-315: the complement keeps the route's own lane relation; it
            # is never reassigned to a sibling lane.
            policyOnly = true;
            reason = "policy-table-internal-reachability";
            intent = (attrsOrEmpty (route.intent or null)) // {
              policyTableComplement = true;
              source = "policy-default-lane";
            };
          }
        ) matching
      ) (oneMemberPerLanePrefix family (builtins.filter (isPolicyTableComplementSource family) routes))
    );
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
