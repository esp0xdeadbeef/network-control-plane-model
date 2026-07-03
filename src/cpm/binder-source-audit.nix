{ helpers }:

let
  inherit (helpers) requireAttrs requireString;

  failAudit = path: message:
    throw "CPM binder source audit error: ${path}: ${message}";

  allowedBinderSourceClasses = [
    "public-inventory"
    "protected-inventory"
    "runtime-facts"
    "validation-context"
  ];

  requireNonEmptyString = path: value:
    let
      stringValue = requireString path value;
    in
    if stringValue == "" then failAudit path "must not be empty" else stringValue;

  stringHint = value: fallback:
    if builtins.isString value && value != "" then value else fallback;

  missingBinderAudit = path: attrs:
    let
      fieldPath = stringHint (attrs.field or null) path;
      expectedSourceClass = stringHint (attrs.expectedBinderSourceClass or attrs.binderSourceClass or null) "public-inventory";
      ownerRecord = stringHint (attrs.ownerRecord or attrs.owner or attrs.scope or null) path;
    in
    throw "CPM_BINDER_SOURCE_AUDIT_MISSING field=${fieldPath} expectedSourceClass=${expectedSourceClass} owner=${ownerRecord}";

  missingUpstreamRef = path: attrs: audit:
    let
      fieldPath = stringHint (audit.field or attrs.field or null) path;
      sourceClass = stringHint (audit.sourceClass or attrs.binderSourceClass or null) "unknown";
      ownerRecord = stringHint (attrs.ownerRecord or attrs.owner or attrs.scope or null) path;
    in
    throw "CPM_UPSTREAM_BEHAVIOR_REF_MISSING field=${fieldPath} sourceClass=${sourceClass} missing=upstreamBehaviorRef owner=${ownerRecord}";

  make =
    { path
    , field
    , binderSourceClass
    , binderSourcePath
    , upstreamBehaviorRef
    ,
    }:
    let
      sourceClass = requireNonEmptyString "${path}.binderSourceAudit.sourceClass" binderSourceClass;
      sourcePath = requireNonEmptyString "${path}.binderSourceAudit.sourcePath" binderSourcePath;
      behaviorRef = requireNonEmptyString "${path}.upstreamBehaviorRef" upstreamBehaviorRef;
      _sourceClass =
        if builtins.elem sourceClass allowedBinderSourceClasses then
          true
        else
          failAudit "${path}.binderSourceAudit.sourceClass" "must be CPM binder source class public-inventory, protected-inventory, runtime-facts, or validation-context";
    in
    builtins.seq _sourceClass {
      upstreamBehaviorRef = behaviorRef;
      binderSourceAudit = {
        stage = "control-plane-model";
        authority = "realization-binding";
        sourceClass = sourceClass;
        inherit field sourcePath;
        upstreamBehaviorRef = behaviorRef;
      };
    };

  makeRoute =
    { path
    , field
    , binderSourceClass
    , binderSourcePath
    , upstreamBehaviorRef
    , route
    ,
    }:
    let
      behaviorRef = requireNonEmptyString "${path}.traceBackRef" upstreamBehaviorRef;
    in
    route
    // (make {
      inherit path field binderSourceClass binderSourcePath;
      upstreamBehaviorRef = behaviorRef;
    })
    // {
      traceBackRef = behaviorRef;
    };

  validateRouteBinding = path: record:
    let
      attrs =
        if builtins.isAttrs record then
          record
        else
          failAudit path "must be an attribute set";
      dst = attrs.dst or attrs.prefix or "<unknown>";
      nextHop = attrs.via or attrs.via4 or attrs.via6 or "<unknown>";
      scope = attrs.scope or path;
      traceBackRef = attrs.traceBackRef or null;
      _trace =
        if builtins.isString traceBackRef && traceBackRef != "" then
          true
        else
          throw "UNTRACEABLE_ROUTE scope=${scope} destination=${dst} nextHop=${nextHop}: missing traceBackRef";
      normalized =
        attrs
        // {
          upstreamBehaviorRef = attrs.upstreamBehaviorRef or traceBackRef;
          traceBackRef = traceBackRef;
        };
    in
    builtins.seq _trace (validate path normalized);

  validate = path: record:
    let
      attrs =
        if builtins.isAttrs record then
          record
        else
          failAudit path "must be an attribute set";
      audit =
        if builtins.isAttrs (attrs.binderSourceAudit or null) then
          attrs.binderSourceAudit
        else
          missingBinderAudit path attrs;
      stage = requireNonEmptyString "${path}.binderSourceAudit.stage" (audit.stage or null);
      authority = requireNonEmptyString "${path}.binderSourceAudit.authority" (audit.authority or null);
      sourceClass = requireNonEmptyString "${path}.binderSourceAudit.sourceClass" (audit.sourceClass or null);
      upstreamTop =
        if builtins.isString (attrs.upstreamBehaviorRef or null) && attrs.upstreamBehaviorRef != "" then
          attrs.upstreamBehaviorRef
        else
          missingUpstreamRef path attrs audit;
      upstreamAudit =
        if builtins.isString (audit.upstreamBehaviorRef or null) && audit.upstreamBehaviorRef != "" then
          audit.upstreamBehaviorRef
        else
          missingUpstreamRef path attrs audit;
      _stage =
        if stage == "control-plane-model" then
          true
        else
          failAudit "${path}.binderSourceAudit.stage" "must be control-plane-model, not cross-stage compiler or renderer authority";
      _authority =
        if authority == "realization-binding" then
          true
        else
          failAudit "${path}.binderSourceAudit.authority" "must be stage-local realization-binding authority";
      _sourceClass =
        if builtins.elem sourceClass allowedBinderSourceClasses then
          true
        else
          failAudit "${path}.binderSourceAudit.sourceClass" "must be CPM binder source class public-inventory, protected-inventory, runtime-facts, or validation-context";
      _upstream =
        if upstreamTop == upstreamAudit then
          true
        else
          failAudit "${path}.binderSourceAudit.upstreamBehaviorRef" "must match the output upstreamBehaviorRef";
    in
    builtins.seq _stage (builtins.seq _authority (builtins.seq _sourceClass (builtins.seq _upstream true)));
in
{
  inherit make makeRoute validate validateRouteBinding;
}
