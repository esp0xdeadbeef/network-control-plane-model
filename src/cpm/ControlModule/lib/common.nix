{ helpers }:

let
  inherit (helpers) isNonEmptyString sortedNames;

  attrsOrEmpty = value:
    if builtins.isAttrs value then value else { };

  listOrEmpty = value:
    if builtins.isList value then value else [ ];

  uniqueStrings =
    values:
    sortedNames (
      builtins.listToAttrs (
        builtins.map
          (value: {
            name = value;
            value = true;
          })
          (builtins.filter isNonEmptyString values)
      )
    );

  mergeRoutes =
    base: extra: {
      ipv4 = listOrEmpty (base.ipv4 or [ ]) ++ listOrEmpty (extra.ipv4 or [ ]);
      ipv6 = listOrEmpty (base.ipv6 or [ ]) ++ listOrEmpty (extra.ipv6 or [ ]);
    };

in
{
  inherit
    attrsOrEmpty
    listOrEmpty
    mergeRoutes
    uniqueStrings
    ;
}
