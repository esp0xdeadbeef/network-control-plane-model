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

  servicePath = root: service: targetName: id:
    "${root}/${service}/${targetName}/${id}";

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
      mode = if required then "persistent" else "ephemeral";
      _pathRequired =
        if required && !isNonEmptyString path then
          throw "statePolicy.persistence.root or explicit ${service}.${id}.path is required when persistence.required=true"
        else
          true;
    in
    builtins.seq _pathRequired ({
      inherit service id mode required;
      source = if isNonEmptyString path then "inventory-realization" else "explicit-ephemeral";
    }
    // attrs
    // (if isNonEmptyString path then { inherit path; } else { runtimeLocation = "ephemeral"; }));

  recordContract = targetName: recordPolicy: service: id: attrs:
    let
      required = recordRequired recordPolicy;
      root = rootFor recordPolicy "root";
      path = buildPath root (attrs.path or "") (servicePath root service targetName "${id}.jsonl");
      _pathRequired =
        if required && !isNonEmptyString path then
          throw "statePolicy.operationalRecords.root or explicit ${service}.${id}.path is required when operationalRecords.required=true"
        else
          true;
    in
    builtins.seq _pathRequired ({
      inherit service id required;
      format = "jsonl";
      mode = if required then "persistent" else "ephemeral";
      source = if isNonEmptyString path then "inventory-realization" else "explicit-ephemeral";
      fields = [
        "time"
        "node"
        "service"
        "eventType"
        "clientOrAddress"
        "action"
        "result"
        "severity"
      ];
      excludedFields = [
        "secrets"
        "certificates"
        "fullPacketPayload"
        "unboundedDebugOutput"
      ];
    }
    // attrs
    // (if isNonEmptyString path then { inherit path; } else { runtimeLocation = "ephemeral"; }));
in
{
  inherit
    attrsOrEmpty
    listOrEmpty
    persistenceContract
    persistenceRequired
    recordContract
    recordRequired
    ;
}
