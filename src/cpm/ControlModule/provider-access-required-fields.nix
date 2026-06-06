{ helpers
, inventory ? { }
,
}:

let
  inherit (helpers) forceAll hasAttr requireList requireStringList sortedNames;

  failInventory = path: message:
    throw "inventory.nix update required: ${path}: ${message}";

  inventoryRoot = if builtins.isAttrs inventory then inventory else { };
  controlPlane = if builtins.isAttrs (inventoryRoot.controlPlane or null) then inventoryRoot.controlPlane else { };
  providerAccess = if builtins.isAttrs (controlPlane.providerAccess or null) then controlPlane.providerAccess else { };
  scenarios = if builtins.isAttrs (providerAccess.scenarios or null) then providerAccess.scenarios else { };

  renderPath = segments:
    builtins.concatStringsSep "." segments;

  hasPath = value: segments:
    if segments == [ ] then
      true
    else
      let
        field = builtins.head segments;
        rest = builtins.tail segments;
      in
      builtins.isAttrs value && hasAttr field value && hasPath value.${field} rest;

  validateScenario = scenarioName:
    let
      scenarioPath = "inventory.controlPlane.providerAccess.scenarios.${scenarioName}";
      scenario = scenarios.${scenarioName};
    in
    if !(builtins.isAttrs scenario) || !(scenario ? requiredFields) then
      true
    else
      let
        rowId = if builtins.isString (scenario.gampId or null) then scenario.gampId else "FS-800-HDS-010-SDS-011";
        requiredFields = requireList "${scenarioPath}.requiredFields" scenario.requiredFields;
        normalizedRequiredFields =
          builtins.genList
            (idx:
              requireStringList
                "${scenarioPath}.requiredFields[${toString idx}]"
                (builtins.elemAt requiredFields idx))
            (builtins.length requiredFields);
        missingFields =
          builtins.filter
            (fieldPath: !(hasPath scenario fieldPath))
            normalizedRequiredFields;
        firstMissing = if missingFields == [ ] then null else builtins.elemAt missingFields 0;
      in
      if missingFields == [ ] then
        true
      else
        failInventory
          "${scenarioPath}.${renderPath firstMissing}"
          "${rowId}: provider-access required field '${renderPath firstMissing}' must be present before CPM handoff; downstream renderer inference is not allowed";
in
forceAll (
  builtins.map
    validateScenario
    (sortedNames scenarios)
)
