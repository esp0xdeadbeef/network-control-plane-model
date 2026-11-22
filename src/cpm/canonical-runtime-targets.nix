# Canonical runtime-target facts, published by the producer.
#
# WHY
# ---
# `network-renderer-nebula`'s host module selects which runtime target a host
# runs (`placement.host`), which logical node it is (`logicalNode`), and which
# containers realize it (`containers`). It reads those from the producer's model
# tree, which RR_RAW_CPM_INPUT forbids; `canonicalSites` (overlay facts) does not
# carry them.
#
# This publishes them as one flat, sorted list:
#
#   { enterprise, site, target, role, placementHost, logicalNode, containers }
#
# A projection of the producer's own values -- nothing is re-derived -- so it
# cannot disagree with the model it came from.
{ lib }:
cpm:
let
  enterpriseNames = builtins.attrNames (cpm.data or { });

  targetEntries = builtins.concatMap
    (enterprise:
      let sites = cpm.data.${enterprise} or { }; in
      builtins.concatMap
        (site:
          let targets = (cpm.data.${enterprise}.${site}.runtimeTargets or { }); in
          map
            (targetName:
              let target = targets.${targetName}; in
              {
                inherit enterprise site;
                target = targetName;
                role = target.role or null;
                placementHost = (target.placement or { }).host or null;
                logicalNode = target.logicalNode or { };
                containers = target.containers or [ ];
              })
            (builtins.attrNames targets))
        (builtins.attrNames sites))
    enterpriseNames;

  keyOf = entry: "${entry.enterprise}/${entry.site}/${entry.target}";
in
{
  targets = builtins.sort
    (a: b: (keyOf a) < (keyOf b))
    (builtins.attrValues (
      builtins.listToAttrs (map (entry: { name = keyOf entry; value = entry; }) targetEntries)
    ));
}
