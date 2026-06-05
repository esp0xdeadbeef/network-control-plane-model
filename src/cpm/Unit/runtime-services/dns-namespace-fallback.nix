{ lib
, helpers
, failInventory
,
}:

let
  inherit (helpers)
    isNonEmptyString
    requireAttrs
    requireList
    requireString
    ;

  normalizeStringList = path: value:
    let
      entries = requireList path value;
      normalized =
        builtins.map
          (entry:
            let rendered = requireString "${path}[*]" entry;
            in if isNonEmptyString rendered then rendered else failInventory path "must not contain empty strings")
          entries;
    in
    if normalized == [ ] then failInventory path "must contain at least one entry" else normalized;

  boolOrDefault =
    path: value: default:
    if value == null then
      default
    else if builtins.isBool value then
      value
    else
      failInventory path "must be a boolean";

  requireEnum = path: allowed: value:
    let rendered = requireString path value;
    in
    if builtins.elem rendered allowed then
      rendered
    else
      failInventory path "must be one of ${builtins.concatStringsSep ", " allowed}";

in
dnsPath: dns:
let
  path = "${dnsPath}.namespaceFallback";
  value = dns.namespaceFallback or null;
in
if value == null then
  null
else
  let
    cfg = requireAttrs path value;
    decisionsPath = "${path}.decisions";
    defaultPublicRecursionFallback =
      boolOrDefault "${path}.defaultPublicRecursionFallback"
        (cfg.defaultPublicRecursionFallback or null)
        false;
    normalizeDecision = decision:
      let
        decisionPath = "${decisionsPath}[*]";
        attrs = requireAttrs decisionPath decision;
        requesterScope = requireString "${decisionPath}.requesterScope" (attrs.requesterScope or null);
        namespace = requireString "${decisionPath}.namespace" (attrs.namespace or null);
        failedAnswerReason = requireString "${decisionPath}.failedAnswerReason" (attrs.failedAnswerReason or null);
        action = requireEnum "${decisionPath}.action" [ "answer" "fallback" "block" "deny" ] (attrs.action or null);
        leakPrevention = requireString "${decisionPath}.leakPrevention" (attrs.leakPrevention or null);
        allowedRecordClasses = normalizeStringList "${decisionPath}.allowedRecordClasses" (attrs.allowedRecordClasses or null);
        deniedRecordClasses = normalizeStringList "${decisionPath}.deniedRecordClasses" (attrs.deniedRecordClasses or null);
        publicRecursionFallback =
          boolOrDefault "${decisionPath}.publicRecursionFallback"
            (attrs.publicRecursionFallback or null)
            false;
        fallbackTarget =
          if attrs ? fallbackTarget then
            requireString "${decisionPath}.fallbackTarget" attrs.fallbackTarget
          else
            null;
        _fallbackTargetRequired =
          if action == "fallback" && fallbackTarget == null then
            failInventory "${decisionPath}.fallbackTarget" "is required when namespace fallback action is 'fallback'"
          else
            true;
        _publicFallbackExplicit =
          if publicRecursionFallback && (action != "fallback" || fallbackTarget == null) then
            failInventory
              "${decisionPath}.publicRecursionFallback"
              "requires explicit fallback action and fallbackTarget"
          else
            true;
        _deniedRequesterScopeNoFallback =
          if failedAnswerReason == "denied-requester-scope" && (publicRecursionFallback || action == "fallback" || fallbackTarget != null) then
            failInventory
              "${decisionPath}.publicRecursionFallback"
              "must be false for denied requester scope; cross-tenant DNS denial cannot inherit public recursion fallback"
          else
            true;
      in
      builtins.seq _fallbackTargetRequired (
        builtins.seq _publicFallbackExplicit (
          builtins.seq _deniedRequesterScopeNoFallback ({
            inherit
              action
              allowedRecordClasses
              deniedRecordClasses
              failedAnswerReason
              leakPrevention
              namespace
              publicRecursionFallback
              requesterScope
              ;
          } // lib.optionalAttrs (fallbackTarget != null) { inherit fallbackTarget; })
        )
      );
    decisions = builtins.map normalizeDecision (requireList decisionsPath (cfg.decisions or null));
    _hasDecision =
      if decisions == [ ] then
        failInventory decisionsPath "must contain at least one namespace miss or fallback decision"
      else
        true;
  in
  builtins.seq _hasDecision {
    inherit defaultPublicRecursionFallback decisions;
  }
