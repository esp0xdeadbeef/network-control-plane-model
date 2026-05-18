{ helpers, common }:

let
  inherit (helpers) forceAll hasAttr isNonEmptyString requireAttrs requireList requireString requireStringList sortedNames;
  inherit (common) attrsOrEmpty failForwarding makeStringSet;

  validateRoutes = ifacePath: ifaceAttrs:
    let
      routes = requireAttrs "${ifacePath}.routes" (ifaceAttrs.routes or null);
      _ipv4 = requireList "${ifacePath}.routes.ipv4" (routes.ipv4 or null);
      _ipv6 = requireList "${ifacePath}.routes.ipv6" (routes.ipv6 or null);
    in
    true;

  validateInterface = sitePath: attachmentLookup: links: nodeName: ifName: iface:
    let
      ifacePath = "${sitePath}.nodes.${nodeName}.interfaces.${ifName}";
      ifaceAttrs = requireAttrs ifacePath iface;
      kind = ifaceAttrs.kind or null;
    in
    if !isNonEmptyString kind then
      failForwarding ifacePath "interface kind is required"
    else if !isNonEmptyString (ifaceAttrs.interface or null) then
      failForwarding "${ifacePath}.interface" "${ifacePath}.interface is required"
    else if kind == "tenant" && !isNonEmptyString (ifaceAttrs.tenant or null) then
      failForwarding "${ifacePath}.tenant" "tenant interface requires explicit tenant"
    else if kind == "tenant" && !hasAttr "${nodeName}|tenant|${ifaceAttrs.tenant}" attachmentLookup then
      failForwarding ifacePath "tenant interface requires explicit site.attachments entry; add { kind = \"tenant\"; name = \"${ifaceAttrs.tenant}\"; unit = \"${nodeName}\"; } to ${sitePath}.attachments"
    else if kind == "overlay" && !isNonEmptyString (ifaceAttrs.overlay or null) then
      failForwarding "${ifacePath}.overlay" "overlay interface requires explicit overlay"
    else if kind == "wan" && !isNonEmptyString (ifaceAttrs.upstream or null) then
      failForwarding "${ifacePath}.upstream" "wan interface requires explicit upstream"
    else if kind == "wan" && !isNonEmptyString (ifaceAttrs.link or null) then
      failForwarding "${ifacePath}.link" "wan interface requires explicit link"
    else if kind == "wan" && !hasAttr ifaceAttrs.link links then
      failForwarding "${ifacePath}.link" "${ifacePath}.link references unknown site link '${ifaceAttrs.link}'"
    else
      builtins.seq (validateRoutes ifacePath ifaceAttrs) true;

  validateNodeUplink = sitePath: uplinkNameSet: nodeName: uplinkName: uplink:
    let
      uplinkPath = "${sitePath}.nodes.${nodeName}.uplinks.${uplinkName}";
      uplinkAttrs = requireAttrs uplinkPath uplink;
      knownUplink =
        if hasAttr uplinkName uplinkNameSet then true else failForwarding uplinkPath "node uplink references unknown site uplink '${uplinkName}'";
      ipv4 = if uplinkAttrs ? ipv4 then requireStringList "${uplinkPath}.ipv4" uplinkAttrs.ipv4 else true;
      ipv6 = if uplinkAttrs ? ipv6 then requireStringList "${uplinkPath}.ipv6" uplinkAttrs.ipv6 else true;
    in
    builtins.seq knownUplink (builtins.seq ipv4 ipv6);

  attachmentLookupForSite = attachments:
    makeStringSet (
      builtins.filter
        isNonEmptyString
        (map
          (attachment:
            let
              attrs = attrsOrEmpty attachment;
              kind = attrs.kind or null;
              name = attrs.name or null;
              unit = attrs.unit or null;
            in
            if isNonEmptyString kind && isNonEmptyString name && isNonEmptyString unit then "${unit}|${kind}|${name}" else null)
          attachments)
    );

in
{
  validateNode = sitePath: attachmentLookup: links: uplinkNameSet: nodeName: node:
    let
      nodePath = "${sitePath}.nodes.${nodeName}";
      nodeAttrs = requireAttrs nodePath node;
      interfaces = requireAttrs "${nodePath}.interfaces" (nodeAttrs.interfaces or null);
      interfaceNames = sortedNames interfaces;
      uplinks = if builtins.isAttrs (nodeAttrs.uplinks or null) then nodeAttrs.uplinks else { };
      hasExplicitTenantInterface =
        builtins.any
          (ifName:
            let iface = attrsOrEmpty interfaces.${ifName};
            in (iface.kind or null) == "tenant" && isNonEmptyString (iface.tenant or null))
          interfaceNames;
    in
    builtins.seq
      (forceAll (map (ifName: validateInterface sitePath attachmentLookup links nodeName ifName interfaces.${ifName}) interfaceNames))
      (builtins.seq
        (forceAll (map (uplinkName: validateNodeUplink sitePath uplinkNameSet nodeName uplinkName uplinks.${uplinkName}) (sortedNames uplinks)))
        (if (nodeAttrs.role or null) == "access" && !hasExplicitTenantInterface then
          failForwarding "${nodePath}.interfaces" "access node requires at least one tenant interface with explicit tenant"
        else
          true));

  inherit attachmentLookupForSite;
}
