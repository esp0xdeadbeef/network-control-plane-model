{ lib, common, transitInvariant }:

let
  inherit (common)
    fail
    forceAll
    hasAttr
    isNonEmptyString
    requireAttrs
    requireList
    requireString
    requireStringList
    ;

  validateNode = context: nodeName: node:
    let
      nodeContext = context // { node = nodeName; };
      nodeAttrs = requireAttrs nodeContext "nodes.${nodeName}" node;
      interfaces = requireAttrs nodeContext "node.interfaces" (nodeAttrs.interfaces or null);
      loopback = requireAttrs nodeContext "node.loopback" (nodeAttrs.loopback or null);
    in
    builtins.seq
      (if !isNonEmptyString (loopback.ipv4 or null) || !isNonEmptyString (loopback.ipv6 or null) then
        fail nodeContext "node loopback is required"
      else
        true)
      (forceAll (
        builtins.map
          (ifName:
            let
              ifaceContext = nodeContext // { interface = ifName; };
              iface = requireAttrs ifaceContext "node.interfaces.${ifName}" interfaces.${ifName};
            in
            if !isNonEmptyString (iface.kind or null) then
              fail ifaceContext "interface kind is required"
            else
              true)
          (lib.attrNamesSorted interfaces)
      ));

  validateAttachments = context: attachments:
    forceAll (
      builtins.genList
        (idx:
          let attachment = requireAttrs context "attachments[${toString idx}]" (builtins.elemAt attachments idx);
          in
          builtins.seq
            (requireString context "attachments[${toString idx}].kind" (attachment.kind or null))
            (builtins.seq
              (requireString context "attachments[${toString idx}].name" (attachment.name or null))
              (requireString context "attachments[${toString idx}].unit" (attachment.unit or null))))
        (builtins.length attachments)
    );

  validateRoleReferences = context: nodeNameSet: policyNodeName: upstreamSelectorNodeName: coreNodeNames: uplinkCoreNames:
    builtins.seq
      (if hasAttr policyNodeName nodeNameSet then true else fail context "policyNodeName references unknown node '${policyNodeName}'")
      (builtins.seq
        (if hasAttr upstreamSelectorNodeName nodeNameSet then true else fail context "upstreamSelectorNodeName references unknown node '${upstreamSelectorNodeName}'")
        (builtins.seq
          (forceAll (
            builtins.map
              (nodeName: if hasAttr nodeName nodeNameSet then true else fail context "coreNodeNames references unknown node '${nodeName}'")
              coreNodeNames
          ))
          (forceAll (
            builtins.map
              (nodeName: if hasAttr nodeName nodeNameSet then true else fail context "uplinkCoreNames references unknown node '${nodeName}'")
              uplinkCoreNames
          ))));

in
{
  validate = enterpriseName: siteName: site:
    let
      context = { enterprise = enterpriseName; site = siteName; };
      siteAttrs = requireAttrs context "site" site;
      attachments = requireList context "attachments" (siteAttrs.attachments or null);
      links = requireAttrs context "links" (siteAttrs.links or null);
      nodes = requireAttrs context "nodes" (siteAttrs.nodes or null);
      policyNodeName = requireString context "policyNodeName" (siteAttrs.policyNodeName or null);
      upstreamSelectorNodeName = requireString context "upstreamSelectorNodeName" (siteAttrs.upstreamSelectorNodeName or null);
      coreNodeNames = requireStringList context "coreNodeNames" (siteAttrs.coreNodeNames or null);
      uplinkCoreNames = requireStringList context "uplinkCoreNames" (siteAttrs.uplinkCoreNames or null);
      nodeNames = lib.attrNamesSorted nodes;
      nodeNameSet = builtins.listToAttrs (map (name: { inherit name; value = true; }) nodeNames);
      domains = requireAttrs context "domains" (siteAttrs.domains or null);
    in
    builtins.seq
      (requireString context "siteId" (siteAttrs.siteId or null))
      (builtins.seq
        (requireString context "siteName" (siteAttrs.siteName or null))
        (builtins.seq
          (validateAttachments context attachments)
          (builtins.seq
            (requireStringList context "uplinkNames" (siteAttrs.uplinkNames or null))
            (builtins.seq
              (requireList context "domains.tenants" (domains.tenants or null))
              (builtins.seq
                (requireList context "domains.externals" (domains.externals or null))
                (builtins.seq
                  (requireAttrs context "tenantPrefixOwners" (siteAttrs.tenantPrefixOwners or null))
                  (builtins.seq
                    (validateRoleReferences context nodeNameSet policyNodeName upstreamSelectorNodeName coreNodeNames uplinkCoreNames)
                    (builtins.seq
                      (forceAll (builtins.map (nodeName: validateNode context nodeName nodes.${nodeName}) nodeNames))
                      (transitInvariant.validate context links (siteAttrs.transit or null))))))))));
}
