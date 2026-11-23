# Canonical forwarding relations, published by the producer.
#
# WHY THIS EXISTS
# ---------------
# The model expresses egress authority in three places, and until now only one of
# them reached a consumer:
#
#   1. per-interface routes          `canonicalRoutes`
#   2. per-target forwarding rules   `forwardingIntent` on the runtime target
#   3. the renderer's derived returns
#
# (2) is read by the renderer and by nothing else. That disjointness is the last
# defect in network-renderer-nixos' SMS-060 investigation, and it showed up three
# ways:
#
#   * the duplicate check called every relation-derived route invented until it
#     was made to load `forwardingIntent` itself;
#   * the ownership rule, built from `canonicalRoutes`, called a relation-derived
#     return route a copy -- measured: 10.70.10.0/24 in table 1001 on
#     espbranch-site-b-b-router-upstream-selector exists only as a relation, and
#     `canonicalRoutes` has no such route at all;
#   * a renderer emitting from canonical content could not satisfy the
#     runtime-origin contract, which needed `preferredSource` -- a field the
#     relation path already knew.
#
# Publishing the relations makes (1) and (2) the same set to a consumer, which is
# the property the renderer boundary needs: one authority, not three.
#
# SHAPE
# -----
# One entry per forwarding rule, flattened to the fields a consumer maps, plus
# the complete modelled rule as `facts` -- the same shape `canonicalSites`,
# `canonicalRuntimeTargets` and `canonicalRoutes` already use, so a consumer that
# needs a field this projection does not single out can take it from the record
# the producer holds rather than from the model.
{ lib }:
cpm:
let
  enterpriseNames = builtins.attrNames (cpm.data or { });

  targetPairs = builtins.concatMap (
    enterprise:
    let
      sites = cpm.data.${enterprise} or { };
    in
    builtins.concatMap (
      site:
      let
        targets = cpm.data.${enterprise}.${site}.runtimeTargets or { };
      in
      map (targetName: {
        key = "${enterprise}/${site}/${targetName}";
        inherit enterprise site targetName;
        target = targets.${targetName};
      }) (builtins.attrNames targets)
    ) (builtins.attrNames sites)
  ) enterpriseNames;

  ruleEntries = builtins.concatMap (
    entry:
    let
      forwardingIntent =
        if builtins.isAttrs (entry.target.forwardingIntent or null) then
          entry.target.forwardingIntent
        else
          { };
      rules =
        if builtins.isList (forwardingIntent.rules or null) then forwardingIntent.rules else [ ];
    in
    map (rule: {
      inherit (entry) enterprise site;
      target = entry.targetName;
      relationId = rule.relationId or null;
      direction = rule.direction or null;
      action = rule.action or null;
      priority = rule.priority or null;
      fromInterface = rule.fromInterface or null;
      toInterface = rule.toInterface or null;
      trafficType = rule.trafficType or null;
      returnBehavior = rule.returnBehavior or null;
      # The runtime interface the rule's egress candidate names, when it names
      # one. This is what a consumer needs to place a relation-derived route, and
      # it is the field whose absence made the ownership rule unable to tell a
      # copy from a required return.
      egressRuntimeInterface =
        ((rule.candidateEgress or { }).runtimeInterface or null);
      facts = rule;
    }) rules
  ) targetPairs;

  keyOf = entry: "${entry.target}/${toString entry.relationId}/${toString entry.priority}/${toString entry.direction}";
in
{
  relations = builtins.sort
    (a: b: (keyOf a) < (keyOf b))
    (builtins.attrValues (
      builtins.listToAttrs (map (entry: { name = keyOf entry; value = entry; }) ruleEntries)
    ));
}
