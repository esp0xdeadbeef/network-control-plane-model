{ helpers, common }:

let
  inherit (helpers) isNonEmptyString;
  inherit (common) failInventory;
in
{
  requireExplicitHostUplinkAddressing = { ifacePath, targetHostName, targetId, hostUplink }:
    let
      uplinkName =
        if isNonEmptyString (hostUplink.uplinkName or null) then
          hostUplink.uplinkName
        else if isNonEmptyString (hostUplink.name or null) then
          hostUplink.name
        else
          failInventory
            "inventory.deployment.hosts.${targetHostName}.uplinks"
            "runtime realization for ${ifacePath} on realized target '${targetId}' resolved an unnamed host uplink";

      requireFamilyMethod = familyName: familyValue:
        if familyValue == null then
          false
        else if !builtins.isAttrs familyValue then
          failInventory
            "inventory.deployment.hosts.${targetHostName}.uplinks.${uplinkName}.${familyName}"
            "runtime realization for ${ifacePath} on realized target '${targetId}' requires this value to be an attribute set"
        else if !isNonEmptyString (familyValue.method or null) then
          failInventory
            "inventory.deployment.hosts.${targetHostName}.uplinks.${uplinkName}.${familyName}.method"
            "runtime realization for ${ifacePath} on realized target '${targetId}' requires this field to be explicitly defined"
        else
          true;

      hasIPv4 = requireFamilyMethod "ipv4" (hostUplink.ipv4 or null);
      hasIPv6 = requireFamilyMethod "ipv6" (hostUplink.ipv6 or null);
    in
    if hasIPv4 || hasIPv6 then
      true
    else
      failInventory
        "inventory.deployment.hosts.${targetHostName}.uplinks.${uplinkName}"
        "runtime realization for ${ifacePath} on realized target '${targetId}' requires explicit upstream addressing in inventory.deployment.hosts.${targetHostName}.uplinks.${uplinkName}.ipv4 and/or ipv6";
}
