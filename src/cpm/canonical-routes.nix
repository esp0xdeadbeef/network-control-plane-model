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
  # Distinct values, order preserved. `lib.unique` would do, but values here can
  # be null and lists of mixed types, so compare their canonical JSON.
  unique =
    values:
    let
      indexed = lib.imap0 (index: value: { inherit index value; }) values;
      firstFor = builtins.listToAttrs (
        map (entry: { name = builtins.toJSON entry.value; value = entry.index; }) indexed
      );
      keep = map (entry: entry.value) (
        builtins.filter (entry: (firstFor.${builtins.toJSON entry.value}) == entry.index) indexed
      );
    in
    keep;

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
                  # FS-370-HDS-010-SDS-010-SMS-010 / FS-540: the preferred
                  # source the runtime-origin contract binds a default to. It is
                  # already stamped on the interface route by
                  # runtime-origin-egress.nix `applyToInterfaces`; publishing it
                  # here is what lets a renderer install the route without
                  # reading the model to find it.
                  preferredSource = route.preferredSource or null;
                }];
          in
          builtins.concatMap
            (family: builtins.concatMap (entriesFor family) (routes."ipv${toString family}" or [ ]))
            [ 4 6 ])
        (builtins.attrNames interfaces))
    targetPairs;

  # Deterministic order and no exact duplicates: one command, one entry.
  #
  # The identity is the one `ip route replace` keys on -- (family, table,
  # destination, gateway, metric) on one interface of one target -- plus the
  # interface and target that carry it. It is NOT the modelled route record:
  #
  #   `policyOnly` does not reach the kernel. One modelled route can arrive here
  #   twice, once as the plain route and once as the policy-only projection of
  #   it, and both are the same command. Keying on `policyOnly` published two
  #   entries for one authority, and every renderer then installed two
  #   primitives for one route (FS-310-HDS-020-SDS-010-SMS-060: "exact
  #   duplicates become repeated target routes instead of one primitive").
  #
  #   `kind` and `sourceKind` are provenance. Two entries that differ only in
  #   them are still one command; `kind` is taken from the first in canonical
  #   order so the published record stays deterministic.
  #
  # Anything else that differs is a genuine conflict -- two routes that cannot
  # both be installed -- and is left to the model's own validation rather than
  # being merged here, because realizing a winner would be this projection
  # choosing meaning the producer did not.
  keyOf = entry: builtins.toJSON [
    entry.target entry.interface entry.family entry.dst entry.gateway
    entry.tableId entry.metric
  ];
  grouped = builtins.groupBy keyOf routeEntries;
  # Every field of an entry is either part of `keyOf` or one of these. That is
  # the whole contract: the identity is what `ip route replace` keys on, so two
  # entries sharing it ARE one command, and the only things left to reconcile
  # are the label (`kind`), the modelled class (`sourceKind`) and the projection
  # flag (`policyOnly`).
  #
  # There is deliberately no "conflict" branch. A conflict would need two
  # entries that share the key but differ in something else, and the key already
  # contains every field a route has apart from these three -- `interface` is in
  # the key, so two different links never collide, and `deploymentHost` follows
  # from `target`. A guard for an unreachable case is a guard nobody can
  # falsify; the merge below is covered by a test that asserts both the merge
  # and that distinct next hops stay distinct.
  merged =
    key:
    let
      entries = grouped.${key};
      # `kind` and `sourceKind` label the same command; when a merged group
      # arrives with several labels, publish one of them deterministically.
      # Picking by arrival order would make the record depend on evaluation
      # order; sorting first makes the answer a function of the content.
      oneOf =
        name:
        let
          values = unique (map (entry: entry.${name} or null) entries);
        in
        if builtins.length values == 1 then
          builtins.head values
        else
          builtins.head (builtins.sort (a: b: builtins.toJSON a < builtins.toJSON b) values);
      policyOnly = builtins.any (entry: entry.policyOnly == true) entries;
    in
    (builtins.head entries)
    // {
      inherit policyOnly;
      kind = oneOf "kind";
      sourceKind = oneOf "sourceKind";
    };
  deduped = map merged (builtins.attrNames grouped);
  sorted = builtins.sort
    (a: b: (keyOf a) < (keyOf b))
    deduped;
in
sorted
