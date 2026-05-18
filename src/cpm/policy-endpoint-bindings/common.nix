{ helpers }:

let
  inherit (helpers) isNonEmptyString sortedNames;
in
{
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  listOrEmpty = value: if builtins.isList value then value else [ ];
  failForwarding = path: message:
    throw "forwarding-model update required: ${path}: ${message}";
  uniqueStrings = values:
    sortedNames (
      builtins.listToAttrs (
        map (value: { name = value; value = true; }) (builtins.filter isNonEmptyString values)
      )
    );
  makeStringSet = values:
    builtins.listToAttrs (
      map (value: { name = value; value = true; }) (builtins.filter isNonEmptyString values)
    );
  appendListValue = acc: key: value:
    acc // { ${key} = (acc.${key} or [ ]) ++ [ value ]; };
}
