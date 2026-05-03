{
  helpers,
  common,
  sitePath,
  enterpriseName,
  siteName,
  overlayNames,
  requireExplicitHostUplinkAddressing,
}:

let
  inherit (helpers) hasAttr isNonEmptyString requireAttrs requireStringList;
  inherit (common) failInventory mergeRoutes;

  explicitUplinkRoute = family: dst: {
    inherit dst;
    intent = {
      kind = if (family == 4 && dst == "0.0.0.0/0") || (family == 6 && dst == "::/0") then "default-reachability" else "uplink-learned-reachability";
      source = "explicit-uplink";
    };
    proto = "upstream";
  };
in
{ nodeName, uplinkName, uplinkValue, portBindings, targetHostName, targetId, realizedTarget }:
let
  uplinkPath = "${sitePath}.nodes.${nodeName}.uplinks.${uplinkName}";
  uplinkAttrs = requireAttrs uplinkPath uplinkValue;
  portBinding = if hasAttr uplinkName portBindings.byUplink then portBindings.byUplink.${uplinkName} else null;
  _requiredPortBinding =
    if realizedTarget && portBinding == null then
      failInventory "${targetId}.ports" "${uplinkPath} on realized target '${targetId}' requires explicit uplink port realization for uplink '${uplinkName}'"
    else
      true;
  runtimeIfName = if portBinding != null then portBinding.runtimeIfName else uplinkName;
  effectiveAddr4 = if portBinding != null && isNonEmptyString (portBinding.interfaceAddr4 or null) then portBinding.interfaceAddr4 else uplinkAttrs.addr4 or null;
  effectiveAddr6 = if portBinding != null && isNonEmptyString (portBinding.interfaceAddr6 or null) then portBinding.interfaceAddr6 else uplinkAttrs.addr6 or null;
  resolvedHostUplink = if portBinding != null && builtins.isAttrs (portBinding.hostUplink or null) then portBinding.hostUplink else null;
  validatedHostUplink =
    if realizedTarget then
      if builtins.elem uplinkName overlayNames then
        resolvedHostUplink
      else if resolvedHostUplink == null then
        failInventory
          "inventory.deployment.hosts.${targetHostName}.uplinks"
          "${uplinkPath} on realized target '${targetId}' requires explicit host uplink mapping in inventory.deployment.hosts.${targetHostName}.uplinks"
      else
        builtins.seq
          (requireExplicitHostUplinkAddressing { ifacePath = uplinkPath; inherit targetHostName targetId; hostUplink = resolvedHostUplink; })
          resolvedHostUplink
    else
      resolvedHostUplink;
  baseRoutes = {
    ipv4 = builtins.map (dst: explicitUplinkRoute 4 dst) (if uplinkAttrs ? ipv4 then requireStringList "${uplinkPath}.ipv4" uplinkAttrs.ipv4 else [ ]);
    ipv6 = builtins.map (dst: explicitUplinkRoute 6 dst) (if uplinkAttrs ? ipv6 then requireStringList "${uplinkPath}.ipv6" uplinkAttrs.ipv6 else [ ]);
  };
  routes = if portBinding != null && builtins.isAttrs (portBinding.interfaceRoutes or null) then mergeRoutes baseRoutes portBinding.interfaceRoutes else baseRoutes;
  value =
    {
      runtimeTarget = targetId;
      logicalNode = nodeName;
      sourceInterface = uplinkName;
      sourceKind = "wan";
      runtimeIfName = runtimeIfName;
      renderedIfName = runtimeIfName;
      addr4 = effectiveAddr4;
      addr6 = effectiveAddr6;
      inherit routes;
      backingRef = { kind = "link"; id = "uplink::${enterpriseName}.${siteName}::${uplinkName}"; name = uplinkName; };
      upstream = uplinkName;
      wan = {
        ipv4 = if uplinkAttrs ? ipv4 then requireStringList "${uplinkPath}.ipv4" uplinkAttrs.ipv4 else [ ];
        ipv6 = if uplinkAttrs ? ipv6 then requireStringList "${uplinkPath}.ipv6" uplinkAttrs.ipv6 else [ ];
      };
    }
    // (if portBinding != null && builtins.isAttrs (portBinding.attach or null) then { attach = portBinding.attach; } else { })
    // (if validatedHostUplink != null then { hostUplink = validatedHostUplink; } else { })
    // (if builtins.isAttrs (validatedHostUplink.ipv4 or null) then { ipv4 = validatedHostUplink.ipv4; } else { })
    // (if builtins.isAttrs (validatedHostUplink.ipv6 or null) then { ipv6 = validatedHostUplink.ipv6; } else { });
in
builtins.seq _requiredPortBinding { name = uplinkName; inherit value; }
