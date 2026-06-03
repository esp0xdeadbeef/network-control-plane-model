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
              code = "E_INVENTORY_RUNTIME_TARGET_UNREALIZED";
              path = "${siteContract.sitePath}.nodes.${nodeName}";
              runtimeTarget = nodeName;
              actualPlacementKind = "missing-inventory-realization";
              expectedPlacementKind = "inventory-realization";
              missingInput = "inventory.realization.nodes";
              missingInventoryKey = "${siteContract.enterpriseName}-${siteContract.siteName}-${nodeName}";
              owningLayer = "network-labs inventory";
              sourceClass = "public-inventory";
              requiredCorrection = "add inventory.realization.nodes.${siteContract.enterpriseName}-${siteContract.siteName}-${nodeName} with logicalNode = { enterprise = \"${siteContract.enterpriseName}\"; site = \"${siteContract.siteName}\"; name = \"${nodeName}\"; }, deployment host, platform, and explicit port/uplink realization facts for this runtime target";
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
    inventory lint error: E_INVENTORY_RUNTIME_TARGET_UNREALIZED: inventory.nix must explicitly realize every control_plane_model runtime target via inventory.realization.nodes.
    Owning layer: network-labs inventory.
    Source class: public-inventory.
    Missing input: inventory.realization.nodes.<enterprise>-<site>-<logical-node>.
    Required correction: add the listed missingInventoryKey entries to the renderer inventory with logicalNode, deployment host, platform, and explicit port/uplink realization facts. Do not repair this in CPM, renderers, scripts, or host defaults.
    Missing runtime target realizations:
    ${builtins.toJSON unrealizedRuntimeTargets}
  ''
else
  true
