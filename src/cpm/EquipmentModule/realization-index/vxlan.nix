{ helpers, failInventory, hostDefFor }:

let
  inherit (helpers) hasAttr requireAttrs requireString;

  requirePositiveInt = path: value:
    if builtins.isInt value && value > 0 then
      value
    else
      failInventory path "must be a positive integer";

  normalizeVxlanBridgeAttachment = targetHostName: vxlanPath: bridgeAttachment:
    let
      bridgeAttrs = requireAttrs "${vxlanPath}.bridgeAttachment" bridgeAttachment;
      bridgeName = requireString "${vxlanPath}.bridgeAttachment.bridge" (bridgeAttrs.bridge or null);
      hostDef = hostDefFor targetHostName;
    in
    if hasAttr bridgeName hostDef.bridges then
      { bridge = bridgeName; }
    else
      failInventory "${vxlanPath}.bridgeAttachment.bridge" "references unknown host bridge '${bridgeName}'";
in
{
  normalizeVxlanContract = targetHostName: portPath: portAttrs:
    if builtins.isAttrs (portAttrs.vxlan or null) then
      let
        vxlanPath = "${portPath}.vxlan";
        vxlanAttrs = requireAttrs vxlanPath portAttrs.vxlan;
      in
      {
        vni = requirePositiveInt "${vxlanPath}.vni" (vxlanAttrs.vni or null);
        localEndpoint = requireString "${vxlanPath}.localEndpoint" (vxlanAttrs.localEndpoint or null);
        remoteEndpoint = requireString "${vxlanPath}.remoteEndpoint" (vxlanAttrs.remoteEndpoint or null);
        underlayInterface = requireString "${vxlanPath}.underlayInterface" (vxlanAttrs.underlayInterface or null);
        mtu = requirePositiveInt "${vxlanPath}.mtu" (vxlanAttrs.mtu or null);
        bridgeAttachment = normalizeVxlanBridgeAttachment targetHostName vxlanPath (vxlanAttrs.bridgeAttachment or null);
      }
    else
      null;
}
