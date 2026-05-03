{ lib }:

let
  hasAttr = name: attrs:
    builtins.isAttrs attrs && builtins.hasAttr name attrs;

  isNonEmptyString = value:
    builtins.isString value && value != "";

  isStringList = value:
    builtins.isList value && builtins.all isNonEmptyString value;

  forceAll = values:
    builtins.deepSeq values true;

  hasDuplicates = values:
    let
      sorted = builtins.sort builtins.lessThan values;
      count = builtins.length sorted;
    in
    if count <= 1 then
      false
    else
      builtins.any
        (idx: builtins.elemAt sorted idx == builtins.elemAt sorted (idx + 1))
        (builtins.genList (idx: idx) (count - 1));

  contextString = context:
    let
      segments =
        (if context ? enterprise && isNonEmptyString context.enterprise then [ "enterprise.${context.enterprise}" ] else [])
        ++ (if context ? site && isNonEmptyString context.site then [ "site.${context.site}" ] else [])
        ++ (if context ? node && isNonEmptyString context.node then [ "node.${context.node}" ] else [])
        ++ (if context ? interface && isNonEmptyString context.interface then [ "interface.${context.interface}" ] else [])
        ++ (if context ? target && isNonEmptyString context.target then [ "target.${context.target}" ] else []);
    in
    if segments == [] then "forwardingModel" else builtins.concatStringsSep "." segments;

  fail = context: message:
    throw "${contextString context}: ${message}";

  requireAttrs = context: path: value:
    if builtins.isAttrs value then value else fail context "${path} must be an attribute set";

  requireList = context: path: value:
    if builtins.isList value then value else fail context "${path} must be a list";

  requireString = context: path: value:
    if isNonEmptyString value then value else fail context "${path} is required";

  requireStringList = context: path: value:
    if isStringList value then value else fail context "${path} must contain only non-empty strings";
in
{
  inherit
    fail
    forceAll
    hasAttr
    hasDuplicates
    isNonEmptyString
    requireAttrs
    requireList
    requireString
    requireStringList
    ;
}
