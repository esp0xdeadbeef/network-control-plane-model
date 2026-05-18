{ helpers, bindingCommon }:

{
  sitePath,
  policyInterfaceTags,
  siteUplinkNames,
  declaredExternalNames,
  serviceDefinitions,
  attachmentsByTenant,
  domainsByTenant,
  runtimeTenantBindingsByTenant,
  runtimeExternalBindingsByName,
  relationTenantNames,
  relationExternalNames,
  serviceNamesFromContract,
  relationTenantSet,
  relationExternalSet,
  relations,
}:

let
  inherit (helpers) hasAttr sortedNames;
  inherit (bindingCommon) failForwarding listOrEmpty uniqueStrings;

  tenantNames =
    uniqueStrings ((sortedNames attachmentsByTenant) ++ (sortedNames domainsByTenant) ++ relationTenantNames);

  externalNames =
    uniqueStrings (siteUplinkNames ++ declaredExternalNames ++ relationExternalNames ++ (sortedNames runtimeExternalBindingsByName));

  tenantBindings =
    builtins.listToAttrs (
      map
        (tenantName:
          let
            runtimeBindingList = runtimeTenantBindingsByTenant.${tenantName} or [ ];
            required =
              if hasAttr tenantName relationTenantSet && runtimeBindingList == [ ] then
                failForwarding "${sitePath}.policy.interfaceTags" "canonical policy endpoint binding for tenant '${tenantName}' requires an explicit runtime tenant interface binding"
              else
                true;
          in
          builtins.seq required {
            name = tenantName;
            value = {
              attachments = attachmentsByTenant.${tenantName} or [ ];
              domains = domainsByTenant.${tenantName} or [ ];
              runtimeBindings = runtimeBindingList;
            };
          })
        tenantNames
    );

  externalBindings =
    builtins.listToAttrs (
      map
        (externalName:
          let
            runtimeBindingList = runtimeExternalBindingsByName.${externalName} or [ ];
            hasRuntimeWANBinding = builtins.any (binding: (binding.sourceKind or null) == "wan") runtimeBindingList;
            hasRuntimeOverlayBinding = builtins.any (binding: (binding.sourceKind or null) == "overlay") runtimeBindingList;
            isDeclaredUplink = builtins.elem externalName siteUplinkNames;
            required =
              if hasAttr externalName relationExternalSet && runtimeBindingList == [ ] then
                if isDeclaredUplink then
                  failForwarding "${sitePath}.uplinkNames" "canonical policy endpoint binding for uplink '${externalName}' requires an explicit realized WAN binding"
                else
                  failForwarding "${sitePath}.nodes" "canonical policy endpoint binding for external '${externalName}' requires an explicit realized overlay or WAN binding"
              else
                true;
          in
          builtins.seq required {
            name = externalName;
            value = {
              uplinks = if isDeclaredUplink || hasRuntimeWANBinding then [ externalName ] else [ ];
              overlays = if hasRuntimeOverlayBinding then [ externalName ] else [ ];
              runtimeBindings = runtimeBindingList;
            };
          })
        externalNames
    );

  serviceBindings =
    builtins.listToAttrs (
      map
        (serviceName:
          let service = serviceDefinitions.${serviceName} or { name = serviceName; };
          in {
            name = serviceName;
            value = {
              providers = listOrEmpty (service.providers or null);
              trafficType = service.trafficType or null;
            };
          })
        serviceNamesFromContract
    );

in
{
  interfaceTags = policyInterfaceTags;
  tenants = tenantBindings;
  externals = externalBindings;
  services = serviceBindings;
  inherit relations;
}
