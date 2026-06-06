{ helpers
, failInventory
,
}:

let
  inherit (helpers)
    ensureUniqueEntries
    hasAttr
    isNonEmptyString
    requireAttrs
    requireString
    sortedNames
    ;

  attrsOrEmpty = value: if builtins.isAttrs value then value else { };

  entriesFor = path: attrs:
    builtins.map
      (name: {
        inherit name;
        value = {
          path = "${path}.${name}";
          attrs = attrs.${name};
        };
      })
      (sortedNames attrs);

  scopedRootFor = targetName: fabricLinksRoot:
    let
      candidate = attrsOrEmpty (fabricLinksRoot.${targetName} or null);
    in
    if candidate == { } || isNonEmptyString (candidate.link or null) || isNonEmptyString (candidate.backingLink or null) then
      { }
    else
      candidate;

  flatEntriesFor = targetName: fabricLinksRoot:
    builtins.filter
      (entry:
        let
          attrs = attrsOrEmpty entry.value.attrs;
        in
        (attrs.target or null) == targetName)
      (entriesFor "inventory.realization.fabricLinks" fabricLinksRoot);

  linkNameFor = fabricPath: fabricAttrs:
    if isNonEmptyString (fabricAttrs.link or null) then
      fabricAttrs.link
    else
      requireString "${fabricPath}.backingLink" (fabricAttrs.backingLink or null);

  runtimeIfNameFor = fabricAttrs:
    let
      interfaceAttrs = attrsOrEmpty (fabricAttrs.interface or null);
    in
    if isNonEmptyString (fabricAttrs.runtimeIfName or null) then
      fabricAttrs.runtimeIfName
    else if isNonEmptyString (interfaceAttrs.name or null) then
      interfaceAttrs.name
    else
      null;

  normalizeFabricLink = raw:
    let
      fabricPath = raw.value.path;
      fabricAttrs = requireAttrs fabricPath raw.value.attrs;
      linkName = linkNameFor fabricPath fabricAttrs;
      runtimeIfName = runtimeIfNameFor fabricAttrs;
      kind =
        if isNonEmptyString (fabricAttrs.kind or null) then
          fabricAttrs.kind
        else
          "selector-fabric-link";
    in
    {
      name = raw.name;
      value = {
        inherit kind;
        link = linkName;
        source = "inventory-realization";
        sourcePath = fabricPath;
      }
      // (if runtimeIfName != null then { inherit runtimeIfName; } else { })
      // (if builtins.isAttrs (fabricAttrs.transport or null) then { transport = fabricAttrs.transport; } else { })
      // (if isNonEmptyString (fabricAttrs.description or null) then { description = fabricAttrs.description; } else { });
    };

  buildLinkIndex = targetPath: fabricLinkDefs:
    ensureUniqueEntries "${targetPath}.fabricLinks" (
      builtins.map
        (fabricLinkName:
          let
            fabricLink = fabricLinkDefs.${fabricLinkName};
          in
          {
            name = fabricLink.link;
            value = fabricLink;
          })
        (sortedNames fabricLinkDefs)
    );

  normalizeFabricLinks = targetName: targetPath: target: fabricLinksRoot:
    let
      nodeLocal = attrsOrEmpty (target.fabricLinks or null);
      scopedRoot = scopedRootFor targetName fabricLinksRoot;
      rawEntryAttrs =
        ensureUniqueEntries
          "${targetPath}.fabricLinks plus inventory.realization.fabricLinks"
          (
            entriesFor "${targetPath}.fabricLinks" nodeLocal
            ++ entriesFor "inventory.realization.fabricLinks.${targetName}" scopedRoot
            ++ flatEntriesFor targetName fabricLinksRoot
          );
      fabricLinkDefs =
        builtins.listToAttrs (
          builtins.map
            (name: normalizeFabricLink { inherit name; value = rawEntryAttrs.${name}; })
            (sortedNames rawEntryAttrs)
        );
    in
    {
      inherit fabricLinkDefs;
      byLink = buildLinkIndex targetPath fabricLinkDefs;
    };
in
{
  inherit normalizeFabricLinks;
}
