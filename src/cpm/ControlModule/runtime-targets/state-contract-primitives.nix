{ common }:

let
  inherit (common) attrsOrEmpty listOrEmpty;

  isNonEmptyString = value: builtins.isString value && value != "";

  requireBool = path: value:
    if builtins.isBool value then
      value
    else
      throw "${path} must be a boolean";

  requiredFlag = path: policy:
    if policy ? required then requireBool path policy.required else false;

  rootFor = policy: field:
    let value = policy.${field} or "";
    in if isNonEmptyString value then value else "";

  allowedDurabilityClasses = [
    "disposable"
    "restart-tolerant"
    "restart-persistent"
  ];

  requireDurabilityClass = path: value:
    if builtins.elem value allowedDurabilityClasses then
      value
    else
      throw "${path} must be one of: disposable, restart-tolerant, restart-persistent";

  durabilityClassFor = policyPath: policy: required: hasPath:
    let
      defaultClass =
        if required then
          "restart-persistent"
        else if hasPath then
          "restart-tolerant"
        else
          "disposable";
      durabilityClass = requireDurabilityClass "${policyPath}.durabilityClass" (policy.durabilityClass or defaultClass);
      _requiredClass =
        if required && durabilityClass != "restart-persistent" then
          throw "${policyPath}.durabilityClass must be restart-persistent when required=true"
        else
          true;
    in
    builtins.seq _requiredClass durabilityClass;

  stateLossHandlingFor = policyPath: policy: durabilityClass:
    let
      defaultHandling =
        if durabilityClass == "restart-persistent" then
          "fail-closed-require-persistent-state"
        else if durabilityClass == "restart-tolerant" then
          "rebuild-from-runtime-sources"
        else
          "recreate-empty-state";
      value = policy.stateLossHandling or defaultHandling;
    in
    if isNonEmptyString value then
      value
    else
      throw "${policyPath}.stateLossHandling must be a non-empty string";

  servicePath = root: service: targetName: id:
    "${root}/${service}/${targetName}/${id}";

  appendUnique = base: extra:
    base ++ builtins.filter (field: !(builtins.elem field base)) extra;

  operationalRecordRequiredFields = [
    "recordType"
    "timestampSource"
    "site"
    "context"
    "runtimeFactSet"
    "modelProvenance"
    "decision"
    "reason"
    "redactionClass"
  ];

  operationalRecordConditionalFields = [
    "tenant"
  ];

  operationalRecordExcludedFields = [
    "secrets"
    "certificates"
    "fullPacketPayload"
    "unboundedDebugOutput"
  ];

  persistenceRequired = requiredFlag "statePolicy.persistence.required";

  recordRequired = requiredFlag "statePolicy.operationalRecords.required";

  buildPath = root: explicitPath: fallback:
    if isNonEmptyString explicitPath then
      explicitPath
    else if isNonEmptyString root then
      fallback
    else
      "";

  persistenceContract = targetName: persistencePolicy: service: id: attrs:
    let
      required = persistenceRequired persistencePolicy;
      root = rootFor persistencePolicy "root";
      path = buildPath root (attrs.path or "") (servicePath root service targetName id);
      hasPath = isNonEmptyString path;
      durabilityClass = durabilityClassFor "statePolicy.persistence" persistencePolicy required hasPath;
      stateLossHandling = stateLossHandlingFor "statePolicy.persistence" persistencePolicy durabilityClass;
      mode = if required then "persistent" else "ephemeral";
      _pathRequired =
        if required && !hasPath then
          throw "statePolicy.persistence.root or explicit ${service}.${id}.path is required when persistence.required=true"
        else
          true;
    in
    builtins.seq _pathRequired ({
      inherit service id mode required targetName durabilityClass stateLossHandling;
      stateClass = attrs.kind or "state";
      scope = {
        target = targetName;
        inherit service id;
      }
      // (if isNonEmptyString (attrs.interface or "") then { interface = attrs.interface; } else { })
      // (if isNonEmptyString (attrs.tenant or "") then { tenant = attrs.tenant; } else { });
      source = if hasPath then "inventory-realization" else "explicit-ephemeral";
    }
    // attrs
    // (if hasPath then { inherit path; } else { runtimeLocation = "ephemeral"; }));

  recordContract = targetName: recordPolicy: service: id: attrs:
    let
      required = recordRequired recordPolicy;
      root = rootFor recordPolicy "root";
      path = buildPath root (attrs.path or "") (servicePath root service targetName "${id}.jsonl");
      hasPath = isNonEmptyString path;
      durabilityClass = durabilityClassFor "statePolicy.operationalRecords" recordPolicy required hasPath;
      stateLossHandling = stateLossHandlingFor "statePolicy.operationalRecords" recordPolicy durabilityClass;
      fieldExtensions = listOrEmpty (attrs.fields or null);
      excludedFieldExtensions = listOrEmpty (attrs.excludedFields or null);
      attrsWithoutSchemaOverrides = builtins.removeAttrs attrs [ "fields" "excludedFields" ];
      _pathRequired =
        if required && !hasPath then
          throw "statePolicy.operationalRecords.root or explicit ${service}.${id}.path is required when operationalRecords.required=true"
        else
          true;
    in
    builtins.seq _pathRequired ({
      inherit service id required targetName durabilityClass stateLossHandling;
      format = "jsonl";
      mode = if required then "persistent" else "ephemeral";
      stateClass = "operational-record";
      scope = {
        target = targetName;
        inherit service id;
      }
      // (if isNonEmptyString (attrs.interface or "") then { interface = attrs.interface; } else { })
      // (if isNonEmptyString (attrs.tenant or "") then { tenant = attrs.tenant; } else { });
      source = if hasPath then "inventory-realization" else "explicit-ephemeral";
      fields = appendUnique
        (operationalRecordRequiredFields ++ operationalRecordConditionalFields)
        fieldExtensions;
      excludedFields = appendUnique operationalRecordExcludedFields excludedFieldExtensions;
      schema = {
        requiredFields = operationalRecordRequiredFields;
        conditionalFields = operationalRecordConditionalFields;
        incompleteEvidence = {
          classification = "incomplete-evidence";
          whenMissingFields = [
            "site"
            "context"
            "runtimeFactSet"
            "modelProvenance"
          ];
          promotionAllowed = false;
        };
      };
    }
    // attrsWithoutSchemaOverrides
    // (if hasPath then { inherit path; } else { runtimeLocation = "ephemeral"; }));
in
{
  inherit
    attrsOrEmpty
    listOrEmpty
    operationalRecordConditionalFields
    operationalRecordRequiredFields
    persistenceContract
    persistenceRequired
    recordContract
    recordRequired
    ;
}
