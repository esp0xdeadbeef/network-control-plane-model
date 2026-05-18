{ helpers }:

let inherit (helpers) isNonEmptyString sortedNames;
in
{
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  listOrEmpty = value: if builtins.isList value then value else [ ];
  makeStringSet = values:
    builtins.listToAttrs (map (value: { name = value; value = true; }) values);
  failForwarding = path: message:
    throw "forwarding-model update required: ${path}: ${message}";
  collectNamesFromList = list:
    builtins.filter isNonEmptyString (map (item: (if builtins.isAttrs item then item else { }).name or null) list);
  collectStringValues = attrs:
    builtins.filter isNonEmptyString (builtins.attrValues attrs);
  inherit sortedNames;
}
