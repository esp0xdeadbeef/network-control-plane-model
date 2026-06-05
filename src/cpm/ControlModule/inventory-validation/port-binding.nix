{ helpers, failInventory }:

{ targetDef, siteContract, nodeContract, portName }:

let
  inherit (helpers) hasAttr isNonEmptyString;

  portPath = "${targetDef.nodePath}.ports.${portName}";
  portBinding = targetDef.portBindings.portDefs.${portName};
  selector = portBinding.selector;
  nodeName = targetDef.logical.name;

  requireExplicitHostUplinkAddressing =
    let
      hostUplink =
        if builtins.isAttrs (portBinding.hostUplink or null) then
          portBinding.hostUplink
        else
          failInventory
            "inventory.deployment.hosts.${targetDef.host}.uplinks"
            "runtime realization for ${portPath} on realized target '${targetDef.nodePath}' requires explicit host uplink bridge mapping in inventory.deployment.hosts.${targetDef.host}.uplinks";
      uplinkName =
        if isNonEmptyString (hostUplink.uplinkName or null) then
          hostUplink.uplinkName
        else if isNonEmptyString (hostUplink.name or null) then
          hostUplink.name
        else
          selector.key;
      requireFamilyMethod = familyName: familyValue:
        if familyValue == null then
          false
        else if !builtins.isAttrs familyValue then
          failInventory
            "inventory.deployment.hosts.${targetDef.host}.uplinks.${uplinkName}.${familyName}"
            "runtime realization for ${portPath} on realized target '${targetDef.nodePath}' requires this value to be an attribute set"
        else if !isNonEmptyString (familyValue.method or null) then
          failInventory
            "inventory.deployment.hosts.${targetDef.host}.uplinks.${uplinkName}.${familyName}.method"
            "runtime realization for ${portPath} on realized target '${targetDef.nodePath}' requires this field to be explicitly defined"
        else
          true;
      hasIPv4 = requireFamilyMethod "ipv4" (hostUplink.ipv4 or null);
      hasIPv6 = requireFamilyMethod "ipv6" (hostUplink.ipv6 or null);
    in
    if hasIPv4 || hasIPv6 then
      true
    else
      failInventory
        "inventory.deployment.hosts.${targetDef.host}.uplinks.${uplinkName}"
        "runtime realization for ${portPath} on realized target '${targetDef.nodePath}' requires explicit upstream addressing in inventory.deployment.hosts.${targetDef.host}.uplinks.${uplinkName}.ipv4 and/or ipv6";
in
if selector.kind == "link" then
  if !hasAttr selector.key siteContract.links then
    failInventory "${portPath}.link" "references unknown forwarding-model site link '${selector.key}'"
  else
    let
      link = siteContract.links.${selector.key};
    in
    if (link.kind or null) != "p2p" then
      failInventory "${portPath}.link" "link selector must reference a p2p forwarding-model link; use uplink selectors for WAN realization"
    else if !hasAttr selector.key nodeContract.p2pLinkSet then
      failInventory "${portPath}.link" "logical node '${nodeName}' does not declare p2p link '${selector.key}'"
    else
      true
else if selector.kind == "logicalInterface" then
  if !hasAttr selector.key nodeContract.interfaces then
    failInventory "${portPath}.logicalInterface" "references unknown logical interface '${selector.key}' on node '${nodeName}'"
  else if !hasAttr selector.key nodeContract.logicalTenantInterfaceSet then
    failInventory "${portPath}.logicalInterface" "must reference a tenant interface with logical = true"
  else
    true
else if !hasAttr selector.key siteContract.uplinkNameSet then
  failInventory "${portPath}.uplink" "references unknown site uplink '${selector.key}'"
else if !nodeContract.mayAnchorExternalUplinks then
  failInventory "${portPath}.uplink" "logical node '${nodeName}' is not allowed to anchor external uplinks"
else if !hasAttr selector.key nodeContract.wanUpstreamSet then
  failInventory "${portPath}.uplink" "logical node '${nodeName}' does not declare WAN uplink '${selector.key}'"
else
  requireExplicitHostUplinkAddressing
