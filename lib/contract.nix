{ lib ? null }:

let
  isNonEmptyString = value:
    builtins.isString value && value != "";

  forceAll = values:
    builtins.deepSeq values true;

  sortedNames = attrs:
    if builtins.isAttrs attrs then
      (
        if lib != null && lib ? attrNamesSorted then
          lib.attrNamesSorted attrs
        else
          builtins.sort builtins.lessThan (builtins.attrNames attrs)
      )
    else
      [ ];

  optionalAttrs = value:
    if value == null then
      { }
    else if builtins.isAttrs value then
      value
    else
      throw "input contract failure: expected attribute set, got ${builtins.typeOf value}";

  renderValue = value:
    let
      jsonAttempt = builtins.tryEval (builtins.toJSON value);
      typeAttempt = builtins.tryEval (builtins.typeOf value);
      typeName =
        if typeAttempt.success then
          typeAttempt.value
        else
          "unknown";
    in
    if jsonAttempt.success then
      jsonAttempt.value
    else
      "\"<unrenderable:${typeName}>\"";

  previewBlock = heading: value:
    "\n${heading}\n${renderValue value}";

  failWithValue = message: value:
    throw "${message}${previewBlock "--- received value ---" value}";

  failWithContext = message: context:
    throw "${message}${previewBlock "--- offending input context ---" context}";

  failWithContextAndValue = message: context: value:
    throw "${message}${previewBlock "--- received value ---" value}${previewBlock "--- offending input context ---" context}";

  requireAttrs = path: value:
    if builtins.isAttrs value then
      value
    else
      failWithValue "input contract failure: ${path} must be an attribute set" value;

  requireAttrsIn = context: path: value:
    if builtins.isAttrs value then
      value
    else
      failWithContextAndValue "input contract failure: ${path} must be an attribute set" context value;

  requireList = path: value:
    if builtins.isList value then
      value
    else
      failWithValue "input contract failure: ${path} must be a list" value;

  requireListIn = context: path: value:
    if builtins.isList value then
      value
    else
      failWithContextAndValue "input contract failure: ${path} must be a list" context value;

  requireString = path: value:
    if isNonEmptyString value then
      value
    else
      failWithValue "input contract failure: ${path} is required" value;

  requireStringIn = context: path: value:
    if isNonEmptyString value then
      value
    else
      failWithContextAndValue "input contract failure: ${path} is required" context value;

  requireStringList = path: value:
    if builtins.isList value && builtins.all isNonEmptyString value then
      value
    else
      failWithValue "input contract failure: ${path} must contain only non-empty strings" value;

  requireStringListIn = context: path: value:
    if builtins.isList value && builtins.all isNonEmptyString value then
      value
    else
      failWithContextAndValue "input contract failure: ${path} must contain only non-empty strings" context value;

  firstOr = fallback: values:
    if values == [ ] then
      fallback
    else
      builtins.elemAt values 0;

  attrCount = attrs:
    builtins.length (builtins.attrNames attrs);

  ensureUniqueEntries = path: entries:
    let
      attrs = builtins.listToAttrs entries;
    in
    if attrCount attrs != builtins.length entries then
      throw "input contract failure: ${path} contains duplicate identities"
    else
      attrs;

  hasAttr = name: attrs:
    builtins.isAttrs attrs && builtins.hasAttr name attrs;
in
{
  inherit
    attrCount
    ensureUniqueEntries
    failWithContext
    failWithContextAndValue
    failWithValue
    firstOr
    forceAll
    hasAttr
    isNonEmptyString
    optionalAttrs
    renderValue
    requireAttrs
    requireAttrsIn
    requireList
    requireListIn
    requireString
    requireStringIn
    requireStringList
    requireStringListIn
    sortedNames;
}
