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
          failAudit "${path}.binderSourceAudit" "is required for CPM realization-binding output";
      stage = requireNonEmptyString "${path}.binderSourceAudit.stage" (audit.stage or null);
      authority = requireNonEmptyString "${path}.binderSourceAudit.authority" (audit.authority or null);
      sourceClass = requireNonEmptyString "${path}.binderSourceAudit.sourceClass" (audit.sourceClass or null);
      upstreamTop = requireNonEmptyString "${path}.upstreamBehaviorRef" (attrs.upstreamBehaviorRef or null);
      upstreamAudit = requireNonEmptyString "${path}.binderSourceAudit.upstreamBehaviorRef" (audit.upstreamBehaviorRef or null);
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
  inherit make validate;
}
