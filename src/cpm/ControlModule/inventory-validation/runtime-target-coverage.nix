{ helpers }:

{ sitesByKey, realizationIndex }:

let
  inherit (helpers) hasAttr sortedNames;

  unrealizedRuntimeTargets =
    builtins.concatLists (
      builtins.map
        (siteKey:
          let
            siteContract = sitesByKey.${siteKey};
          in
          builtins.map
            (nodeName: {
              path = "${siteContract.sitePath}.nodes.${nodeName}";
              runtimeTarget = nodeName;
              actualPlacementKind = "missing-inventory-realization";
              expectedPlacementKind = "inventory-realization";
              logicalNode = {
                enterprise = siteContract.enterpriseName;
                site = siteContract.siteName;
                name = nodeName;
              };
            })
            (builtins.filter
              (nodeName:
                let
                  logicalKey = "${siteContract.enterpriseName}|${siteContract.siteName}|${nodeName}";
                in
                !hasAttr logicalKey realizationIndex.byLogical)
              (sortedNames siteContract.nodeContracts)))
        (sortedNames sitesByKey)
    );
in
if unrealizedRuntimeTargets != [ ] then
  throw ''
    inventory lint error: inventory.nix must explicitly realize every control_plane_model runtime target via inventory.realization.nodes.
    Missing runtime target realizations:
    ${builtins.toJSON unrealizedRuntimeTargets}
  ''
else
  true
