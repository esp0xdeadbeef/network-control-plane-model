{ helpers
, failInventory
, hostDefFor
, resolveHostUplinkFromBridge
,
}:

let
  inherit (helpers)
    hasAttr
    isNonEmptyString
    requireString
    ;

  validAdapterName = value:
    builtins.isString value && builtins.match "^[a-z][a-z0-9-]*$" value != null;

  portSelector = portPath: portAttrs:
    if isNonEmptyString (portAttrs.link or null) then
      {
        kind = "link";
        key = portAttrs.link;
      }
    else if isNonEmptyString (portAttrs.logicalInterface or null) then
      {
        kind = "logicalInterface";
        key = portAttrs.logicalInterface;
      }
    else if (portAttrs.external or false) == true then
      {
        kind = "uplink";
        key = requireString "${portPath}.uplink" (portAttrs.uplink or null);
      }
    else if isNonEmptyString (portAttrs.uplink or null) then
      {
        kind = "uplink";
        key = portAttrs.uplink;
      }
    else
      failInventory portPath "port must declare exactly one selector via link, logicalInterface, or uplink/external";

  adapterNameFor = portPath: portAttrs: selector:
    if selector.kind == "link" then
      let
        requiredAdapterName = requireString "${portPath}.adapterName" (portAttrs.adapterName or null);
      in
      if validAdapterName requiredAdapterName then
        requiredAdapterName
      else
        failInventory "${portPath}.adapterName" "must match ^[a-z][a-z0-9-]*$ (example: br-isp-a)"
    else if isNonEmptyString (portAttrs.adapterName or null) then
      failInventory "${portPath}.adapterName" "is only supported for ports that select a p2p link via .link"
    else
      null;

  hostUplinkFor = targetHostName: portPath: selector: attach:
    if selector.kind == "uplink" && attach != null && (attach.kind or null) == "bridge" then
      resolveHostUplinkFromBridge targetHostName portPath attach.bridge
    else if selector.kind == "uplink" then
      let
        hostDef = hostDefFor targetHostName;
        uplinkName = selector.key;
      in
      if hasAttr uplinkName hostDef.uplinks then hostDef.uplinks.${uplinkName} else null
    else if attach != null && (attach.kind or null) == "bridge" then
      resolveHostUplinkFromBridge targetHostName portPath attach.bridge
    else
      null;
in
{
  inherit
    adapterNameFor
    hostUplinkFor
    portSelector
    ;
}
