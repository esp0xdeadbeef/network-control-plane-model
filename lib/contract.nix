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

  requireAttrs = path: value:
    if builtins.isAttrs value then
      value
    else
      throw "input contract failure: ${path} must be an attribute set";

  requireList = path: value:
    if builtins.isList value then
      value
    else
      throw "input contract failure: ${path} must be a list";

  requireString = path: value:
    if isNonEmptyString value then
      value
    else
      throw "input contract failure: ${path} is required";

  requireStringList = path: value:
    if builtins.isList value && builtins.all isNonEmptyString value then
      value
    else
      throw "input contract failure: ${path} must contain only non-empty strings";

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
    firstOr
    forceAll
    hasAttr
    isNonEmptyString
    optionalAttrs
    requireAttrs
    requireList
    requireString
    requireStringList
    sortedNames;
}
