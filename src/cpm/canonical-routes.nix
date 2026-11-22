# Canonical routes, published by the producer alongside canonical interfaces.
#
# WHY
# ---
# A renderer that needs route semantics currently has to read the producer's
# model (`control_plane_model` / the bundle's `network.data`), which is exactly
# what `RR_RAW_CPM_INPUT` forbids: `network.data` is the CPM with a validation
# wrapper, so "consume the canonical bundle" and "consume the CPM" were the same
# operation. Interface identity is already published (`canonicalInterfaces`); this
# publishes the route facts a renderer materializes, in one flat, deterministic
# set, so the same information does not have to be re-derived from nested
# per-interface records.
#
# SHAPE
# -----
# One entry per (target, interface, family, table, destination, gateway, metric),
# which is exactly the identity `ip route replace` keys on plus the carrier:
#
#   { target, interface, family, dst, gateway, tableId, metric, kind }
#
# `tableId` is the interface's modelled policy-routing allocation (null when the
# route belongs to the main table); `gateway` is the route's own `via4`/`via6`.
# Entries are deduplicated by that identity, so two paths that would install the
# same command appear once -- the renderer must not have to discover that itself.
{ lib }:
cpm:
let
  enterpriseNames = builtins.attrNames (cpm.data or { });

  targetPairs = builtins.concatMap
    (enterprise:
      let sites = cpm.data.${enterprise} or { }; in
      builtins.concatMap
        (site:
          let targets = cpm.data.${enterprise}.${site}.runtimeTargets or { };
          in map
            (targetName: {
              key = "${enterprise}/${site}/${targetName}";
              inherit targetName;
              target = targets.${targetName};
            })
            (builtins.attrNames targets))
        (builtins.attrNames sites))
    enterpriseNames;

  routeEntries = builtins.concatMap
    (entry:
      let
        interfaces =
          (entry.target.effectiveRuntimeRealization.interfaces or { });
      in
      builtins.concatMap
        (ifaceName:
          let
            iface = interfaces.${ifaceName};
            routes = iface.routes or { };
            tableId = (iface.policyRoutingAllocation or { }).tableId or null;
            entriesFor = family: route:
              let
                viaField = if family == 4 then "via4" else "via6";
                dst = route.dst or null;
              in
              if !builtins.isString dst then
                [ ]
              else
                [{
                  target = entry.targetName;
                  interface = ifaceName;
                  # The platform interface name the route is installed on, and
                  # the modelled class the renderer filters by. Both are
                  # modelled facts; a consumer must not re-derive them from
                  # nested per-interface records.
                  runtimeIfName =
                    iface.runtimeIfName or (iface.renderedIfName or ifaceName);
                  sourceKind = iface.sourceKind or null;
                  policyOnly = (route.policyOnly or false) == true;
                  # The deployment host the target is placed on, so a renderer
                  # can scope its artifact without re-reading placement from the
                  # nested model.
                  deploymentHost =
                    ((entry.target.placement or { }).host or null);
                  inherit family dst tableId;
                  gateway = route.${viaField} or null;
                  metric = route.metric or null;
                  kind = (route.intent or { }).kind or null;
                }];
          in
          builtins.concatMap
            (family: builtins.concatMap (entriesFor family) (routes."ipv${toString family}" or [ ]))
            [ 4 6 ])
        (builtins.attrNames interfaces))
    targetPairs;

  # Deterministic order and no exact duplicates: one command, one entry.
  keyOf = entry: builtins.toJSON [
    entry.target entry.interface entry.family entry.dst entry.gateway
    entry.tableId entry.metric entry.policyOnly
  ];
  deduped = builtins.attrValues (
    builtins.listToAttrs (
      map (entry: { name = keyOf entry; value = entry; }) routeEntries
    )
  );
  sorted = builtins.sort
    (a: b: (keyOf a) < (keyOf b))
    deduped;
in
sorted
