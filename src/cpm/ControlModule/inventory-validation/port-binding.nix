{ helpers, failInventory }:

{ targetDef, siteContract, nodeContract, portName }:

let
  inherit (helpers) hasAttr;

  portPath = "${targetDef.nodePath}.ports.${portName}";
  portBinding = targetDef.portBindings.portDefs.${portName};
  selector = portBinding.selector;
  nodeName = targetDef.logical.name;
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
  true
