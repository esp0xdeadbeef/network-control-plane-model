{
  lib,
  helpers,
  common,
  enterpriseName,
  siteName,
  sitePath,
  attachments,
  links,
}:

let
  inherit (helpers) ensureUniqueEntries hasAttr isNonEmptyString requireAttrs requireString requireStringList;
  inherit (common) failForwarding;

  attachmentLookup =
    ensureUniqueEntries
      "${sitePath}.attachments"
      (builtins.genList
        (idx:
          let
            attachmentPath = "${sitePath}.attachments[${toString idx}]";
            attachment = requireAttrs attachmentPath (builtins.elemAt attachments idx);
            kind = requireString "${attachmentPath}.kind" (attachment.kind or null);
            name = requireString "${attachmentPath}.name" (attachment.name or null);
            unit = requireString "${attachmentPath}.unit" (attachment.unit or null);
          in
          { name = "${unit}|${kind}|${name}"; value = { inherit kind name unit; id = "attachment::${unit}::${kind}::${name}"; }; })
        (builtins.length attachments));

  siteLinks =
    lib.mapAttrsSorted
      (linkName: linkValue:
        let
          linkPath = "${sitePath}.links.${linkName}";
          link = requireAttrs linkPath linkValue;
        in
        link // { name = linkName; id = requireString "${linkPath}.id" (link.id or null); kind = requireString "${linkPath}.kind" (link.kind or null); })
      links;

  resolveBackingRef = nodeName: ifName: iface:
    let
      ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
      kind = requireString "${ifacePath}.kind" (iface.kind or null);
    in
    if kind == "tenant" then
      let
        tenantName = requireString "${ifacePath}.tenant" (iface.tenant or null);
        attachmentKey = "${nodeName}|tenant|${tenantName}";
        attachment =
          if hasAttr attachmentKey attachmentLookup then
            attachmentLookup.${attachmentKey}
          else
            failForwarding ifacePath "tenant interface requires explicit site.attachments entry; add { kind = \"tenant\"; name = \"${tenantName}\"; unit = \"${nodeName}\"; } to ${sitePath}.attachments";
      in
      { kind = "attachment"; id = attachment.id; name = attachment.name; }
    else if kind == "overlay" then
      let
        overlayName = requireString "${ifacePath}.overlay" (iface.overlay or null);
      in
      { kind = "overlay"; id = "overlay::${enterpriseName}.${siteName}::${overlayName}"; name = overlayName; }
    else
      let
        linkName = requireString "${ifacePath}.link" (iface.link or null);
        link =
          if hasAttr linkName siteLinks then
            siteLinks.${linkName}
          else
            failForwarding "${ifacePath}.link" "input contract failure: ${ifacePath}.link references unknown site link '${linkName}'";
      in
      {
        kind = "link";
        id = link.id;
        name = linkName;
        linkKind = link.kind;
      }
      // (if isNonEmptyString (link.lane or null) then { lane = link.lane; } else { })
      // (if builtins.isList (link.uplinks or null) then { uplinks = requireStringList "${ifacePath}.link.uplinks" link.uplinks; } else { })
      // (if kind == "wan" then { upstreamAlias = requireString "${ifacePath}.upstream" (iface.upstream or null); } else { });
in
{
  inherit resolveBackingRef;
}
