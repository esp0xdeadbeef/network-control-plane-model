{ lib }:

# FS-310-HDS-020-SDS-010-SMS-060 -- rendered policy route placement / lane
# occurrence.
#
# THE GAP THIS CLOSES
# -------------------
# The row says, verbatim:
#
#   "Install each canonical route into exactly the context table and lane the
#    canonical record names. The renderer shall not choose, infer, or withhold a
#    route's table or lane occurrence: it shall not gate a route's materialization
#    on the presence of a forwarding rule, derive occurrence from interface
#    topology, or rely on an environment-supplied fallback table."
#
# Two facts decide a route's lane occurrence, and until now the CPM published
# neither:
#
#   policyRoutingSources  which source interfaces feed a target's policy table
#   networkBehavior       the role flags that make a target a selector, a policy
#                         target, an upstream selector or an access gateway
#
# network-renderer-nixos had to derive both from interface topology
# (s88/Unit/mapping/runtime-targets/interfaces/policy-routing-sources.nix and
# network-behavior.nix) because the strings did not appear anywhere in
# network-control-plane-model/src. Deriving them there is exactly the derivation
# the row forbids, so the renderer now *fails closed* when a target carries
# neither: measured, rendering `s-router-access-admin` throws
#
#   FS-310-HDS-020-SDS-010-SMS-060: the model supplies no 'policyRoutingSources'
#   for runtime target 'esp0xdeadbeef::site-a::esp0xdeadbeef-site-a-s-router-access-adm'
#
# and the same for `networkBehavior`. A fail-closed throw is the correct renderer
# behaviour; the missing fact is a producer defect, and this file is the producer
# change that fixes it.
#
# WHY IT IS NOT A RENDERER TABLE MOVED ONE LAYER DOWN
# ---------------------------------------------------
# Nothing here is topology inference bolted onto the CPM. Every input is a fact
# the CPM already publishes and owns:
#
#   * the interface class flags (`interfaceClass.edgeFacing`, `.fabricFacing`,
#     `.exitFacing`, `.coreFacing`, ...) are assigned by
#     Unit/runtime-targets/interfaces/taxonomy.nix from the interface's
#     sourceKind and its lane -- model facts, validated there;
#   * the lane each interface belongs to (`backingRef.lane.kind/access/uplink`)
#     is the lane the model assigned;
#   * the target's role and traversal participation are model facts.
#
# The predicates below are the same ones the renderer used, kept identical so the
# values do not change for the sites that rendered before -- what changes is WHO
# decides. A renderer may now only install what these records name.

let
  attrsOrEmpty =
    value:
    if builtins.isAttrs value then
      value
    else
      { };

  namesOf = attrs: lib.sort builtins.lessThan (builtins.attrNames (attrsOrEmpty attrs));

  interfacesOf = target: attrsOrEmpty (attrsOrEmpty (target.effectiveRuntimeRealization or null).interfaces or null);

  classFor =
    interfaces: name:
    let
      ifaceClass = (attrsOrEmpty interfaces.${name}).interfaceClass or { };
    in
    attrsOrEmpty ifaceClass;

  hasClass = interfaces: flag: name: (classFor interfaces name).${flag} or false;

  laneOf = interfaces: name: attrsOrEmpty ((attrsOrEmpty ((attrsOrEmpty interfaces.${name}).backingRef or null)).lane or null);

  laneAccessFor =
    interfaces: name:
    let
      access = (laneOf interfaces name).access or null;
    in
    if builtins.isString access then access else null;

  uplinksFor =
    interfaces: name:
    let
      backingRef = attrsOrEmpty ((attrsOrEmpty interfaces.${name}).backingRef or null);
      lane = laneOf interfaces name;
      explicit = if builtins.isList (backingRef.uplinks or null) then builtins.filter builtins.isString backingRef.uplinks else [ ];
      laneUplinks = if builtins.isList (lane.uplinks or null) then builtins.filter builtins.isString lane.uplinks else [ ];
    in
    lib.unique (explicit ++ laneUplinks);

  sameAccess =
    interfaces: left: right:
    let
      access = laneAccessFor interfaces left;
    in
    access != null && laneAccessFor interfaces right == access;

  sameUplink =
    interfaces: left: right:
    lib.any (uplink: builtins.elem uplink (uplinksFor interfaces right)) (uplinksFor interfaces left);

  # The four role flags. `isSelector`/`isUpstreamSelector`/`isPolicy` are target
  # shape; `isAccessGateway` additionally needs a tenant-source interface, which
  # is what makes a box the DHCP/DNS gateway for an access rather than a transit
  # hop on it.
  behaviorForInterfaces =
    target: interfaces:
    let
      names = namesOf interfaces;
      any_ = flag: lib.any (hasClass interfaces flag) names;
      sourceKindIs =
        kind: name:
        ((attrsOrEmpty interfaces.${name}).sourceKind or null) == kind;
      roles = attrsOrEmpty target.traversalParticipation;
      isSelector = any_ "edgeFacing" && any_ "fabricFacing";
      isUpstreamSelector = any_ "coreFacing" && any_ "exitFacing";
      isPolicy = any_ "fabricFacing" && any_ "exitFacing";
      isAccessGateway = any_ "edgeFacing" && lib.any (sourceKindIs "tenant") names;
    in
    {
      inherit
        isSelector
        isUpstreamSelector
        isPolicy
        isAccessGateway
        ;
      # A policy box keeps its interface routes out of the main table: a route
      # installed in main on a policy target is reachable without traversing
      # policy, which is the bypass this whole row exists to prevent.
      keepInterfaceRoutesInMain = !(isSelector || isUpstreamSelector || isPolicy || isAccessGateway);
      # The model's own statement of what the target does, published beside the
      # derived flags so a consumer can check them against each other instead of
      # trusting a boolean.
      role = target.role or null;
      participates = roles.participates or false;
      exit = roles.exit or false;
      enforcement = roles.enforcement or false;
      upstreamSelection = roles.upstreamSelection or false;
    };

  behaviorFor = target: behaviorForInterfaces target (interfacesOf target);

  renderedNameFor =
    interfaces: name:
    let
      rendered = (attrsOrEmpty interfaces.${name}).renderedIfName or null;
    in
    if builtins.isString rendered then rendered else name;

  # Which source interfaces feed a given interface's policy table.
  #
  # This is the renderer's `sourcesFor` predicate, applied to a MODEL interface
  # instead of to a renderer-invented class table. Every input is a fact the CPM
  # already publishes (interfaceClass flags from taxonomy.nix, the assigned
  # lane's access/uplink, sourceKind), so the answer is a model fact and not an
  # inference over link topology.
  #
  # Keyed by the RENDERED interface name because that is what the renderer
  # installs the table against; the values name model interface names, which is
  # what the canonical route records reference.
  sourcesForInterface =
    interfaces: name:
    let
      names = namesOf interfaces;
      behavior = behaviorForInterfaces { } interfaces;
      has = hasClass interfaces;
    in
    if behavior.isSelector && has "edgeFacing" name then
      lib.filter (other: has "fabricFacing" other && sameAccess interfaces name other) names
    else if behavior.isSelector && has "fabricFacing" name then
      lib.filter (other: has "edgeFacing" other && sameAccess interfaces name other) names
    else if behavior.isUpstreamSelector && has "coreFacing" name then
      lib.unique (
        [ name ] ++ lib.filter (other: has "exitFacing" other && sameUplink interfaces name other) names
      )
    else if behavior.isUpstreamSelector && has "exitFacing" name then
      lib.unique (
        [ name ] ++ lib.filter (other: has "coreFacing" other && sameUplink interfaces name other) names
      )
    else if behavior.isPolicy && has "fabricFacing" name then
      lib.filter (
        other: has "fabricFacing" other || (has "exitFacing" other && sameAccess interfaces name other)
      ) names
    else if behavior.isPolicy && has "exitFacing" name then
      lib.filter (
        other: (has "fabricFacing" other || has "exitFacing" other) && sameAccess interfaces name other
      ) names
    else if has "overlay" name then
      lib.unique ([ name ] ++ lib.filter (other: has "coreTransit" other) names)
    else if has "coreTransit" name then
      lib.unique ([ name ] ++ lib.filter (other: has "overlay" other) names)
    else
      [ name ];

  policyRoutingSourcesFor =
    target:
    let
      interfaces = interfacesOf target;
    in
    builtins.listToAttrs (
      map (name: {
        name = renderedNameFor interfaces name;
        value = sourcesForInterface interfaces name;
      }) (namesOf interfaces)
    );
in
# Applied to a single runtime target, so the caller composes it with the other
# per-target stages.
target:
(target // {
  networkBehavior = behaviorFor target;
  policyRoutingSources = policyRoutingSourcesFor target;
})
