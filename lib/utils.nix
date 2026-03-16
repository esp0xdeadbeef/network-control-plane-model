{
  stripMask = addr:
    if builtins.isString addr && addr != "" then
      builtins.elemAt (builtins.split "/" addr) 0
    else
      null;

  attrNamesSorted = attrs:
    builtins.sort builtins.lessThan (builtins.attrNames attrs);

  attrValuesSorted = attrs:
    builtins.map
      (name: attrs.${name})
      (builtins.sort builtins.lessThan (builtins.attrNames attrs));

  mapAttrsSorted = f: attrs:
    builtins.listToAttrs (
      builtins.map
        (name: {
          inherit name;
          value = f name attrs.${name};
        })
        (builtins.sort builtins.lessThan (builtins.attrNames attrs))
    );

  filter = pred: list:
    builtins.filter pred list;

  isP2PLink = link:
    builtins.isAttrs link
    && (link.kind or null) == "p2p"
    && builtins.isAttrs (link.endpoints or {})
    && builtins.length (builtins.attrNames (link.endpoints or {})) == 2;
}
